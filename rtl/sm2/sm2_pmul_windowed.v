// =============================================================================
// 模块名称 : sm2_pmul_windowed
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.1 (Phase 0.5.2 窗口化标量点乘)
// 日期     : 2026-10-04
// 视角     : rtl-designer (葛逻辑)
// 功能     : SM2 标量点乘 R = [scalar]*(px,py), w-ary 窗口化 (w=4)
//
// 算法     : w-ary Windowing (w=4), MSB-first
//   预计算: 15 个倍点 {P, 2P, 3P, ..., 15P}
//           prec[0] = P          (直接赋值)
//           prec[1] = 2P         (必须走点倍; P+P 时 H=0 退化, 不可用点加)
//           prec[j] = prec[j-1]+P (j = 2..14)
//   主循环: 64 轮 (256/4), 每轮 4 次点倍 + 1 次点加 (if window != 0)
//   窗口   : win = (sc >> shift) & 15, shift = 252, 248, ..., 0
//
// v1.1 相对 v1.0 的修正 (v1.0 从未通过编译, 且有 3 处算法级错误):
//   1. [算法] 预计算表 8 -> 15 项。w=4 的窗口值域为 0..15, 8 项表无法覆盖
//             窗口 9..15, v1.0 的 case default 会把它们全部误映射到 1P。
//   2. [算法] 2P 必须用点倍生成。v1.0 的 prec[i]=prec[i-1]+P 在 i=1 时执行
//             P+P, 相等点加使 H=0, sm2_point_add 是纯公式实现无短路 -> 退化。
//   3. [算法] v1.0 用 sc[idx-1:idx-4] 取窗口: (a) idx=255 时取 [254:251],
//             漏掉最高位 255; (b) 循环在 idx<4 退出, 最低 3 位 [2:0] 从不被
//             处理; (c) 变量边界 part-select 在 -g2005 下不合法。
//             v1.1 改用 sc >> win_shift 右移 + 常量边界 [3:0] 截取。
//   4. [综合] v1.0 S_PREC 在 prec[0]=P 后进入 S_PREC_W, 但 pa_start 从未拉高,
//             pa_done 永不到来 -> 死锁。v1.1 改为回到 S_PREC 继续。
//   5. [综合] v1.0 S_DBLW_W 在 pa_done 拍同时 `pa_x1 <= Xr` 与 `Xr <= pa_x3`,
//             NBA 使 pa_x1 取到旧值 -> 反复倍同一旧点。v1.1 拆成
//             S_DBLW(启动)/S_DBLW_W(等待)/S_DBLN(决策) 三态, 链式输入在
//             独立拍上采样已更新的 Xr。
//
// 对比 sm2_pmul v2.0 (double-and-add, 256 轮):
//   - 迭代次数: 256 -> 64 (减少 75%)
//   - 点加法数量: 128 -> 64 (减少 50%), 另加预计算 14 次
//   - 预期延迟: ~50k cycles -> ~25k cycles (2x 加速)
//
// 接口     : 与 sm2_pmul v2.0 完全兼容, 可直接替换
// 依赖     : sm2_point_add
// 数学验证 : .workbuddy/tmp/pmul_window_ref.py (ALL REF CHECKS: PASS)
//             预计算表 1P..15P 全对; 窗口化与 DAA 在 20 个 k 上仿射等价
// =============================================================================

`timescale 1ns / 1ps

module sm2_pmul_windowed (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] scalar,
    input  wire [255:0] px,
    input  wire [255:0] py,
    output reg  [255:0] x_out,
    output reg  [255:0] y_out,
    output reg  [255:0] z_out,
    output reg          inf_flag,
    output reg          done,

    // -- Phase 8: 透传 u_pa (sm2_point_add) 的共享 Montgomery 乘法请求 --
    output wire         pa_mm_req,
    output wire [255:0] pa_mm_a,
    output wire [255:0] pa_mm_b,
    input  wire [255:0] pa_mm_result,
    input  wire         pa_mm_done
);

    // =========================================================================
    // 常数
    // =========================================================================
    // MONT_ONE = R mod p, R = 2^256 mod p; 用作仿射点的 Z 坐标
    localparam [255:0] MONT_ONE = 256'h0000000100000000000000000000000000000000ffffffff0000000000000001;

    localparam integer NTAB  = 15;    // 预计算 1P..15P
    localparam integer W     = 4;     // 窗口宽度
    localparam integer NWIN  = 64;    // 窗口轮数 = 256/4
    localparam integer SH0   = 252;   // 首轮右移量 (取 [255:252])

    // =========================================================================
    // 子模块
    // =========================================================================
    reg          pa_start;
    reg          pa_op;
    reg  [255:0] pa_x1, pa_y1, pa_z1;
    reg  [255:0] pa_x2, pa_y2, pa_z2;
    wire [255:0] pa_x3, pa_y3, pa_z3;
    wire         pa_done;

    sm2_point_add u_pa (
        .clk(clk), .rst_n(rst_n), .start(pa_start), .op(pa_op),
        .x1(pa_x1), .y1(pa_y1), .z1(pa_z1),
        .x2(pa_x2), .y2(pa_y2), .z2(pa_z2),
        .x3(pa_x3), .y3(pa_y3), .z3(pa_z3), .done(pa_done),
        // Phase 8: point_add 的 montmul 请求透传到上层 sm2_mm_arb
        .mm_req(pa_mm_req), .mm_a(pa_mm_a), .mm_b(pa_mm_b),
        .mm_result(pa_mm_result), .mm_done(pa_mm_done)
    );

    // =========================================================================
    // 预计算表 (15 个倍点: 1P..15P)
    // =========================================================================
    reg [255:0] prec_x [0:NTAB-1];
    reg [255:0] prec_y [0:NTAB-1];
    reg [255:0] prec_z [0:NTAB-1];

    // =========================================================================
    // 状态机
    // =========================================================================
    localparam [3:0] S_IDLE   = 4'd0;
    localparam [3:0] S_PREC   = 4'd1;   // 启动一次预计算运算 (或直写 prec[0])
    localparam [3:0] S_PREC_W = 4'd2;   // 等待预计算结果
    localparam [3:0] S_DBLW   = 4'd3;   // 启动一次点倍
    localparam [3:0] S_DBLW_W = 4'd4;   // 等待点倍结果
    localparam [3:0] S_DBLN   = 4'd5;   // 决定: 继续点倍 or 进入窗口判定
    localparam [3:0] S_ADDC   = 4'd6;   // 判定窗口值
    localparam [3:0] S_ADD    = 4'd7;   // 启动点加 (或无穷远时直取表项)
    localparam [3:0] S_ADD_W  = 4'd8;   // 等待点加结果
    localparam [3:0] S_NEXT   = 4'd9;   // 窗口前移 or 结束
    localparam [3:0] S_DONE   = 4'd10;

    reg [3:0]   st;
    reg [8:0]   win_shift;   // 252 -> 0, 步长 -4
    reg [255:0] sc;
    reg [255:0] Xr, Yr, Zr;
    reg [3:0]   prec_cnt;    // 预计算下标 (0..14)
    reg [3:0]   dbl_cnt;     // 本窗口已完成点倍次数 (0..4)

    // 当前窗口值 (常量边界截取, 变量移位 -> -g2005 合法)
    wire [3:0] win_val = sc >> win_shift;

    // =========================================================================
    // 主状态机逻辑
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            win_shift <= 9'd0;
            sc        <= 256'd0;
            Xr        <= 256'd0;
            Yr        <= 256'd0;
            Zr        <= 256'd0;
            x_out     <= 256'd0;
            y_out     <= 256'd0;
            z_out     <= 256'd0;
            inf_flag  <= 1'b0;
            done      <= 1'b0;
            pa_start  <= 1'b0;
            pa_op     <= 1'b0;
            prec_cnt  <= 4'd0;
            dbl_cnt   <= 4'd0;
        end else begin
            pa_start  <= 1'b0;      // 单拍脉冲

            case (st)

                // =========================================================
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        inf_flag  <= 1'b0;
                        sc        <= scalar;
                        Xr        <= 256'd0;      // 初始为无穷远
                        Yr        <= 256'd0;
                        Zr        <= 256'd0;
                        prec_cnt  <= 4'd0;
                        dbl_cnt   <= 4'd0;
                        win_shift <= 9'd252;
                        st        <= S_PREC;
                    end
                end

                // =========================================================
                // 预计算 1P..15P
                //   prec[0] = P          直写, 无运算
                //   prec[1] = 2P         点倍 (P+P 会退化)
                //   prec[j] = prec[j-1]+P,  j = 2..14
                // =========================================================
                S_PREC: begin
                    if (prec_cnt == 4'd0) begin
                        prec_x[0] <= px;
                        prec_y[0] <= py;
                        prec_z[0] <= MONT_ONE;
                        prec_cnt  <= 4'd1;
                        st        <= S_PREC;         // 不等待, 继续下一项
                    end else if (prec_cnt == 4'd1) begin
                        // prec[1] = 2*prec[0]
                        pa_op    <= 1'b1;            // 点倍
                        pa_x1    <= prec_x[0];
                        pa_y1    <= prec_y[0];
                        pa_z1    <= prec_z[0];
                        pa_x2    <= 256'd0;
                        pa_y2    <= 256'd0;
                        pa_z2    <= 256'd0;
                        pa_start <= 1'b1;
                        st       <= S_PREC_W;
                    end else begin
                        // prec[j] = prec[j-1] + prec[0]
                        pa_op    <= 1'b0;            // 点加
                        pa_x1    <= prec_x[prec_cnt-1];
                        pa_y1    <= prec_y[prec_cnt-1];
                        pa_z1    <= prec_z[prec_cnt-1];
                        pa_x2    <= prec_x[0];
                        pa_y2    <= prec_y[0];
                        pa_z2    <= prec_z[0];
                        pa_start <= 1'b1;
                        st       <= S_PREC_W;
                    end
                end

                S_PREC_W: begin
                    if (pa_done) begin
                        prec_x[prec_cnt] <= pa_x3;
                        prec_y[prec_cnt] <= pa_y3;
                        prec_z[prec_cnt] <= pa_z3;
                        prec_cnt          <= prec_cnt + 4'd1;
                        st                <= (prec_cnt == 4'd14) ? S_DBLW : S_PREC;
                    end
                end

                // =========================================================
                // 主循环: 每轮 4 次点倍
                // =========================================================
                S_DBLW: begin
                    if (Zr == 256'd0) begin
                        st       <= S_ADDC;          // 无穷远: 跳过点倍
                    end else begin
                        pa_op    <= 1'b1;
                        pa_x1    <= Xr;
                        pa_y1    <= Yr;
                        pa_z1    <= Zr;
                        pa_x2    <= 256'd0;
                        pa_y2    <= 256'd0;
                        pa_z2    <= 256'd0;
                        pa_start <= 1'b1;
                        st       <= S_DBLW_W;
                    end
                end

                S_DBLW_W: begin
                    if (pa_done) begin
                        Xr       <= pa_x3;
                        Yr       <= pa_y3;
                        Zr       <= pa_z3;
                        st       <= S_DBLN;
                    end
                end

                S_DBLN: begin
                    if (dbl_cnt < 4'd3) begin
                        dbl_cnt  <= dbl_cnt + 4'd1;
                        st       <= S_DBLW;          // 第 2/3/4 次点倍
                    end else begin
                        st       <= S_ADDC;
                    end
                end

                // =========================================================
                // 窗口判定与点加
                // =========================================================
                S_ADDC: begin
                    st <= (win_val == 4'd0) ? S_NEXT : S_ADD;
                end

                S_ADD: begin
                    if (Zr == 256'd0) begin
                        // 无穷远 + [win]*P = [win]*P: 直接取表项
                        case (win_val)
                            4'd1: begin Xr <= prec_x[0];  Yr <= prec_y[0];  Zr <= prec_z[0];  end
                            4'd2: begin Xr <= prec_x[1];  Yr <= prec_y[1];  Zr <= prec_z[1];  end
                            4'd3: begin Xr <= prec_x[2];  Yr <= prec_y[2];  Zr <= prec_z[2];  end
                            4'd4: begin Xr <= prec_x[3];  Yr <= prec_y[3];  Zr <= prec_z[3];  end
                            4'd5: begin Xr <= prec_x[4];  Yr <= prec_y[4];  Zr <= prec_z[4];  end
                            4'd6: begin Xr <= prec_x[5];  Yr <= prec_y[5];  Zr <= prec_z[5];  end
                            4'd7: begin Xr <= prec_x[6];  Yr <= prec_y[6];  Zr <= prec_z[6];  end
                            4'd8: begin Xr <= prec_x[7];  Yr <= prec_y[7];  Zr <= prec_z[7];  end
                            4'd9: begin Xr <= prec_x[8];  Yr <= prec_y[8];  Zr <= prec_z[8];  end
                            4'd10:begin Xr <= prec_x[9];  Yr <= prec_y[9];  Zr <= prec_z[9];  end
                            4'd11:begin Xr <= prec_x[10]; Yr <= prec_y[10]; Zr <= prec_z[10]; end
                            4'd12:begin Xr <= prec_x[11]; Yr <= prec_y[11]; Zr <= prec_z[11]; end
                            4'd13:begin Xr <= prec_x[12]; Yr <= prec_y[12]; Zr <= prec_z[12]; end
                            4'd14:begin Xr <= prec_x[13]; Yr <= prec_y[13]; Zr <= prec_z[13]; end
                            4'd15:begin Xr <= prec_x[14]; Yr <= prec_y[14]; Zr <= prec_z[14]; end
                            default:begin Xr <= 256'd0;  Yr <= 256'd0;  Zr <= 256'd0;  end
                        endcase
                        st <= S_NEXT;
                    end else begin
                        pa_op  <= 1'b0;
                        pa_x1  <= Xr;
                        pa_y1  <= Yr;
                        pa_z1  <= Zr;
                        case (win_val)
                            4'd1: begin pa_x2 <= prec_x[0];  pa_y2 <= prec_y[0];  pa_z2 <= prec_z[0];  end
                            4'd2: begin pa_x2 <= prec_x[1];  pa_y2 <= prec_y[1];  pa_z2 <= prec_z[1];  end
                            4'd3: begin pa_x2 <= prec_x[2];  pa_y2 <= prec_y[2];  pa_z2 <= prec_z[2];  end
                            4'd4: begin pa_x2 <= prec_x[3];  pa_y2 <= prec_y[3];  pa_z2 <= prec_z[3];  end
                            4'd5: begin pa_x2 <= prec_x[4];  pa_y2 <= prec_y[4];  pa_z2 <= prec_z[4];  end
                            4'd6: begin pa_x2 <= prec_x[5];  pa_y2 <= prec_y[5];  pa_z2 <= prec_z[5];  end
                            4'd7: begin pa_x2 <= prec_x[6];  pa_y2 <= prec_y[6];  pa_z2 <= prec_z[6];  end
                            4'd8: begin pa_x2 <= prec_x[7];  pa_y2 <= prec_y[7];  pa_z2 <= prec_z[7];  end
                            4'd9: begin pa_x2 <= prec_x[8];  pa_y2 <= prec_y[8];  pa_z2 <= prec_z[8];  end
                            4'd10:begin pa_x2 <= prec_x[9];  pa_y2 <= prec_y[9];  pa_z2 <= prec_z[9];  end
                            4'd11:begin pa_x2 <= prec_x[10]; pa_y2 <= prec_y[10]; pa_z2 <= prec_z[10]; end
                            4'd12:begin pa_x2 <= prec_x[11]; pa_y2 <= prec_y[11]; pa_z2 <= prec_z[11]; end
                            4'd13:begin pa_x2 <= prec_x[12]; pa_y2 <= prec_y[12]; pa_z2 <= prec_z[12]; end
                            4'd14:begin pa_x2 <= prec_x[13]; pa_y2 <= prec_y[13]; pa_z2 <= prec_z[13]; end
                            4'd15:begin pa_x2 <= prec_x[14]; pa_y2 <= prec_y[14]; pa_z2 <= prec_z[14]; end
                            default:begin pa_x2 <= prec_x[0]; pa_y2 <= prec_y[0]; pa_z2 <= prec_z[0]; end
                        endcase
                        pa_start <= 1'b1;
                        st       <= S_ADD_W;
                    end
                end

                S_ADD_W: begin
                    if (pa_done) begin
                        Xr       <= pa_x3;
                        Yr       <= pa_y3;
                        Zr       <= pa_z3;
                        st       <= S_NEXT;
                    end
                end

                // =========================================================
                S_NEXT: begin
                    if (win_shift == 9'd0) begin
                        st        <= S_DONE;
                    end else begin
                        win_shift <= win_shift - 9'd4;
                        dbl_cnt   <= 4'd0;
                        st        <= S_DBLW;
                    end
                end

                // =========================================================
                S_DONE: begin
                    done <= 1'b1;
                    if (Zr == 256'd0) begin
                        inf_flag <= 1'b1;
                        x_out    <= 256'd0;
                        y_out    <= 256'd0;
                        z_out    <= 256'd0;
                    end else begin
                        x_out    <= Xr;
                        y_out    <= Yr;
                        z_out    <= Zr;
                    end
                    st <= S_IDLE;
                end

                default: begin
                    st <= S_IDLE;
                end
            endcase
        end
    end

endmodule
