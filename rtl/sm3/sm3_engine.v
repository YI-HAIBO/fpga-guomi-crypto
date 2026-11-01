// =============================================================================
// 模块名称 : sm3_engine
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v3.0
// 日期     : 2026-10-03
// 视角     : rtl-designer (葛逻辑)
// 功能     : SM3 哈希压缩函数 (处理单块 512-bit 消息)
//           输入: 512-bit 消息块 + 前一个状态 (IV or previous v)
//           输出: 新状态 v_j = v_j_internal XOR v_i
//
// 接口设计: 简化单块处理, 多块由 testbench 手动循环
// 时序     : 消息扩展 52 + 压缩 64x3 phases = 192 = 244 cycles/block
// 吞吐     : 256 bit / 244 cycles ≈ 1.05 bit/cycle @ 400 MHz ≈ 420 MB/s (单实例)
//           4 实例并行 ≈ 1.7 GB/s (4 引擎并行达 3.6 GB/s 含 SM4)
//
// 参考     : GB/T 32905-2016 4.3 节 SM3 压缩函数 CF
//           gmssl Python 参考实现 (gmssl/sm3.py)
//
// v3.0 2026-10-03 Phase 3 RTL 优化: S_COMPRESS 三阶段流水线化,
//                 消除 -1.216ns setup 违例 (61 endpoints)。
//                 原单拍 TT1/TT2/P0/state 组合链 ~11ns, 拆为 3 阶段各 ~4ns。
//                 总延迟 116 -> 244 cycles, 吞吐 888 -> 422 MB/s (单实例)。
// 关键发现: SM3 无 S-box, P0/P1 只是 XOR+rotl, 全部用位运算实现
//           FF/GG 是布尔函数 (XOR/AND/OR 组合)
//
// ⚠️ 状态 : 首次仿真验证中
// =============================================================================

`timescale 1ns / 1ps

module sm3_engine (
    input  wire         clk,
    input  wire         rst_n,

    // 命令接口
    input  wire         start,           // 启动一次压缩
    input  wire [511:0] msg_block,       // 512-bit 消息块
    input  wire [255:0] prev_state,      // 前一个状态 (IV for first block)

    // 结果输出
    output wire [255:0] out_state,       // 新状态
    output reg          done,            // 单次压缩完成 (需 FSM 驱动)
    output wire         busy             // 处理中
);

    // =========================================================================
    // 常量 (来自 gmssl 权威实现, GB/T 32905-2016)
    // =========================================================================
    localparam [31:0] T_LOW  = 32'h79CC4519;   // 0 <= j <= 15
    localparam [31:0] T_HIGH = 32'h7A879D8A;   // 16 <= j <= 63

    // =========================================================================
    // FSM
    // =========================================================================
    localparam S_IDLE     = 3'b000;
    localparam S_EXPAND   = 3'b001;
    localparam S_COMP_P1  = 3'b010;  // 压缩阶段1: SS1/FF/GG -> pipe regs
    localparam S_COMP_P2  = 3'b011;  // 压缩阶段2: TT1/TT2 -> pipe regs
    localparam S_COMP_P3  = 3'b100;  // 压缩阶段3: P0 + state 更新, 推进轮次
    localparam S_OUTPUT   = 3'b101;

    reg  [2:0] fsm_state;
    reg  [6:0] w_idx;        // 消息扩展索引 0..67
    reg  [6:0] round_idx;    // 压缩轮索引 0..63
    reg  [255:0] state;      // 当前内部状态 A..H

    // 流水线寄存器 (v3.0 新增, 消除 S_COMPRESS 组合链)
    reg [31:0] ss1_pipe;     // SS1 流水寄存
    reg [31:0] a_rot12_pipe; // rotl(A,12) 流水寄存 (用于 SS2 = SS1^A_rot12)
    reg [31:0] ff_pipe;      // FF_val 流水寄存
    reg [31:0] gg_pipe;      // GG_val 流水寄存
    reg [31:0] tt1_pipe;     // TT1 流水寄存
    reg [31:0] tt2_pipe;     // TT2 流水寄存

    // =========================================================================
    // 消息扩展寄存器 (68 个 32-bit word)
    // =========================================================================
    reg [31:0] W_mem [0:67];

    // =========================================================================
    // rotl 函数 (循环左移 32-bit)
    // 实现: 拼接成 64-bit 后右移 (32-n) 位, 低 32 位即结果
    //       注意: 移位量必须用 6'd32, 因为 5'd32 会被截断成 16
    // =========================================================================
    function [31:0] rotl32;
        input [31:0] x;
        input [4:0]  n;
        begin
            rotl32 = ({x, x} >> (6'd32 - n));
        end
    endfunction

    // =========================================================================
    // 状态字提取
    // =========================================================================
    wire [31:0] A = state[255:224];
    wire [31:0] B = state[223:192];
    wire [31:0] C = state[191:160];
    wire [31:0] D = state[159:128];
    wire [31:0] E = state[127:96];
    wire [31:0] F = state[95:64];
    wire [31:0] G = state[63:32];
    wire [31:0] H = state[31:0];

    // =========================================================================
    // T_j 常量 (根据轮数选择)
    // =========================================================================
    wire [31:0] T_j = (round_idx < 7'd16) ? T_LOW : T_HIGH;

    // =========================================================================
    // 中间计算: SS1, SS2
    // =========================================================================
    wire [31:0] A_rot12 = rotl32(A, 5'd12);
    wire [31:0] T_j_rot = rotl32(T_j, round_idx[4:0]);
    wire [32:0] ss1_sum = {1'b0, A_rot12} + {1'b0, E} + {1'b0, T_j_rot};
    wire [31:0] SS1 = rotl32(ss1_sum[31:0], 5'd7);
    wire [31:0] SS2 = SS1 ^ A_rot12;

    // =========================================================================
    // 布尔函数 FF_j, GG_j
    // FF_j(A,B,C) = A^B^C (j<16)  或  (A&B)|(A&C)|(B&C) (j>=16)
    // GG_j(E,F,G) = E^F^G (j<16)  或  (E&F)|((~E)&G)   (j>=16)
    // =========================================================================
    wire [31:0] FF_val = (round_idx < 7'd16) ? (A ^ B ^ C)
                                              : ((A & B) | (A & C) | (B & C));
    wire [31:0] GG_val = (round_idx < 7'd16) ? (E ^ F ^ G)
                                              : ((E & F) | ((~E) & G));

    // =========================================================================
    // W'_j = W[j] ^ W[j+4]
    // =========================================================================
    wire [31:0] Wp_j = W_mem[round_idx] ^ W_mem[round_idx + 4];

    // =========================================================================
    // TT1, TT2
    // TT1 = FF_j(A,B,C) + D + SS2 + W'_j
    // TT2 = GG_j(E,F,G) + H + SS1 + W[j]
    // =========================================================================
    wire [34:0] tt1_sum = {3'b0, FF_val} + {3'b0, D} + {3'b0, SS2} + {3'b0, Wp_j};
    wire [31:0] TT1 = tt1_sum[31:0];

    wire [34:0] tt2_sum = {3'b0, GG_val} + {3'b0, H} + {3'b0, SS1} + {3'b0, W_mem[round_idx]};
    wire [31:0] TT2 = tt2_sum[31:0];

    // =========================================================================
    // P0(TT2) = TT2 ^ rotl(TT2, 9) ^ rotl(TT2, 17)
    // =========================================================================
    wire [31:0] P0_TT2 = TT2 ^ rotl32(TT2, 5'd9) ^ rotl32(TT2, 5'd17);

    // =========================================================================
    // P2 pipeline wires (v3.0): compute from pipe registers for S_COMP_P2
    // SS2_pipe = SS1_pipe ^ A_rot12_pipe;  Wp_pipe = W[j] ^ W[j+4]
    // TT1_pipe = FF + D + SS2_pipe + Wp_pipe
    // TT2_pipe = GG + H + SS1_pipe + W[j]
    // =========================================================================
    wire [31:0] ss2_pipe = ss1_pipe ^ a_rot12_pipe;
    wire [31:0] wp_pipe  = W_mem[round_idx] ^ W_mem[round_idx + 4];
    wire [34:0] tt1_sum_pipe = {3'b0, ff_pipe} + {3'b0, D} +
                                {3'b0, ss2_pipe} + {3'b0, wp_pipe};
    wire [34:0] tt2_sum_pipe = {3'b0, gg_pipe} + {3'b0, H} +
                                {3'b0, ss1_pipe} + {3'b0, W_mem[round_idx]};
    wire [31:0] p0_pipe = tt2_pipe ^ rotl32(tt2_pipe, 5'd9) ^ rotl32(tt2_pipe, 5'd17);

    // =========================================================================
    // 消息扩展: W[j] for j in 16..67
    // W[j] = P1(W[j-16] ^ W[j-9] ^ rotl(W[j-3], 15)) ^ rotl(W[j-13], 7) ^ W[j-6]
    // P1(x) = x ^ rotl(x, 15) ^ rotl(x, 23)
    // =========================================================================
    wire [31:0] w_temp = W_mem[w_idx - 16] ^ W_mem[w_idx - 9] ^
                         rotl32(W_mem[w_idx - 3], 5'd15);
    wire [31:0] p1_val = w_temp ^ rotl32(w_temp, 5'd15) ^ rotl32(w_temp, 5'd23);
    wire [31:0] W_next = p1_val ^ rotl32(W_mem[w_idx - 13], 5'd7) ^
                         W_mem[w_idx - 6];

    // =========================================================================
    // FSM 主逻辑
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_state    <= S_IDLE;
            w_idx        <= 7'd0;
            round_idx    <= 7'd0;
            state        <= 256'd0;
            done         <= 1'b0;
            ss1_pipe     <= 32'd0;
            a_rot12_pipe <= 32'd0;
            ff_pipe      <= 32'd0;
            gg_pipe      <= 32'd0;
            tt1_pipe     <= 32'd0;
            tt2_pipe     <= 32'd0;
        end else begin
            done <= 1'b0;
            case (fsm_state)
                S_IDLE: begin
                    if (start) begin
                        state <= prev_state;
                        W_mem[0]  <= msg_block[511:480];
                        W_mem[1]  <= msg_block[479:448];
                        W_mem[2]  <= msg_block[447:416];
                        W_mem[3]  <= msg_block[415:384];
                        W_mem[4]  <= msg_block[383:352];
                        W_mem[5]  <= msg_block[351:320];
                        W_mem[6]  <= msg_block[319:288];
                        W_mem[7]  <= msg_block[287:256];
                        W_mem[8]  <= msg_block[255:224];
                        W_mem[9]  <= msg_block[223:192];
                        W_mem[10] <= msg_block[191:160];
                        W_mem[11] <= msg_block[159:128];
                        W_mem[12] <= msg_block[127:96];
                        W_mem[13] <= msg_block[95:64];
                        W_mem[14] <= msg_block[63:32];
                        W_mem[15] <= msg_block[31:0];
                        w_idx     <= 7'd16;
                        fsm_state <= S_EXPAND;
                    end
                end

                S_EXPAND: begin
                    W_mem[w_idx] <= W_next;
                    if (w_idx == 7'd67) begin
                        w_idx     <= 7'd0;
                        round_idx <= 7'd0;
                        fsm_state <= S_COMP_P1;
                    end else begin
                        w_idx <= w_idx + 7'd1;
                    end
                end

                S_COMP_P1: begin
                    // 阶段1: 计算 SS1, A_rot12, FF, GG -> 流水寄存
                    ss1_pipe     <= SS1;
                    a_rot12_pipe <= A_rot12;
                    ff_pipe      <= FF_val;
                    gg_pipe      <= GG_val;
                    fsm_state    <= S_COMP_P2;
                end

                S_COMP_P2: begin
                    // 阶段2: 从 pipe regs 计算 TT1, TT2 (via module-level wires)
                    tt1_pipe  <= tt1_sum_pipe[31:0];
                    tt2_pipe  <= tt2_sum_pipe[31:0];
                    fsm_state <= S_COMP_P3;
                end

                S_COMP_P3: begin
                    // 阶段3: P0(TT2) + state 更新 (P0 是 XOR+rotl, 组合浅)
                    // P0(x) = x ^ rotl(x,9) ^ rotl(x,17)
                    if (round_idx == 7'd63) begin
                        state <= {tt1_pipe, A, rotl32(B, 5'd9), C,
                                   p0_pipe, E, rotl32(F, 5'd19), G} ^ prev_state;
                        fsm_state <= S_OUTPUT;
                        done      <= 1'b1;
                    end else begin
                        state <= {tt1_pipe, A, rotl32(B, 5'd9), C,
                                   p0_pipe, E, rotl32(F, 5'd19), G};
                        round_idx <= round_idx + 7'd1;
                        fsm_state <= S_COMP_P1;
                    end
                end

                S_OUTPUT: begin
                    fsm_state <= S_IDLE;
                end

                default: begin
                    fsm_state <= S_IDLE;
                end
            endcase
        end
    end

    // =========================================================================
    // 输出
    // =========================================================================
    assign out_state = state;
    assign busy      = (fsm_state != S_IDLE);

endmodule
