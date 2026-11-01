// =============================================================================
// sm4_engine_masked_v2_pipe.v -- SM4 引擎级掩码表重计算 (B-3 + 流水线版)
// =============================================================================
// 版本: 1.2  (v1.2: B-5 时序收敛 — advance_2_rounds 拆为 2 级流水线)
// 日期: 2026-10-07
// 设计: 齐流晶 (FPGA Full-Flow Lead)
// 基线: rtl/sm4/sm4_engine_masked_v2.v (v1.1, 654 行, B-3 64/64 + B-4 49/49 PASS)
//
// 【B-5 时序收敛修改】
//   原 advance_2_rounds() 是 2 轮 SM4 组合串联 (23 级逻辑),
//   P&R 实测 WNS = -7.906 ns (Fmax ~55.8 MHz, 目标 100 MHz)。
//   本版把 2 轮拆成 2 级流水线:
//     - 新增 pipe_s1[127:0] (第 1 轮结果寄存器)
//     - 新增 dp_phase (0=计算第1轮, 1=计算第2轮)
//     - S_DP 从 16 周期变为 32 周期 (每 2 周期推进 2 轮)
//     - 总延迟: 34 → 50 cycles (+16, 可接受)
//   预期: 每级 ~12 级逻辑, Fmax > 100 MHz
//
// 【功能等价性】
//   与 sm4_engine_masked_v2.v 逐 bit 等价 (masked_en=0 时与 sm4_engine_sys 一致)。
//   仅延迟增加 16 cycles, 数据通路数值不变。
//   B-3 (64/64) 和 B-4 (49/49) 回归需在新 TB 上重跑。
// =============================================================================

`timescale 1ns / 1ps

module sm4_engine_masked_v2_pipe (
    input  wire         clk,
    input  wire         rst_n,

    // 命令接口 (与 sm4_engine_masked_v2 完全一致)
    input  wire         start,
    input  wire [127:0] key,
    input  wire [127:0] plaintext,
    input  wire         decrypt,
    input  wire [127:0] ciphertext,

    // 结果输出 (与 sm4_engine_masked_v2 完全一致)
    output wire [127:0] result,
    output reg          done,
    output wire         busy,

    // B-3 掩码控制
    input  wire          masked_en,
    input  wire          sbox_mask_ext_en,
    input  wire [7:0]    sbox_mask_c_ext,
    input  wire [2047:0] sbox_mask_tbl_ext,

    // B-3 侧信道观测端口
    output wire [7:0] sbox_addr_tap,
    output wire [7:0] sbox_mask_c_tap,
    output reg        sbox_mask_valid
);

    // =========================================================================
    // 常量 (与 sm4_engine_masked_v2 一致)
    // =========================================================================
    localparam [31:0] FK0 = 32'ha3b1bac6;
    localparam [31:0] FK1 = 32'h56aa3350;
    localparam [31:0] FK2 = 32'h677d9197;
    localparam [31:0] FK3 = 32'hb27022dc;

    // =========================================================================
    // 状态机 (4 状态, 5-bit)
    // =========================================================================
    localparam [4:0] S_IDLE     = 5'd0;
    localparam [4:0] S_KEY      = 5'd1;
    localparam [4:0] S_DP       = 5'd2;
    localparam [4:0] S_OUTPUT   = 5'd3;

    reg [4:0]  fsm_state;
    reg [4:0]  k_idx;
    reg        do_decrypt;

    // 输入窗口 (128-bit, 4 word)
    reg [127:0] input_window;

    // 密钥扩展窗口 {K[i], K[i+1], K[i+2], K[i+3]}
    reg [127:0] key_window;

    // 轮密钥数组
    reg [31:0] round_keys [0:31];

    // =========================================================================
    // B-5 流水线: 单轮推进函数 (替换原 advance_2_rounds)
    // =========================================================================
    reg [127:0] pipe_val;   // 当前 4-word 窗口
    reg [127:0] pipe_s1;   // 流水线第 1 级: 第 1 轮结果
    reg [4:0]   dp_cnt;     // 数据通路迭代计数 0..15 (每计数推进 2 轮)
    reg         dp_phase;   // 0=计算第1轮, 1=计算第2轮

    // 输出缓冲
    reg [127:0] data_out;

    assign result = data_out;
    assign busy   = (fsm_state != S_IDLE);

    // 输入选择: 加密用 plaintext, 解密用 ciphertext
    wire [127:0] input_data = decrypt ? ciphertext : plaintext;

    // =========================================================================
    // rotl32 (与 sm4_engine_masked_v2 一致)
    // =========================================================================
    function [31:0] rotl32;
        input [31:0] x;
        input [4:0]  n;
        begin
            rotl32 = ({x, x} >> (6'd32 - n));
        end
    endfunction

    // =========================================================================
    // SM4 S-box (GB/T 32907-2016, 与 sm4_engine_masked_v2 一致)
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
    // B-3 掩码表重计算状态 (RSM-LUT 双缓冲, 与 sm4_engine_masked_v2 完全一致)
    // =========================================================================
    reg [7:0]  sbox_tbl_src [0:511];
    reg        sbox_buf_sel;
    reg [7:0]  sbox_c_a;
    reg [7:0]  sbox_c_b;
    reg [15:0] sbox_seed;
    reg [3:0]  sbox_mg_cnt;
    integer    gi;

    // 生成 LFSR: 原多项式 x^16+x^14+x^13+x^11+1 (周期 65535)
    wire       sbox_seed_fb  = sbox_seed[15];
    wire [15:0] sbox_seed_nxt = {sbox_seed[14:0], sbox_seed_fb} ^
                                (sbox_seed_fb ? 16'h6800 : 16'h0000);

    wire [7:0] sbox_c_new = sbox_seed_nxt[15:8];
    wire [7:0] sbox_c_active = sbox_buf_sel ? sbox_c_b : sbox_c_a;
    wire [7:0] sbox_c_tgt    = sbox_buf_sel ? sbox_c_a : sbox_c_b;
    wire [7:0] sbox_c_eff = sbox_mask_ext_en ? sbox_mask_c_ext : sbox_c_active;

    wire sbox_mg_en = masked_en & ~sbox_mask_ext_en & (fsm_state == S_KEY);

    // =========================================================================
    // B-3 掩码表读取 (组合, 与 sm4_engine_masked_v2 完全一致)
    // =========================================================================
    function [7:0] sbox_tbl_read;
        input  [7:0]    idx_msk;
        reg    [10:0]   byte_addr;
        reg    [7:0]    t_ext;
        begin
            byte_addr      = {idx_msk, 3'b000};
            t_ext          = sbox_mask_tbl_ext[byte_addr +: 8];
            sbox_tbl_read  = sbox_mask_ext_en ? t_ext :
                             sbox_tbl_src[{sbox_buf_sel, idx_msk}];
        end
    endfunction

    // =========================================================================
    // B-3 统一 S 盒查询入口 (与 sm4_engine_masked_v2 完全一致)
    // =========================================================================
    function [7:0] sbox_v2;
        input [7:0] x;
        begin
            sbox_v2 = masked_en ? sbox_tbl_read(x ^ sbox_c_eff) : sm4_sbox(x);
        end
    endfunction

    // =========================================================================
    // B-3 侧信道观测 (与 sm4_engine_masked_v2 完全一致)
    // =========================================================================
    wire [31:0] sbox_tap_tmp = input_window[31:0] ^ input_window[63:32] ^
                               input_window[95:64]  ^ round_keys[0];
    wire [7:0]  sbox_tap_idx = sbox_tap_tmp[31:24] ^ sbox_c_eff;

    assign sbox_addr_tap   = masked_en ? sbox_tap_idx : sbox_tap_tmp[31:24];
    assign sbox_mask_c_tap = sbox_c_eff;

    // =========================================================================
    // SM4 CK 常数 (与 sm4_engine_masked_v2 完全一致)
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
    // B-5 流水线核心: 单轮 SM4 推进函数 (替换原 advance_2_rounds)
    //   输入:  4-word 窗口 + 轮索引 r_idx (0..31)
    //   输出:  经过 1 轮后的新 4-word 窗口
    //   组合深度 ~12 级 (原 2 轮串联为 23 级)
    // =========================================================================
    function [127:0] advance_1_round;
        input [127:0] window;
        input [4:0]   r_idx;
        reg [31:0]    rk;
        reg [31:0]    new_word;
        reg [31:0]    tmp;
        reg [31:0]    tau;
        reg [31:0]    L;
        begin
            // 轮密钥选择 (加密/解密)
            if (do_decrypt) rk = round_keys[31 - r_idx];
            else            rk = round_keys[r_idx];

            // T 变换: tmp = X[i+3]^X[i+2]^X[i+1]^rk
            tmp = window[31:0] ^ window[63:32] ^ window[95:64] ^ rk;

            // S 盒 (4 字节并行)
            tau = {sbox_v2(tmp[31:24]),
                   sbox_v2(tmp[23:16]),
                   sbox_v2(tmp[15:8]),
                   sbox_v2(tmp[7:0])};

            // L 变换
            L = tau ^ rotl32(tau, 5'd2) ^ rotl32(tau, 5'd10) ^
                rotl32(tau, 5'd18) ^ rotl32(tau, 5'd24);

            // 新字 = X[i] ^ L
            new_word = window[127:96] ^ L;

            // 窗口前移: {X[i+1], X[i+2], X[i+3], X[i+4]}
            advance_1_round = {window[95:64], window[63:32], window[31:0], new_word};
        end
    endfunction

    // =========================================================================
    // 密钥扩展 (组合, 与 sm4_engine_masked_v2 完全一致)
    // =========================================================================
    wire [31:0] key_xors1 = key_window[95:64] ^ key_window[63:32] ^ key_window[31:0] ^ get_ck(k_idx);
    wire [31:0] key_tau1  = {sbox_v2(key_xors1[31:24]),
                            sbox_v2(key_xors1[23:16]),
                            sbox_v2(key_xors1[15:8]),
                            sbox_v2(key_xors1[7:0])};
    wire [31:0] key_Lp1   = key_tau1 ^ rotl32(key_tau1, 5'd13) ^ rotl32(key_tau1, 5'd23);
    wire [31:0] key_next1 = key_window[127:96] ^ key_Lp1;

    wire [31:0] key_xors2 = key_window[63:32] ^ key_window[31:0] ^ key_next1 ^ get_ck(k_idx+5'd1);
    wire [31:0] key_tau2  = {sbox_v2(key_xors2[31:24]),
                            sbox_v2(key_xors2[23:16]),
                            sbox_v2(key_xors2[15:8]),
                            sbox_v2(key_xors2[7:0])};
    wire [31:0] key_Lp2   = key_tau2 ^ rotl32(key_tau2, 5'd13) ^ rotl32(key_tau2, 5'd23);
    wire [31:0] key_next2 = key_window[95:64] ^ key_Lp2;

    // =========================================================================
    // FSM 主逻辑 (B-5 流水线版: S_DP 拆为 2 相)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_state    <= S_IDLE;
            k_idx        <= 5'd0;
            do_decrypt   <= 1'b0;
            input_window <= 128'd0;
            key_window   <= 128'd0;
            pipe_val     <= 128'd0;
            pipe_s1      <= 128'd0;
            dp_cnt       <= 5'd0;
            dp_phase     <= 1'b0;
            data_out     <= 128'd0;
            done         <= 1'b0;
            sbox_buf_sel    <= 1'b0;
            sbox_c_a        <= 8'hA5;
            sbox_c_b        <= 8'hA5;
            sbox_seed       <= 16'hB000;
            sbox_mg_cnt     <= 4'd0;
            sbox_mask_valid <= 1'b0;
            for (gi = 0; gi < 512; gi = gi + 1) begin
                sbox_tbl_src[gi] <= sm4_sbox(gi[7:0] ^ 8'hA5);
            end
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

                    if (masked_en & ~sbox_mask_ext_en) begin
                        sbox_seed   <= sbox_seed_nxt;
                        sbox_mg_cnt <= 4'd0;
                        if (sbox_buf_sel) sbox_c_a <= sbox_c_new;
                        else              sbox_c_b <= sbox_c_new;
                    end
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
                    fsm_state <= S_DP;
                    pipe_val  <= input_window;
                    dp_cnt    <= 5'd0;
                    dp_phase  <= 1'b0;
                end else begin
                    k_idx <= k_idx + 5'd2;
                end

                if (sbox_mg_en) begin
                    for (gi = 0; gi < 16; gi = gi + 1) begin
                        sbox_tbl_src[{~sbox_buf_sel, sbox_mg_cnt, gi[3:0]}] <=
                            sm4_sbox({sbox_mg_cnt, gi[3:0]} ^ sbox_c_tgt);
                    end
                    sbox_mg_cnt <= sbox_mg_cnt + 4'd1;
                end

                if (k_idx == 5'd30) begin
                    if (masked_en) sbox_mask_valid <= 1'b1;
                    if (masked_en & ~sbox_mask_ext_en) sbox_buf_sel <= ~sbox_buf_sel;
                end
            end

            // =================================================================
            // B-5 流水线 S_DP: 每 2 周期推进 2 轮
            //   dp_phase=0: 计算第 1 轮 → 写入 pipe_s1
            //   dp_phase=1: 计算第 2 轮 → 写入 pipe_val, dp_cnt+1
            //   轮索引: phase0 用 {dp_cnt[3:0],1'b0}, phase1 用 {dp_cnt[3:0],1'b1}
            //   总计 16×2 = 32 周期 (原 16 周期)
            // =================================================================
            S_DP: begin
                if (!dp_phase) begin
                    // Phase 0: 第 1 轮 (轮索引 = dp_cnt*2)
                    pipe_s1   <= advance_1_round(pipe_val, {dp_cnt[3:0], 1'b0});
                    dp_phase  <= 1'b1;
                end else begin
                    // Phase 1: 第 2 轮 (轮索引 = dp_cnt*2+1), 推进窗口
                    pipe_val  <= advance_1_round(pipe_s1, {dp_cnt[3:0], 1'b1});
                    dp_cnt    <= dp_cnt + 5'd1;
                    dp_phase  <= 1'b0;
                    if (dp_cnt == 5'd15) begin
                        fsm_state <= S_OUTPUT;
                    end
                end
            end

            // 尾部字序调换: {X[35], X[34], X[33], X[32]}
            S_OUTPUT: begin
                data_out <= {pipe_val[31:0],  // X[35] -> result[127:96]
                             pipe_val[63:32], // X[34] -> result[95:64]
                             pipe_val[95:64], // X[33] -> result[63:32]
                             pipe_val[127:96]}; // X[32] -> result[31:0]
                done      <= 1'b1;
                fsm_state <= S_IDLE;
            end

            default: fsm_state <= S_IDLE;
            endcase
        end
    end

endmodule