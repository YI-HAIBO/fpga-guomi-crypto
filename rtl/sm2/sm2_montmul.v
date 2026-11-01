// =============================================================================
// 模块名称 : sm2_montmul
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v2.2  (乘法器半字拆分 + 软件流水 acc 累加)
// 日期     : 2026-10-18
// 视角     : rtl-designer (葛逻辑)
// 功能     : SM2 Montgomery 模乘 (result = a * b * R^{-1} mod p)
// 曲线     : sm2p256v1 (GB/T 32918-2016)
// 时序     : ~57 cycles (3 phases × 17 cycles + transitions + reduce + done)
//
// 算法 (Montgomery reduction, 迭代版本):
//   Phase 0: t = a * b          (17 cycles = 8 iter × 2 stages + 1 fin)
//   Phase 1: m = t[255:0] * NEG_P_INV  mod 2^256  (17 cycles)
//   Phase 2: mp = m * P         (17 cycles)
//   Reduce:  u = (t + mp) >> 256, if u >= P: u -= P
//
// 版本演进:
//   v1.1: 3× 256×256 组合乘法器 → ~167k cells/instance, 5400 DSP inferred
//   v2.0: 1× 32×256 迭代乘法器  → ~3k cells/instance, <100 DSP (~32 cycles)
//   v2.1: S_ITER 拆两拍 (MULL + ADD), 关键路径 89 级 → ~45 级 (~52 cycles)
//   v2.2: 乘法器半字拆分 + 软件流水:
//         - partial = a[15:0]*b 与 a[31:16]*b 两个 16×256 半字各占一拍寄存,
//           下一拍再做 288-bit 合并 —— 把单拍内的 DSP 级联 + 64 级 CARRY4
//           累加链拆成两段
//         - 上一轮的 acc 累加与本轮半字乘法放在同一拍(软件流水),
//           因此每轮仍是 2 拍, 不增加吞吐代价
//
// v2.2 动机 (wrap8 综合实测):
//   最差路径 u_mm_arb/u_mm/a_shift_reg[16] -> shifted_reg_reg[285]
//   Data Path 18.888ns = logic 16.084ns (85.2%) + route 2.804ns (14.8%)
//   Logic Levels 72 = CARRY4×64 + DSP48E1×4 + LUT×4
//   -> 频率上限由乘法器内部组合链决定, 与扇出无关
//   综合级最短周期 v2.0/v2.1/v2.2 前一直是 19.04ns (≈52 MHz)
//
// 参考: Montgomery 1985; GB/T 32918-2016; gmssl 35 组交叉验证
// =============================================================================

`timescale 1ns / 1ps

module sm2_montmul (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,          // 启动脉冲
    input  wire [255:0] a,              // Montgomery 形式输入
    input  wire [255:0] b,              // Montgomery 形式输入
    output reg  [255:0] result,         // Montgomery 形式输出
    output reg          done,           // 完成脉冲 (1 cycle)
    output wire         busy            // 处理中
);

    // =========================================================================
    // 曲线常数 (SM2 sm2p256v1)
    // =========================================================================
    localparam [255:0] P         = 256'hfffffffeffffffffffffffffffffffffffffffff00000000ffffffffffffffff;
    localparam [255:0] NEG_P_INV = 256'hfffffffc00000001fffffffe00000000ffffffff000000010000000000000001;

    // =========================================================================
    // FSM 状态 (v2.2: 乘法拆两拍 + 独立的最后一轮累加拍)
    // =========================================================================
    localparam [3:0] S_IDLE      = 4'd0;  // 空闲
    localparam [3:0] S_ITER_MUL0 = 4'd1;  // 迭代拍 A: 两个 16×256 半字乘积 + acc 累加(上一轮)
    localparam [3:0] S_ITER_MULL = 4'd2;  // 迭代拍 B: 半字合并 + 移位 -> shifted_reg
    localparam [3:0] S_ITER_FIN  = 4'd7;  // 最后一轮的 acc 累加 (软件流水收尾)
    localparam [3:0] S_TRANS     = 4'd3;  // Phase 转换: 捕获 acc, 设置下 phase 参数
    localparam [3:0] S_TRANS2    = 4'd4;  // Phase 转换续: 设置 a_shift (需等 t/m 稳定)
    localparam [3:0] S_REDUCE    = 4'd5;  // u = (t+mp)>>256 低半求和
    localparam [3:0] S_REDUCE2   = 4'd8;  // v2.3: 高半求和 (含低半进位)
    localparam [3:0] S_REDUCE3   = 4'd9;  // v2.3: 条件减 P (ge_p 由减法进位导出)
    localparam [3:0] S_DONE      = 4'd6;  // Done pulse (1 cycle)

    reg [3:0] state;

    // =========================================================================
    // 寄存器
    // =========================================================================
    reg [255:0] b_reg;        // 右操作数 (每个 phase 固定)
    reg [255:0] a_shift;      // 左操作数 (每迭代左移 32 位)
    reg [511:0] acc;          // 累加器 (512 位)
    reg [2:0]   cnt;          // 迭代计数器 (0..7)
    reg [1:0]   phase;        // 当前 phase (0,1,2)

    // 乘法结果寄存
    reg [511:0] t_reg;        // t = a * b (512 位)
    reg [255:0] m_reg;        // m = t_low * INV mod 2^256
    reg [511:0] mp_reg;       // mp = m * P (512 位)

    // v2.1: 流水线寄存器 (S_ITER_MULL → 下一拍的 acc 累加)
    reg [511:0] shifted_reg;  // 存储 shifted 结果, 打破 DSP→CARRY4 组合链

    // v2.2 新增: 半字乘积寄存器 (16×256 = 272 bit)
    reg [271:0] plo;          // a_shift[15:0]  * b_reg
    reg [271:0] phi;          // a_shift[31:16] * b_reg
    reg         acc_en;       // 软件流水门控: 第 0 轮不累加 (shifted_reg 无效)

    // =========================================================================
    // 32×256 迭代乘法器 (v2.2: 半字拆分)
    //   a[31:0] * b = (a[15:0] * b) + ((a[31:16] * b) << 16)
    //   plo/phi 在 S_ITER_MUL0 寄存, partial 在 S_ITER_MULL 合并
    // =========================================================================
    wire [287:0] partial = {16'b0, plo} + {phi, 16'b0};   // 288 bit

    // Shifted partial (case statement for -g2005 compatibility)
    // cnt=0: partial << 0, cnt=1: partial << 32, ..., cnt=7: partial << 224
    // Total: 288 + 224 = 512 bits max
    reg [511:0] shifted;
    always @(*) begin
        case (cnt)
            3'd0:  shifted = {224'b0, partial};
            3'd1:  shifted = {192'b0, partial, 32'b0};
            3'd2:  shifted = {160'b0, partial, 64'b0};
            3'd3:  shifted = {128'b0, partial, 96'b0};
            3'd4:  shifted = { 96'b0, partial, 128'b0};
            3'd5:  shifted = { 64'b0, partial, 160'b0};
            3'd6:  shifted = { 32'b0, partial, 192'b0};
            3'd7:  shifted = {partial, 224'b0};
            default: shifted = 512'b0;
        endcase
    end

    // =========================================================================
    // Reduce: u = (t + mp) >> 256, conditional subtract
    // Note: t_reg + mp_reg can overflow bit 511 (carry into bit 512),
    // so the high part must be 257 bits to capture the full value.
    //
    // v2.3: 拆三拍。原写法在一拍内完成 513-bit 加法 + 257-bit 条件减,
    //   综合出 102 级逻辑 (CARRY4=97), 是 wrap10 综合期最差路径
    //   (u_mm_arb/u_mm/t_reg_reg[129] -> result_reg[128], 15.191ns)。
    //   拆拍后每拍只有一段 256/257-bit 进位链。
    // =========================================================================
    reg [256:0] sum_lo;      // 低半 256 位和, bit256 = 进位
    reg [256:0] sum_hi;      // 高半 256 位和 (257 bit)
    reg [256:0] u_sub_r;     // sum_hi - P (257 bit)
    reg         ge_p_r;      // sum_hi >= P

    wire [256:0] p_ext = {1'b0, P};               // zero-extend P to 257 bits

    // =========================================================================
    // FSM 主逻辑
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            b_reg       <= 256'd0;
            a_shift     <= 256'd0;
            acc         <= 512'd0;
            cnt         <= 3'd0;
            phase       <= 2'd0;
            t_reg       <= 512'd0;
            m_reg       <= 256'd0;
            mp_reg      <= 512'd0;
            shifted_reg <= 512'd0;
            plo         <= 272'd0;
            phi         <= 272'd0;
            acc_en      <= 1'b0;
            sum_lo      <= 257'd0;
            sum_hi      <= 257'd0;
            u_sub_r     <= 257'd0;
            ge_p_r      <= 1'b0;
            result      <= 256'd0;
            done        <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        b_reg   <= b;
                        a_shift <= a;
                        acc     <= 512'd0;
                        cnt     <= 3'd0;
                        phase   <= 2'd0;
                        acc_en  <= 1'b0;
                        state   <= S_ITER_MUL0;
                    end
                end

                // ---- v2.2 迭代拍 A ----
                // 两个 16×256 半字乘积各自寄存 (拆开 DSP 级联 + 长 CARRY4 累加链);
                // 同时把「上一轮」的 shifted_reg 累加进 acc (软件流水, 不增加拍数)
                S_ITER_MUL0: begin
                    done <= 1'b0;
                    plo  <= a_shift[15:0]  * b_reg;
                    phi  <= a_shift[31:16] * b_reg;
                    if (acc_en) acc <= acc + shifted_reg;
                    else        acc_en <= 1'b1;
                    state <= S_ITER_MULL;
                end

                // ---- v2.2 迭代拍 B ----
                // 用刚寄存的 plo/phi 合成 partial, 按 cnt 移位后存入 shifted_reg
                S_ITER_MULL: begin
                    done        <= 1'b0;
                    shifted_reg <= shifted;      // 依赖 plo/phi (上一拍稳定) 与 cnt
                    a_shift     <= a_shift >> 32; // 为下一次迭代准备
                    if (cnt == 3'd7) begin
                        state <= S_ITER_FIN;     // 最后一轮: 再一拍做 acc 累加
                    end else begin
                        cnt   <= cnt + 1'b1;
                        state <= S_ITER_MUL0;
                    end
                end

                // ---- v2.2 收尾拍: 第 7 轮的 acc 累加 ----
                S_ITER_FIN: begin
                    done   <= 1'b0;
                    acc    <= acc + shifted_reg;
                    cnt    <= 3'd0;
                    acc_en <= 1'b0;
                    state  <= S_TRANS;
                end

                // Phase 转换: 捕获 acc (上周期已稳定), 设置下 phase 参数
                S_TRANS: begin
                    done <= 1'b0;
                    case (phase)
                        2'd0: begin
                            t_reg   <= acc;              // 捕获 t = a*b
                            b_reg   <= NEG_P_INV;        // 下 phase 右操作数
                            acc     <= 512'd0;           // 清零累加器
                            cnt     <= 3'd0;             // 重置计数
                            phase   <= 2'd1;             // 切换到 Phase 1
                            state   <= S_TRANS2;         // 下一拍设置 a_shift
                        end
                        2'd1: begin
                            m_reg   <= acc[255:0];       // 捕获 m = t_low*INV
                            b_reg   <= P;                // 下 phase 右操作数
                            acc     <= 512'd0;
                            cnt     <= 3'd0;
                            phase   <= 2'd2;             // 切换到 Phase 2
                            state   <= S_TRANS2;
                        end
                        2'd2: begin
                            mp_reg  <= acc;              // 捕获 mp = m*P
                            state   <= S_REDUCE;         // 直接进入 reduce
                        end
                        default: state <= S_REDUCE;
                    endcase
                end

                // Phase 转换续: t_reg/m_reg 已稳定, 设置 a_shift
                S_TRANS2: begin
                    done <= 1'b0;
                    case (phase)
                        2'd1: a_shift <= t_reg[255:0];  // Phase 1: a = t_low
                        2'd2: a_shift <= m_reg;          // Phase 2: a = m
                        default: a_shift <= 256'd0;
                    endcase
                    acc_en <= 1'b0;
                    state  <= S_ITER_MUL0;
                end

                // ---- v2.3 reduce 拍 1: 低半 256 位求和 (进位留在 bit256) ----
                S_REDUCE: begin
                    done   <= 1'b0;
                    sum_lo <= {1'b0, t_reg[255:0]} + {1'b0, mp_reg[255:0]};
                    state  <= S_REDUCE2;
                end

                // ---- v2.3 reduce 拍 2: 高半 256 位求和 (含低半进位) ----
                S_REDUCE2: begin
                    done   <= 1'b0;
                    sum_hi <= {1'b0, t_reg[511:256]} + {1'b0, mp_reg[511:256]}
                              + sum_lo[256];
                    state  <= S_REDUCE3;
                end

                // ---- v2.3 reduce 拍 3: 条件减 P ----
                // ge_p 由减法进位导出, Vivado 会复用同一个减法器
                S_REDUCE3: begin
                    done    <= 1'b0;
                    u_sub_r <= sum_hi - p_ext;
                    ge_p_r  <= (sum_hi >= p_ext);
                    state   <= S_DONE;
                end

                S_DONE: begin
                    result <= ge_p_r ? u_sub_r[255:0] : sum_hi[255:0];
                    done   <= 1'b1;
                    state  <= S_IDLE;
                end

                default: begin
                    done  <= 1'b0;
                    state <= S_IDLE;
                end
            endcase
        end
    end

    assign busy = (state != S_IDLE);

endmodule
