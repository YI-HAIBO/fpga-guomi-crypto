// =============================================================================
// 模块名称 : sm2_pmul
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v2.0  (v1.0 的标量比特选择 / from_mont 乘数 / 仿射转换链三处均错)
// 日期     : 2026-10-02
// 视角     : rtl-designer
// 功能     : SM2 标量点乘  R = [scalar]*(px,py), 全程 Jacobian 坐标
//
// 域约定 (与 sm2_montmul.v / sm2_consts.py 完全一致):
//   等价类 M(v) = v*R mod p ,  R = 2^256 mod p
//   mont_mul(a,b) = REDC(a*b) = a*b*R^-1 mod p
//   => 两个 Montgomery 形式输入相乘, 结果仍是 Montgomery 形式 (封闭)
//   => to_mont(plain v)   = mul(v, R^2)   (乘数 R2_MOD_P)
//   => from_mont(M(v))    = mul(m, 1)     (乘数 plain 1)
//      **注意**: from_mont 的乘数是 plain 1, 不是 MONT_ONE(=R)。
//      喂 R 只会得到恒等映射 (m*R*R^-1 = m), v1.0 就是踩了这个坑。
//
// 坐标     : 全程 Jacobian (Montgomery 域); 输出 x/y/z 即 (X, Y, Z), 无穷远 => z==0
// 算法     : MSB-first double-and-add, 256 轮
//   i = 255 (初值): bit255==1 -> R = P ; bit255==0 -> R = 无穷远
//   for i = 254 downto 0:  R = 2R ;  if scalar[i]  R = R + P
// 无穷远短路 (关键):
//   sm2_point_add 的点加在 Z1==0 时 Z3 = ((0+Z2)^2-0-ZZ2)*H = 0, 会把基点吃掉;
//   点倍在 Z1==0 时同理退化。故用 Zr==0 作无穷远哨兵, 遇到时直接短路:
//     - 点倍: Zr==0 -> 跳过 (无穷远的倍点还是无穷远)
//     - 点加: Zr==0 -> R = P (无穷远 + P = P)
//   这样 [0]P 自然得到无穷远, 不需要特判, 也不会把基点算错。
// 相等点问题: 因为每轮点加之前必定先点倍, R + P 里的 R 绝不等于 P
//   (R == P 只在 R == 无穷远 时成立, 而该情形已被短路), 所以 jac_add 不会
//   遇到 H==0 的退化 (除 [0]P 外), 无需在 pmul 内额外保护。
// 依赖     : sm2_point_add, sm2_montmul
// 时序     : 256 轮点运算 ≈ 50k cycles
// =============================================================================

`timescale 1ns / 1ps

module sm2_pmul (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,            // 启动脉冲
    input  wire [255:0] scalar,           // 标量 (plain, 0 <= scalar < n); 运算期间不变
    input  wire [255:0] px,              // 基点 x (Montgomery 形式)
    input  wire [255:0] py,              // 基点 y (Montgomery 形式)
    output reg  [255:0] x_out,           // Jacobian X (Montgomery 形式) ; 无穷远时为 0
    output reg  [255:0] y_out,           // Jacobian Y (Montgomery 形式)
    output reg  [255:0] z_out,           // Jacobian Z (Montgomery 形式) ; 0 = 无穷远
    output reg          inf_flag,        // 结果为无穷远
    output reg          done,            // 完成脉冲 (1 cycle)

    // -- Phase 8: 透传 u_pa (sm2_point_add) 的共享 Montgomery 乘法请求 --
    output wire         pa_mm_req,
    output wire [255:0] pa_mm_a,
    output wire [255:0] pa_mm_b,
    input  wire [255:0] pa_mm_result,
    input  wire         pa_mm_done
);

    // =========================================================================
    // 常数 (均已用 Python 对 p=sm2p256v1 核算过)
    // =========================================================================
    localparam [255:0] MONT_ONE = 256'h0000000100000000000000000000000000000000ffffffff0000000000000001; // R mod p
    localparam [255:0] R2_MOD_P = 256'h0000000400000002000000010000000100000002ffffffff0000000200000003; // R^2 mod p

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
        // Phase 8: point_add 的 montmul 请求透传到 sm2_sign 层的 sm2_mm_arb
        .mm_req(pa_mm_req), .mm_a(pa_mm_a), .mm_b(pa_mm_b),
        .mm_result(pa_mm_result), .mm_done(pa_mm_done)
    );

    // Phase 8: 本模块原有的 sm2_montmul u_mm 是死实例 (mm_start 从不置 1),
    //          已删除; 点运算的 montmul 由 u_pa 经上层 sm2_mm_arb 提供。

    // =========================================================================
    // 状态
    // =========================================================================
    localparam [3:0] S_DBL   = 4'd0;   // 发起点倍 (Zr==0 时短路)
    localparam [3:0] S_DBLW  = 4'd1;   // 等点倍 done
    localparam [3:0] S_ADDC  = 4'd2;   // 按 scalar[idx] 决定要不要点加
    localparam [3:0] S_ADD   = 4'd3;   // 发起点加 (Zr==0 时直接 R=P)
    localparam [3:0] S_ADDW  = 4'd4;   // 等点加 done
    localparam [3:0] S_NEXT  = 4'd5;   // 位指针推进
    localparam [3:0] S_DONE  = 4'd6;
    localparam [3:0] S_IDLE  = 4'd7;

    reg [3:0] st;
    reg [7:0] idx;
    reg [255:0] sc;                     // 标量锁存
    reg [255:0] Xr, Yr, Zr;             // Jacobian (Montgomery)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            idx       <= 8'd0;
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
        end else begin
            // 子模块启动脉冲每拍默认清零 (从模块回 IDLE 后不能重复采样 start)
            pa_start  <= 1'b0;

            case (st)

                // =========================================================
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        inf_flag <= 1'b0;
                        sc       <= scalar;             // 标量锁存, 运算期不再看端口
                        Xr       <= px;
                        Yr       <= py;
                        idx      <= 8'd254;
                        if (scalar[255]) Zr <= MONT_ONE; else Zr <= 256'd0;  // 无穷远哨兵
                        st       <= S_DBL;
                    end
                end

                // =========================================================
                // 点倍 (无穷远短路)
                // =========================================================
                S_DBL: begin
                    if (Zr == 256'd0) begin
                        st <= S_ADDC;                  // 无穷远: 跳过点倍
                    end else begin
                        pa_op    <= 1'b1;              // 点倍 2R
                        pa_x1    <= Xr;
                        pa_y1    <= Yr;
                        pa_z1    <= Zr;
                        pa_x2    <= 256'd0;
                        pa_y2    <= 256'd0;
                        pa_z2    <= 256'd0;
                        pa_start <= 1'b1;
                        st       <= S_DBLW;
                    end
                end

                S_DBLW: begin
                    if (pa_done) begin
                        Xr <= pa_x3;
                        Yr <= pa_y3;
                        Zr <= pa_z3;
                        st <= S_ADDC;
                    end
                end

                // 本轮点加与否由当前标量位决定
                S_ADDC: begin
                    if (sc[idx]) st <= S_ADD; else st <= S_NEXT;
                end

                // =========================================================
                // 点加 (无穷远短路)
                // =========================================================
                S_ADD: begin
                    if (Zr == 256'd0) begin
                        Xr       <= px;                // 无穷远 + P = P
                        Yr       <= py;
                        Zr       <= MONT_ONE;
                        st       <= S_NEXT;
                    end else begin
                        pa_op    <= 1'b0;              // 点加
                        pa_x1    <= Xr;
                        pa_y1    <= Yr;
                        pa_z1    <= Zr;
                        pa_x2    <= px;                // 基点, z2 = 1
                        pa_y2    <= py;
                        pa_z2    <= MONT_ONE;
                        pa_start <= 1'b1;
                        st       <= S_ADDW;
                    end
                end

                S_ADDW: begin
                    if (pa_done) begin
                        Xr <= pa_x3;
                        Yr <= pa_y3;
                        Zr <= pa_z3;
                        st <= S_NEXT;
                    end
                end

                // =========================================================
                S_NEXT: begin
                    if (idx == 8'd0) st <= S_DONE;
                    else begin
                        idx <= idx - 8'd1;
                        st  <= S_DBL;
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
