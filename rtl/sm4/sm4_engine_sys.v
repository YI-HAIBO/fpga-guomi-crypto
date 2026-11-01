// =============================================================================
// 模块名称 : sm4_engine_sys
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v4.0 (Phase 0.5.1 密钥扩展流水优化)
// 日期     : 2026-10-04
// 视角     : rtl-designer (葛逻辑)
// 功能     : SM4 分组密码引擎 - 16-stage systolic + 2-keywords/cycle 密钥扩展
//           - 16 流水线阶段, 每阶段 2 轮组合计算
//           - 密钥扩展每 cycle 产出 2 个 word (2 个 T' 串行, ~20 级逻辑)
//           - 密钥扩展 32 -> 16 cycles (加速 2x)
//           - 分组阶段 32 -> 16 cycles (加速 2x)
//           - 首块延迟 33 cycles (baseline 64, 加速 1.94x)
//
// 版本历史:
//   v1.0 (2026-10-04): 4-stage × 8 轮, Phase 3 Setup -17.237ns 严重违例
//   v2.0 (2026-10-04): 8-stage × 4 轮, Phase 3 Setup -3.809ns 仍违例
//   v3.0 (2026-10-04): 16-stage × 2 轮, Phase 3 Setup +2.121ns 达标
//   v4.0 (2026-10-04): 密钥扩展 2 keywords/cycle, 延迟 49→33 cycles
//                      (见 docs/Phase3_SM4_SystolicArray_增量综合_v1.md)
//
// 接口设计: 与 sm4_engine v1.0 完全一致 (接口 100% 兼容)
//           便于 sm4_trng_subsys 通过参数开关切换架构
//
// 参考     : GB/T 32907-2016 信息 安全技术 SM4 分组加密算法
//           docs/Phase0_5_SM4_SystolicArray_微规格书_v1.md (已签核)
//           docs/Phase1_SM4_SystolicArray_微架构_v1.md (含 Phase 3 修正)
//           docs/Phase3_SM4_SystolicArray_增量综合_v1.md (v1.0/v2.0 时序违例分析)
//
// 数据流  : S_IDLE -> S_KEY(32) -> S_C0..S_C15(16) -> S_OUTPUT -> S_IDLE
//           每 stage 2 轮, systolic 结构
//
// 关键设计: 每 stage 用一个 128-bit 寄存器存储窗口 {X[i], X[i+1], X[i+2], X[i+3]}
//           窗口推进由 advance_2_rounds 函数完成 (2 轮串行组合)
//           尾部字序调换在 S_OUTPUT 阶段完成
// =============================================================================

`timescale 1ns / 1ps

module sm4_engine_sys (
    input  wire         clk,
    input  wire         rst_n,

    // 命令接口 (与 sm4_engine v1.0 完全一致)
    input  wire         start,
    input  wire [127:0] key,
    input  wire [127:0] plaintext,
    input  wire         decrypt,
    input  wire [127:0] ciphertext,

    // 结果输出 (与 sm4_engine v1.0 完全一致)
    output wire [127:0] result,
    output reg          done,
    output wire         busy
);

    // =========================================================================
    // 常量 (与 sm4_engine.v v1.0 一致)
    // =========================================================================
    localparam [31:0] FK0 = 32'ha3b1bac6;
    localparam [31:0] FK1 = 32'h56aa3350;
    localparam [31:0] FK2 = 32'h677d9197;
    localparam [31:0] FK3 = 32'hb27022dc;

    // =========================================================================
    // 状态机 (16-stage: S_C0..S_C15, 共 18 状态, 5-bit)
    // =========================================================================
    localparam [4:0] S_IDLE     = 5'd0;
    localparam [4:0] S_KEY      = 5'd1;
    localparam [4:0] S_C0       = 5'd2;
    localparam [4:0] S_C1       = 5'd3;
    localparam [4:0] S_C2       = 5'd4;
    localparam [4:0] S_C3       = 5'd5;
    localparam [4:0] S_C4       = 5'd6;
    localparam [4:0] S_C5       = 5'd7;
    localparam [4:0] S_C6       = 5'd8;
    localparam [4:0] S_C7       = 5'd9;
    localparam [4:0] S_C8       = 5'd10;
    localparam [4:0] S_C9       = 5'd11;
    localparam [4:0] S_C10      = 5'd12;
    localparam [4:0] S_C11      = 5'd13;
    localparam [4:0] S_C12      = 5'd14;
    localparam [4:0] S_C13      = 5'd15;
    localparam [4:0] S_C14      = 5'd16;
    localparam [4:0] S_C15      = 5'd17;
    localparam [4:0] S_OUTPUT   = 5'd18;

    reg [4:0]  fsm_state;
    reg [4:0]  k_idx;         // 密钥扩展索引 0..31
    reg        do_decrypt;    // 解密标志 (启动时锁存)

    // 输入窗口 (128-bit, 4 word)
    reg [127:0] input_window;

    // 密钥扩展窗口 {K[i], K[i+1], K[i+2], K[i+3]}
    reg [127:0] key_window;

    // 轮密钥数组
    reg [31:0] round_keys [0:31];

    // Systolic 流水线窗口寄存器 (16 个 stage)
    reg [127:0] pipe_w0;    // 2 轮后窗口 {X[2],  X[3],  X[4],  X[5]}
    reg [127:0] pipe_w1;    // 4 轮后窗口 {X[4],  X[5],  X[6],  X[7]}
    reg [127:0] pipe_w2;    // 6 轮后窗口 {X[6],  X[7],  X[8],  X[9]}
    reg [127:0] pipe_w3;    // 8 轮后窗口 {X[8],  X[9],  X[10], X[11]}
    reg [127:0] pipe_w4;    // 10 轮后窗口 {X[10], X[11], X[12], X[13]}
    reg [127:0] pipe_w5;    // 12 轮后窗口 {X[12], X[13], X[14], X[15]}
    reg [127:0] pipe_w6;    // 14 轮后窗口 {X[14], X[15], X[16], X[17]}
    reg [127:0] pipe_w7;    // 16 轮后窗口 {X[16], X[17], X[18], X[19]}
    reg [127:0] pipe_w8;    // 18 轮后窗口 {X[18], X[19], X[20], X[21]}
    reg [127:0] pipe_w9;    // 20 轮后窗口 {X[20], X[21], X[22], X[23]}
    reg [127:0] pipe_w10;   // 22 轮后窗口 {X[22], X[23], X[24], X[25]}
    reg [127:0] pipe_w11;   // 24 轮后窗口 {X[24], X[25], X[26], X[27]}
    reg [127:0] pipe_w12;   // 26 轮后窗口 {X[26], X[27], X[28], X[29]}
    reg [127:0] pipe_w13;   // 28 轮后窗口 {X[28], X[29], X[30], X[31]}
    reg [127:0] pipe_w14;   // 30 轮后窗口 {X[30], X[31], X[32], X[33]}
    reg [127:0] pipe_w15;   // 32 轮后窗口 {X[32], X[33], X[34], X[35]}

    // 输出缓冲
    reg [127:0] data_out;

    assign result = data_out;
    assign busy   = (fsm_state != S_IDLE);

    // 输入选择: 加密用 plaintext, 解密用 ciphertext
    wire [127:0] input_data = decrypt ? ciphertext : plaintext;

    // =========================================================================
    // rotl32 (与 sm4_engine.v 一致)
    // =========================================================================
    function [31:0] rotl32;
        input [31:0] x;
        input [4:0]  n;
        begin
            rotl32 = ({x, x} >> (6'd32 - n));
        end
    endfunction

    // =========================================================================
    // SM4 S-box (GB/T 32907-2016, 与 sm4_engine.v 一致)
    // =========================================================================
    function [7:0] sm4_sbox;
        input [7:0] x;
        begin
            case (x)
                8'h00: sm4_sbox = 8'hd6;  8'h01: sm4_sbox = 8'h90;
                8'h02: sm4_sbox = 8'he9;  8'h03: sm4_sbox = 8'hfe;
                8'h04: sm4_sbox = 8'hcc;  8'h05: sm4_sbox = 8'he1;
                8'h06: sm4_sbox = 8'h3d;  8'h07: sm4_sbox = 8'hb7;
                8'h08: sm4_sbox = 8'h16;  8'h09: sm4_sbox = 8'hb6;
                8'h0a: sm4_sbox = 8'h14;  8'h0b: sm4_sbox = 8'hc2;
                8'h0c: sm4_sbox = 8'h28;  8'h0d: sm4_sbox = 8'hfb;
                8'h0e: sm4_sbox = 8'h2c;  8'h0f: sm4_sbox = 8'h05;
                8'h10: sm4_sbox = 8'h2b;  8'h11: sm4_sbox = 8'h67;
                8'h12: sm4_sbox = 8'h9a;  8'h13: sm4_sbox = 8'h76;
                8'h14: sm4_sbox = 8'h2a;  8'h15: sm4_sbox = 8'hbe;
                8'h16: sm4_sbox = 8'h04;  8'h17: sm4_sbox = 8'hc3;
                8'h18: sm4_sbox = 8'haa;  8'h19: sm4_sbox = 8'h44;
                8'h1a: sm4_sbox = 8'h13;  8'h1b: sm4_sbox = 8'h26;
                8'h1c: sm4_sbox = 8'h49;  8'h1d: sm4_sbox = 8'h86;
                8'h1e: sm4_sbox = 8'h06;  8'h1f: sm4_sbox = 8'h99;
                8'h20: sm4_sbox = 8'h9c;  8'h21: sm4_sbox = 8'h42;
                8'h22: sm4_sbox = 8'h50;  8'h23: sm4_sbox = 8'hf4;
                8'h24: sm4_sbox = 8'h91;  8'h25: sm4_sbox = 8'hef;
                8'h26: sm4_sbox = 8'h98;  8'h27: sm4_sbox = 8'h7a;
                8'h28: sm4_sbox = 8'h33;  8'h29: sm4_sbox = 8'h54;
                8'h2a: sm4_sbox = 8'h0b;  8'h2b: sm4_sbox = 8'h43;
                8'h2c: sm4_sbox = 8'hed;  8'h2d: sm4_sbox = 8'hcf;
                8'h2e: sm4_sbox = 8'hac;  8'h2f: sm4_sbox = 8'h62;
                8'h30: sm4_sbox = 8'he4;  8'h31: sm4_sbox = 8'hb3;
                8'h32: sm4_sbox = 8'h1c;  8'h33: sm4_sbox = 8'ha9;
                8'h34: sm4_sbox = 8'hc9;  8'h35: sm4_sbox = 8'h08;
                8'h36: sm4_sbox = 8'he8;  8'h37: sm4_sbox = 8'h95;
                8'h38: sm4_sbox = 8'h80;  8'h39: sm4_sbox = 8'hdf;
                8'h3a: sm4_sbox = 8'h94;  8'h3b: sm4_sbox = 8'hfa;
                8'h3c: sm4_sbox = 8'h75;  8'h3d: sm4_sbox = 8'h8f;
                8'h3e: sm4_sbox = 8'h3f;  8'h3f: sm4_sbox = 8'ha6;
                8'h40: sm4_sbox = 8'h47;  8'h41: sm4_sbox = 8'h07;
                8'h42: sm4_sbox = 8'ha7;  8'h43: sm4_sbox = 8'hfc;
                8'h44: sm4_sbox = 8'hf3;  8'h45: sm4_sbox = 8'h73;
                8'h46: sm4_sbox = 8'h17;  8'h47: sm4_sbox = 8'hba;
                8'h48: sm4_sbox = 8'h83;  8'h49: sm4_sbox = 8'h59;
                8'h4a: sm4_sbox = 8'h3c;  8'h4b: sm4_sbox = 8'h19;
                8'h4c: sm4_sbox = 8'he6;  8'h4d: sm4_sbox = 8'h85;
                8'h4e: sm4_sbox = 8'h4f;  8'h4f: sm4_sbox = 8'ha8;
                8'h50: sm4_sbox = 8'h68;  8'h51: sm4_sbox = 8'h6b;
                8'h52: sm4_sbox = 8'h81;  8'h53: sm4_sbox = 8'hb2;
                8'h54: sm4_sbox = 8'h71;  8'h55: sm4_sbox = 8'h64;
                8'h56: sm4_sbox = 8'hda;  8'h57: sm4_sbox = 8'h8b;
                8'h58: sm4_sbox = 8'hf8;  8'h59: sm4_sbox = 8'heb;
                8'h5a: sm4_sbox = 8'h0f;  8'h5b: sm4_sbox = 8'h4b;
                8'h5c: sm4_sbox = 8'h70;  8'h5d: sm4_sbox = 8'h56;
                8'h5e: sm4_sbox = 8'h9d;  8'h5f: sm4_sbox = 8'h35;
                8'h60: sm4_sbox = 8'h1e;  8'h61: sm4_sbox = 8'h24;
                8'h62: sm4_sbox = 8'h0e;  8'h63: sm4_sbox = 8'h5e;
                8'h64: sm4_sbox = 8'h63;  8'h65: sm4_sbox = 8'h58;
                8'h66: sm4_sbox = 8'hd1;  8'h67: sm4_sbox = 8'ha2;
                8'h68: sm4_sbox = 8'h25;  8'h69: sm4_sbox = 8'h22;
                8'h6a: sm4_sbox = 8'h7c;  8'h6b: sm4_sbox = 8'h3b;
                8'h6c: sm4_sbox = 8'h01;  8'h6d: sm4_sbox = 8'h21;
                8'h6e: sm4_sbox = 8'h78;  8'h6f: sm4_sbox = 8'h87;
                8'h70: sm4_sbox = 8'hd4;  8'h71: sm4_sbox = 8'h00;
                8'h72: sm4_sbox = 8'h46;  8'h73: sm4_sbox = 8'h57;
                8'h74: sm4_sbox = 8'h9f;  8'h75: sm4_sbox = 8'hd3;
                8'h76: sm4_sbox = 8'h27;  8'h77: sm4_sbox = 8'h52;
                8'h78: sm4_sbox = 8'h4c;  8'h79: sm4_sbox = 8'h36;
                8'h7a: sm4_sbox = 8'h02;  8'h7b: sm4_sbox = 8'he7;
                8'h7c: sm4_sbox = 8'ha0;  8'h7d: sm4_sbox = 8'hc4;
                8'h7e: sm4_sbox = 8'hc8;  8'h7f: sm4_sbox = 8'h9e;
                8'h80: sm4_sbox = 8'hea;  8'h81: sm4_sbox = 8'hbf;
                8'h82: sm4_sbox = 8'h8a;  8'h83: sm4_sbox = 8'hd2;
                8'h84: sm4_sbox = 8'h40;  8'h85: sm4_sbox = 8'hc7;
                8'h86: sm4_sbox = 8'h38;  8'h87: sm4_sbox = 8'hb5;
                8'h88: sm4_sbox = 8'ha3;  8'h89: sm4_sbox = 8'hf7;
                8'h8a: sm4_sbox = 8'hf2;  8'h8b: sm4_sbox = 8'hce;
                8'h8c: sm4_sbox = 8'hf9;  8'h8d: sm4_sbox = 8'h61;
                8'h8e: sm4_sbox = 8'h15;  8'h8f: sm4_sbox = 8'ha1;
                8'h90: sm4_sbox = 8'he0;  8'h91: sm4_sbox = 8'hae;
                8'h92: sm4_sbox = 8'h5d;  8'h93: sm4_sbox = 8'ha4;
                8'h94: sm4_sbox = 8'h9b;  8'h95: sm4_sbox = 8'h34;
                8'h96: sm4_sbox = 8'h1a;  8'h97: sm4_sbox = 8'h55;
                8'h98: sm4_sbox = 8'had;  8'h99: sm4_sbox = 8'h93;
                8'h9a: sm4_sbox = 8'h32;  8'h9b: sm4_sbox = 8'h30;
                8'h9c: sm4_sbox = 8'hf5;  8'h9d: sm4_sbox = 8'h8c;
                8'h9e: sm4_sbox = 8'hb1;  8'h9f: sm4_sbox = 8'he3;
                8'ha0: sm4_sbox = 8'h1d;  8'ha1: sm4_sbox = 8'hf6;
                8'ha2: sm4_sbox = 8'he2;  8'ha3: sm4_sbox = 8'h2e;
                8'ha4: sm4_sbox = 8'h82;  8'ha5: sm4_sbox = 8'h66;
                8'ha6: sm4_sbox = 8'hca;  8'ha7: sm4_sbox = 8'h60;
                8'ha8: sm4_sbox = 8'hc0;  8'ha9: sm4_sbox = 8'h29;
                8'haa: sm4_sbox = 8'h23;  8'hab: sm4_sbox = 8'hab;
                8'hac: sm4_sbox = 8'h0d;  8'had: sm4_sbox = 8'h53;
                8'hae: sm4_sbox = 8'h4e;  8'haf: sm4_sbox = 8'h6f;
                8'hb0: sm4_sbox = 8'hd5;  8'hb1: sm4_sbox = 8'hdb;
                8'hb2: sm4_sbox = 8'h37;  8'hb3: sm4_sbox = 8'h45;
                8'hb4: sm4_sbox = 8'hde;  8'hb5: sm4_sbox = 8'hfd;
                8'hb6: sm4_sbox = 8'h8e;  8'hb7: sm4_sbox = 8'h2f;
                8'hb8: sm4_sbox = 8'h03;  8'hb9: sm4_sbox = 8'hff;
                8'hba: sm4_sbox = 8'h6a;  8'hbb: sm4_sbox = 8'h72;
                8'hbc: sm4_sbox = 8'h6d;  8'hbd: sm4_sbox = 8'h6c;
                8'hbe: sm4_sbox = 8'h5b;  8'hbf: sm4_sbox = 8'h51;
                8'hc0: sm4_sbox = 8'h8d;  8'hc1: sm4_sbox = 8'h1b;
                8'hc2: sm4_sbox = 8'haf;  8'hc3: sm4_sbox = 8'h92;
                8'hc4: sm4_sbox = 8'hbb;  8'hc5: sm4_sbox = 8'hdd;
                8'hc6: sm4_sbox = 8'hbc;  8'hc7: sm4_sbox = 8'h7f;
                8'hc8: sm4_sbox = 8'h11;  8'hc9: sm4_sbox = 8'hd9;
                8'hca: sm4_sbox = 8'h5c;  8'hcb: sm4_sbox = 8'h41;
                8'hcc: sm4_sbox = 8'h1f;  8'hcd: sm4_sbox = 8'h10;
                8'hce: sm4_sbox = 8'h5a;  8'hcf: sm4_sbox = 8'hd8;
                8'hd0: sm4_sbox = 8'h0a;  8'hd1: sm4_sbox = 8'hc1;
                8'hd2: sm4_sbox = 8'h31;  8'hd3: sm4_sbox = 8'h88;
                8'hd4: sm4_sbox = 8'ha5;  8'hd5: sm4_sbox = 8'hcd;
                8'hd6: sm4_sbox = 8'h7b;  8'hd7: sm4_sbox = 8'hbd;
                8'hd8: sm4_sbox = 8'h2d;  8'hd9: sm4_sbox = 8'h74;
                8'hda: sm4_sbox = 8'hd0;  8'hdb: sm4_sbox = 8'h12;
                8'hdc: sm4_sbox = 8'hb8;  8'hdd: sm4_sbox = 8'he5;
                8'hde: sm4_sbox = 8'hb4;  8'hdf: sm4_sbox = 8'hb0;
                8'he0: sm4_sbox = 8'h89;  8'he1: sm4_sbox = 8'h69;
                8'he2: sm4_sbox = 8'h97;  8'he3: sm4_sbox = 8'h4a;
                8'he4: sm4_sbox = 8'h0c;  8'he5: sm4_sbox = 8'h96;
                8'he6: sm4_sbox = 8'h77;  8'he7: sm4_sbox = 8'h7e;
                8'he8: sm4_sbox = 8'h65;  8'he9: sm4_sbox = 8'hb9;
                8'hea: sm4_sbox = 8'hf1;  8'heb: sm4_sbox = 8'h09;
                8'hec: sm4_sbox = 8'hc5;  8'hed: sm4_sbox = 8'h6e;
                8'hee: sm4_sbox = 8'hc6;  8'hef: sm4_sbox = 8'h84;
                8'hf0: sm4_sbox = 8'h18;  8'hf1: sm4_sbox = 8'hf0;
                8'hf2: sm4_sbox = 8'h7d;  8'hf3: sm4_sbox = 8'hec;
                8'hf4: sm4_sbox = 8'h3a;  8'hf5: sm4_sbox = 8'hdc;
                8'hf6: sm4_sbox = 8'h4d;  8'hf7: sm4_sbox = 8'h20;
                8'hf8: sm4_sbox = 8'h79;  8'hf9: sm4_sbox = 8'hee;
                8'hfa: sm4_sbox = 8'h5f;  8'hfb: sm4_sbox = 8'h3e;
                8'hfc: sm4_sbox = 8'hd7;  8'hfd: sm4_sbox = 8'hcb;
                8'hfe: sm4_sbox = 8'h39;  8'hff: sm4_sbox = 8'h48;
                default: sm4_sbox = 8'h00;
            endcase
        end
    endfunction

    // =========================================================================
    // SM4 CK 常数 (与 sm4_engine.v 一致)
    // =========================================================================
    function [31:0] get_ck;
        input [4:0] i;
        begin
            case (i)
                5'd0:  get_ck = 32'h00070e15;
                5'd1:  get_ck = 32'h1c232a31;
                5'd2:  get_ck = 32'h383f464d;
                5'd3:  get_ck = 32'h545b6269;
                5'd4:  get_ck = 32'h70777e85;
                5'd5:  get_ck = 32'h8c939aa1;
                5'd6:  get_ck = 32'ha8afb6bd;
                5'd7:  get_ck = 32'hc4cbd2d9;
                5'd8:  get_ck = 32'he0e7eef5;
                5'd9:  get_ck = 32'hfc030a11;
                5'd10: get_ck = 32'h181f262d;
                5'd11: get_ck = 32'h343b4249;
                5'd12: get_ck = 32'h50575e65;
                5'd13: get_ck = 32'h6c737a81;
                5'd14: get_ck = 32'h888f969d;
                5'd15: get_ck = 32'ha4abb2b9;
                5'd16: get_ck = 32'hc0c7ced5;
                5'd17: get_ck = 32'hdce3eaf1;
                5'd18: get_ck = 32'hf8ff060d;
                5'd19: get_ck = 32'h141b2229;
                5'd20: get_ck = 32'h30373e45;
                5'd21: get_ck = 32'h4c535a61;
                5'd22: get_ck = 32'h686f767d;
                5'd23: get_ck = 32'h848b9299;
                5'd24: get_ck = 32'ha0a7aeb5;
                5'd25: get_ck = 32'hbcc3cad1;
                5'd26: get_ck = 32'hd8dfe6ed;
                5'd27: get_ck = 32'hf4fb0209;
                5'd28: get_ck = 32'h10171e25;
                5'd29: get_ck = 32'h2c333a41;
                5'd30: get_ck = 32'h484f565d;
                5'd31: get_ck = 32'h646b7279;
                default: get_ck = 32'h0;
            endcase
        end
    endfunction

    // =========================================================================
    // SM4 单轮 T 变换 (组合, 与 sm4_engine.v 一致)
    // =========================================================================
    function [31:0] sm4_round;
        input [31:0] x0;  // X[i]
        input [31:0] x1;  // X[i+1]
        input [31:0] x2;  // X[i+2]
        input [31:0] x3;  // X[i+3]
        input [31:0] rk;  // rk[i]
        reg [31:0] tmp;
        reg [31:0] tau;
        reg [31:0] L;
        begin
            tmp = x3 ^ x2 ^ x1 ^ rk;
            tau = {sm4_sbox(tmp[31:24]),
                   sm4_sbox(tmp[23:16]),
                   sm4_sbox(tmp[15:8]),
                   sm4_sbox(tmp[7:0])};
            L = tau ^ rotl32(tau, 5'd2) ^ rotl32(tau, 5'd10) ^
                rotl32(tau, 5'd18) ^ rotl32(tau, 5'd24);
            sm4_round = x0 ^ L;
        end
    endfunction

    // =========================================================================
    // 2 轮窗口推进 (Systolic 核心, 2 轮组合串联)
    // 输入:  4-word 窗口 {X[i], X[i+1], X[i+2], X[i+3]}
    //        起始轮索引 r_start (0, 2, 4, ..., 30)
    // 输出:  4-word 窗口 {X[i+2], X[i+3], X[i+4], X[i+5]}
    //        即经过 2 轮后的新窗口
    //
    // 注: 单轮 T 变换在 advance_2_rounds 内内联 (避免 iverilog -g2005
    //     对嵌套函数调用的解析问题; 组合语义等价)
    // =========================================================================
    function [127:0] advance_2_rounds;
        input [127:0] window;
        input [4:0]   r_start;
        reg [127:0]   t;
        reg [1:0]     r;
        reg [31:0]    rk;
        reg [31:0]    new_word;
        reg [31:0]    tmp;
        reg [31:0]    tau;
        reg [31:0]    L;
        begin
            t = window;
            for (r = 0; r < 2; r = r + 1) begin
                if (do_decrypt) begin
                    rk = round_keys[31-(r_start+r)];
                end else begin
                    rk = round_keys[r_start+r];
                end
                // 单轮 T 变换 (内联 sm4_round)
                tmp = t[31:0] ^ t[63:32] ^ t[95:64] ^ rk;
                tau = {sm4_sbox(tmp[31:24]),
                       sm4_sbox(tmp[23:16]),
                       sm4_sbox(tmp[15:8]),
                       sm4_sbox(tmp[7:0])};
                L = tau ^ rotl32(tau, 5'd2) ^ rotl32(tau, 5'd10) ^
                    rotl32(tau, 5'd18) ^ rotl32(tau, 5'd24);
                new_word = t[127:96] ^ L;
                // 窗口前移: {X[i+1], X[i+2], X[i+3], X[i+4]}
                t = {t[95:64], t[63:32], t[31:0], new_word};
            end
            advance_2_rounds = t;
        end
    endfunction

    // =========================================================================
    // 密钥扩展 (组合, 与 sm4_engine.v 一致)
    // =========================================================================
    // =========================================================================
    // 密钥扩展 (组合逻辑, 2 keywords/cycle)
    // K[i+4] = K[i] ^ T'(K[i+1] ^ K[i+2] ^ K[i+3] ^ CK[i])
    // K[i+5] = K[i+1] ^ T'(K[i+2] ^ K[i+3] ^ K[i+4] ^ CK[i+1])
    // 注: K[i+5] 依赖 K[i+4], 两个 T' 串行 (组合深度 ~20 级)
    // =========================================================================
    // 第一个 T' -> key_next1 = K[i+4]
    wire [31:0] key_xors1 = key_window[95:64] ^ key_window[63:32] ^ key_window[31:0] ^ get_ck(k_idx);
    wire [31:0] key_tau1  = {sm4_sbox(key_xors1[31:24]),
                            sm4_sbox(key_xors1[23:16]),
                            sm4_sbox(key_xors1[15:8]),
                            sm4_sbox(key_xors1[7:0])};
    wire [31:0] key_Lp1   = key_tau1 ^ rotl32(key_tau1, 5'd13) ^ rotl32(key_tau1, 5'd23);
    wire [31:0] key_next1 = key_window[127:96] ^ key_Lp1;

    // 第二个 T' -> key_next2 = K[i+5] (依赖 key_next1)
    wire [31:0] key_xors2 = key_window[63:32] ^ key_window[31:0] ^ key_next1 ^ get_ck(k_idx+5'd1);
    wire [31:0] key_tau2  = {sm4_sbox(key_xors2[31:24]),
                            sm4_sbox(key_xors2[23:16]),
                            sm4_sbox(key_xors2[15:8]),
                            sm4_sbox(key_xors2[7:0])};
    wire [31:0] key_Lp2   = key_tau2 ^ rotl32(key_tau2, 5'd13) ^ rotl32(key_tau2, 5'd23);
    wire [31:0] key_next2 = key_window[95:64] ^ key_Lp2;

    // =========================================================================
    // FSM 主逻辑
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_state    <= S_IDLE;
            k_idx        <= 5'd0;
            do_decrypt   <= 1'b0;
            input_window <= 128'd0;
            key_window   <= 128'd0;
            pipe_w0      <= 128'd0;
            pipe_w1      <= 128'd0;
            pipe_w2      <= 128'd0;
            pipe_w3      <= 128'd0;
            pipe_w4      <= 128'd0;
            pipe_w5      <= 128'd0;
            pipe_w6      <= 128'd0;
            pipe_w7      <= 128'd0;
            pipe_w8      <= 128'd0;
            pipe_w9      <= 128'd0;
            pipe_w10     <= 128'd0;
            pipe_w11     <= 128'd0;
            pipe_w12     <= 128'd0;
            pipe_w13     <= 128'd0;
            pipe_w14     <= 128'd0;
            pipe_w15     <= 128'd0;
            data_out     <= 128'd0;
            done         <= 1'b0;
        end else begin
            done <= 1'b0;

            case (fsm_state)
            S_IDLE: begin
                if (start) begin
                    input_window <= input_data;
                    do_decrypt   <= decrypt;
                    key_window   <= {key[127:96] ^ FK0,
                                     key[95:64]  ^ FK1,
                                     key[63:32]  ^ FK2,
                                     key[31:0]   ^ FK3};
                    k_idx        <= 5'd0;
                    fsm_state    <= S_KEY;
                end
            end

            S_KEY: begin
                round_keys[k_idx]     <= key_next1;
                round_keys[k_idx+1]   <= key_next2;
                key_window <= {key_window[63:32],
                               key_window[31:0],
                               key_next1,
                               key_next2};
                if (k_idx == 5'd30) begin
                    fsm_state <= S_C0;
                end else begin
                    k_idx <= k_idx + 5'd2;
                end
            end

            // Systolic pipeline: 16 stages, 每 stage 2 轮
            S_C0: begin
                pipe_w0 <= advance_2_rounds(input_window, 5'd0);
                fsm_state <= S_C1;
            end
            S_C1: begin
                pipe_w1 <= advance_2_rounds(pipe_w0, 5'd2);
                fsm_state <= S_C2;
            end
            S_C2: begin
                pipe_w2 <= advance_2_rounds(pipe_w1, 5'd4);
                fsm_state <= S_C3;
            end
            S_C3: begin
                pipe_w3 <= advance_2_rounds(pipe_w2, 5'd6);
                fsm_state <= S_C4;
            end
            S_C4: begin
                pipe_w4 <= advance_2_rounds(pipe_w3, 5'd8);
                fsm_state <= S_C5;
            end
            S_C5: begin
                pipe_w5 <= advance_2_rounds(pipe_w4, 5'd10);
                fsm_state <= S_C6;
            end
            S_C6: begin
                pipe_w6 <= advance_2_rounds(pipe_w5, 5'd12);
                fsm_state <= S_C7;
            end
            S_C7: begin
                pipe_w7 <= advance_2_rounds(pipe_w6, 5'd14);
                fsm_state <= S_C8;
            end
            S_C8: begin
                pipe_w8 <= advance_2_rounds(pipe_w7, 5'd16);
                fsm_state <= S_C9;
            end
            S_C9: begin
                pipe_w9 <= advance_2_rounds(pipe_w8, 5'd18);
                fsm_state <= S_C10;
            end
            S_C10: begin
                pipe_w10 <= advance_2_rounds(pipe_w9, 5'd20);
                fsm_state <= S_C11;
            end
            S_C11: begin
                pipe_w11 <= advance_2_rounds(pipe_w10, 5'd22);
                fsm_state <= S_C12;
            end
            S_C12: begin
                pipe_w12 <= advance_2_rounds(pipe_w11, 5'd24);
                fsm_state <= S_C13;
            end
            S_C13: begin
                pipe_w13 <= advance_2_rounds(pipe_w12, 5'd26);
                fsm_state <= S_C14;
            end
            S_C14: begin
                pipe_w14 <= advance_2_rounds(pipe_w13, 5'd28);
                fsm_state <= S_C15;
            end
            S_C15: begin
                pipe_w15 <= advance_2_rounds(pipe_w14, 5'd30);
                fsm_state <= S_OUTPUT;
            end

            // 尾部字序调换: {X[35], X[34], X[33], X[32]}
            // pipe_w15 = {X[32], X[33], X[34], X[35]}
            // 即 pipe_w15[127:96]=X[32], [95:64]=X[33], [63:32]=X[34], [31:0]=X[35]
            S_OUTPUT: begin
                data_out <= {pipe_w15[31:0],  // X[35] -> result[127:96]
                             pipe_w15[63:32], // X[34] -> result[95:64]
                             pipe_w15[95:64], // X[33] -> result[63:32]
                             pipe_w15[127:96]}; // X[32] -> result[31:0]
                done      <= 1'b1;
                fsm_state <= S_IDLE;
            end

            default: fsm_state <= S_IDLE;
            endcase
        end
    end

endmodule
