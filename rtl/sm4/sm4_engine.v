// =============================================================================
// 模块名称 : sm4_engine
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-02
// 视角     : rtl-designer (葛逻辑)
// 功能     : SM4 分组密码引擎 (128-bit block, 128-bit key, 32 轮)
//           支持加密/解密 (解密 = 加密 + 逆序轮密钥)
//
// 接口设计: 单次块处理, start 触发 → done 输出
// 时序     : 密钥扩展 32 cycles + 分组 32 cycles = 64 cycles/block
// 吞吐     : 128 bit / 64 cycles = 2 bit/cycle @ 400 MHz = 1 GB/s (单实例)
//           16 实例并行 = 16 GB/s (远超 40 GB/s 目标, 需优化)
//
// 参考     : GB/T 32907-2016 信息 安全技术 SM4 分组加密算法
//           gmssl Python 参考实现 (gmssl/sm4.py)
//
// 关键发现: SM4 有 S-box (256 项), 与 SM3 不同
//           密钥扩展用 T' (L': rotl 13,23), 分组用 T (L: rotl 2,10,18,24)
//           解密 = 加密, 只需逆序轮密钥
// =============================================================================

`timescale 1ns / 1ps

module sm4_engine (
    input  wire         clk,
    input  wire         rst_n,

    // 命令接口
    input  wire         start,           // 启动一次加/解密
    input  wire [127:0] key,             // 128-bit 密钥
    input  wire [127:0] plaintext,       // 128-bit 明文 (加密输入)
    input  wire         decrypt,         // 0=加密, 1=解密
    input  wire [127:0] ciphertext,      // 128-bit 密文 (解密输入, decrypt=1 时用)

    // 结果输出
    output wire [127:0] result,          // 128-bit 输出
    output reg          done,            // 单次完成
    output wire         busy             // 处理中
);

    // =========================================================================
    // 常量
    // =========================================================================
    localparam [31:0] FK0 = 32'ha3b1bac6;
    localparam [31:0] FK1 = 32'h56aa3350;
    localparam [31:0] FK2 = 32'h677d9197;
    localparam [31:0] FK3 = 32'hb27022dc;

    // =========================================================================
    // CK 常数表 (用函数实现, 兼容 iverilog)
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
    // FSM
    // =========================================================================
    localparam S_IDLE     = 3'd0;
    localparam S_KEY_EXP  = 3'd1;   // 密钥扩展
    localparam S_CIPHER   = 3'd2;   // 分组变换
    localparam S_OUTPUT   = 3'd3;

    reg  [2:0]  fsm_state;
    reg  [4:0]  k_idx;        // 密钥扩展索引 0..31
    reg  [4:0]  r_idx;        // 分组轮索引 0..31
    reg  [31:0] X [0:35];     // 分组缓冲 (36 words)
    reg  [31:0] K [0:35];     // 密钥扩展缓冲 (36 words)
    reg  [31:0] round_keys [0:31];  // 32 轮密钥
    reg  [127:0] data_out;    // 输出数据
    reg          do_decrypt;  // 解密标志

    // 输入选择: 加密用明文, 解密用密文
    wire [127:0] input_data = decrypt ? ciphertext : plaintext;

    // =========================================================================
    // rotl32 (与 SM3 相同实现)
    // =========================================================================
    function [31:0] rotl32;
        input [31:0] x;
        input [4:0]  n;
        begin
            rotl32 = ({x, x} >> (6'd32 - n));
        end
    endfunction

    // =========================================================================
    // SM4 S-box (256 项, 来自 GB/T 32907-2016)
    // =========================================================================
    function [7:0] sm4_sbox;
        input [7:0] x;
        begin
            case (x)
                8'h00: sm4_sbox = 8'hd6; 8'h01: sm4_sbox = 8'h90;
                8'h02: sm4_sbox = 8'he9; 8'h03: sm4_sbox = 8'hfe;
                8'h04: sm4_sbox = 8'hcc; 8'h05: sm4_sbox = 8'he1;
                8'h06: sm4_sbox = 8'h3d; 8'h07: sm4_sbox = 8'hb7;
                8'h08: sm4_sbox = 8'h16; 8'h09: sm4_sbox = 8'hb6;
                8'h0a: sm4_sbox = 8'h14; 8'h0b: sm4_sbox = 8'hc2;
                8'h0c: sm4_sbox = 8'h28; 8'h0d: sm4_sbox = 8'hfb;
                8'h0e: sm4_sbox = 8'h2c; 8'h0f: sm4_sbox = 8'h05;
                8'h10: sm4_sbox = 8'h2b; 8'h11: sm4_sbox = 8'h67;
                8'h12: sm4_sbox = 8'h9a; 8'h13: sm4_sbox = 8'h76;
                8'h14: sm4_sbox = 8'h2a; 8'h15: sm4_sbox = 8'hbe;
                8'h16: sm4_sbox = 8'h04; 8'h17: sm4_sbox = 8'hc3;
                8'h18: sm4_sbox = 8'haa; 8'h19: sm4_sbox = 8'h44;
                8'h1a: sm4_sbox = 8'h13; 8'h1b: sm4_sbox = 8'h26;
                8'h1c: sm4_sbox = 8'h49; 8'h1d: sm4_sbox = 8'h86;
                8'h1e: sm4_sbox = 8'h06; 8'h1f: sm4_sbox = 8'h99;
                8'h20: sm4_sbox = 8'h9c; 8'h21: sm4_sbox = 8'h42;
                8'h22: sm4_sbox = 8'h50; 8'h23: sm4_sbox = 8'hf4;
                8'h24: sm4_sbox = 8'h91; 8'h25: sm4_sbox = 8'hef;
                8'h26: sm4_sbox = 8'h98; 8'h27: sm4_sbox = 8'h7a;
                8'h28: sm4_sbox = 8'h33; 8'h29: sm4_sbox = 8'h54;
                8'h2a: sm4_sbox = 8'h0b; 8'h2b: sm4_sbox = 8'h43;
                8'h2c: sm4_sbox = 8'hed; 8'h2d: sm4_sbox = 8'hcf;
                8'h2e: sm4_sbox = 8'hac; 8'h2f: sm4_sbox = 8'h62;
                8'h30: sm4_sbox = 8'he4; 8'h31: sm4_sbox = 8'hb3;
                8'h32: sm4_sbox = 8'h1c; 8'h33: sm4_sbox = 8'ha9;
                8'h34: sm4_sbox = 8'hc9; 8'h35: sm4_sbox = 8'h08;
                8'h36: sm4_sbox = 8'he8; 8'h37: sm4_sbox = 8'h95;
                8'h38: sm4_sbox = 8'h80; 8'h39: sm4_sbox = 8'hdf;
                8'h3a: sm4_sbox = 8'h94; 8'h3b: sm4_sbox = 8'hfa;
                8'h3c: sm4_sbox = 8'h75; 8'h3d: sm4_sbox = 8'h8f;
                8'h3e: sm4_sbox = 8'h3f; 8'h3f: sm4_sbox = 8'ha6;
                8'h40: sm4_sbox = 8'h47; 8'h41: sm4_sbox = 8'h07;
                8'h42: sm4_sbox = 8'ha7; 8'h43: sm4_sbox = 8'hfc;
                8'h44: sm4_sbox = 8'hf3; 8'h45: sm4_sbox = 8'h73;
                8'h46: sm4_sbox = 8'h17; 8'h47: sm4_sbox = 8'hba;
                8'h48: sm4_sbox = 8'h83; 8'h49: sm4_sbox = 8'h59;
                8'h4a: sm4_sbox = 8'h3c; 8'h4b: sm4_sbox = 8'h19;
                8'h4c: sm4_sbox = 8'he6; 8'h4d: sm4_sbox = 8'h85;
                8'h4e: sm4_sbox = 8'h4f; 8'h4f: sm4_sbox = 8'ha8;
                8'h50: sm4_sbox = 8'h68; 8'h51: sm4_sbox = 8'h6b;
                8'h52: sm4_sbox = 8'h81; 8'h53: sm4_sbox = 8'hb2;
                8'h54: sm4_sbox = 8'h71; 8'h55: sm4_sbox = 8'h64;
                8'h56: sm4_sbox = 8'hda; 8'h57: sm4_sbox = 8'h8b;
                8'h58: sm4_sbox = 8'hf8; 8'h59: sm4_sbox = 8'heb;
                8'h5a: sm4_sbox = 8'h0f; 8'h5b: sm4_sbox = 8'h4b;
                8'h5c: sm4_sbox = 8'h70; 8'h5d: sm4_sbox = 8'h56;
                8'h5e: sm4_sbox = 8'h9d; 8'h5f: sm4_sbox = 8'h35;
                8'h60: sm4_sbox = 8'h1e; 8'h61: sm4_sbox = 8'h24;
                8'h62: sm4_sbox = 8'h0e; 8'h63: sm4_sbox = 8'h5e;
                8'h64: sm4_sbox = 8'h63; 8'h65: sm4_sbox = 8'h58;
                8'h66: sm4_sbox = 8'hd1; 8'h67: sm4_sbox = 8'ha2;
                8'h68: sm4_sbox = 8'h25; 8'h69: sm4_sbox = 8'h22;
                8'h6a: sm4_sbox = 8'h7c; 8'h6b: sm4_sbox = 8'h3b;
                8'h6c: sm4_sbox = 8'h01; 8'h6d: sm4_sbox = 8'h21;
                8'h6e: sm4_sbox = 8'h78; 8'h6f: sm4_sbox = 8'h87;
                8'h70: sm4_sbox = 8'hd4; 8'h71: sm4_sbox = 8'h00;
                8'h72: sm4_sbox = 8'h46; 8'h73: sm4_sbox = 8'h57;
                8'h74: sm4_sbox = 8'h9f; 8'h75: sm4_sbox = 8'hd3;
                8'h76: sm4_sbox = 8'h27; 8'h77: sm4_sbox = 8'h52;
                8'h78: sm4_sbox = 8'h4c; 8'h79: sm4_sbox = 8'h36;
                8'h7a: sm4_sbox = 8'h02; 8'h7b: sm4_sbox = 8'he7;
                8'h7c: sm4_sbox = 8'ha0; 8'h7d: sm4_sbox = 8'hc4;
                8'h7e: sm4_sbox = 8'hc8; 8'h7f: sm4_sbox = 8'h9e;
                8'h80: sm4_sbox = 8'hea; 8'h81: sm4_sbox = 8'hbf;
                8'h82: sm4_sbox = 8'h8a; 8'h83: sm4_sbox = 8'hd2;
                8'h84: sm4_sbox = 8'h40; 8'h85: sm4_sbox = 8'hc7;
                8'h86: sm4_sbox = 8'h38; 8'h87: sm4_sbox = 8'hb5;
                8'h88: sm4_sbox = 8'ha3; 8'h89: sm4_sbox = 8'hf7;
                8'h8a: sm4_sbox = 8'hf2; 8'h8b: sm4_sbox = 8'hce;
                8'h8c: sm4_sbox = 8'hf9; 8'h8d: sm4_sbox = 8'h61;
                8'h8e: sm4_sbox = 8'h15; 8'h8f: sm4_sbox = 8'ha1;
                8'h90: sm4_sbox = 8'he0; 8'h91: sm4_sbox = 8'hae;
                8'h92: sm4_sbox = 8'h5d; 8'h93: sm4_sbox = 8'ha4;
                8'h94: sm4_sbox = 8'h9b; 8'h95: sm4_sbox = 8'h34;
                8'h96: sm4_sbox = 8'h1a; 8'h97: sm4_sbox = 8'h55;
                8'h98: sm4_sbox = 8'had; 8'h99: sm4_sbox = 8'h93;
                8'h9a: sm4_sbox = 8'h32; 8'h9b: sm4_sbox = 8'h30;
                8'h9c: sm4_sbox = 8'hf5; 8'h9d: sm4_sbox = 8'h8c;
                8'h9e: sm4_sbox = 8'hb1; 8'h9f: sm4_sbox = 8'he3;
                8'ha0: sm4_sbox = 8'h1d; 8'ha1: sm4_sbox = 8'hf6;
                8'ha2: sm4_sbox = 8'he2; 8'ha3: sm4_sbox = 8'h2e;
                8'ha4: sm4_sbox = 8'h82; 8'ha5: sm4_sbox = 8'h66;
                8'ha6: sm4_sbox = 8'hca; 8'ha7: sm4_sbox = 8'h60;
                8'ha8: sm4_sbox = 8'hc0; 8'ha9: sm4_sbox = 8'h29;
                8'haa: sm4_sbox = 8'h23; 8'hab: sm4_sbox = 8'hab;
                8'hac: sm4_sbox = 8'h0d; 8'had: sm4_sbox = 8'h53;
                8'hae: sm4_sbox = 8'h4e; 8'haf: sm4_sbox = 8'h6f;
                8'hb0: sm4_sbox = 8'hd5; 8'hb1: sm4_sbox = 8'hdb;
                8'hb2: sm4_sbox = 8'h37; 8'hb3: sm4_sbox = 8'h45;
                8'hb4: sm4_sbox = 8'hde; 8'hb5: sm4_sbox = 8'hfd;
                8'hb6: sm4_sbox = 8'h8e; 8'hb7: sm4_sbox = 8'h2f;
                8'hb8: sm4_sbox = 8'h03; 8'hb9: sm4_sbox = 8'hff;
                8'hba: sm4_sbox = 8'h6a; 8'hbb: sm4_sbox = 8'h72;
                8'hbc: sm4_sbox = 8'h6d; 8'hbd: sm4_sbox = 8'h6c;
                8'hbe: sm4_sbox = 8'h5b; 8'hbf: sm4_sbox = 8'h51;
                8'hc0: sm4_sbox = 8'h8d; 8'hc1: sm4_sbox = 8'h1b;
                8'hc2: sm4_sbox = 8'haf; 8'hc3: sm4_sbox = 8'h92;
                8'hc4: sm4_sbox = 8'hbb; 8'hc5: sm4_sbox = 8'hdd;
                8'hc6: sm4_sbox = 8'hbc; 8'hc7: sm4_sbox = 8'h7f;
                8'hc8: sm4_sbox = 8'h11; 8'hc9: sm4_sbox = 8'hd9;
                8'hca: sm4_sbox = 8'h5c; 8'hcb: sm4_sbox = 8'h41;
                8'hcc: sm4_sbox = 8'h1f; 8'hcd: sm4_sbox = 8'h10;
                8'hce: sm4_sbox = 8'h5a; 8'hcF: sm4_sbox = 8'hd8;
                8'hd0: sm4_sbox = 8'h0a; 8'hd1: sm4_sbox = 8'hc1;
                8'hd2: sm4_sbox = 8'h31; 8'hd3: sm4_sbox = 8'h88;
                8'hd4: sm4_sbox = 8'ha5; 8'hd5: sm4_sbox = 8'hcd;
                8'hd6: sm4_sbox = 8'h7b; 8'hd7: sm4_sbox = 8'hbd;
                8'hd8: sm4_sbox = 8'h2d; 8'hd9: sm4_sbox = 8'h74;
                8'hda: sm4_sbox = 8'hd0; 8'hdb: sm4_sbox = 8'h12;
                8'hdc: sm4_sbox = 8'hb8; 8'hdd: sm4_sbox = 8'he5;
                8'hde: sm4_sbox = 8'hb4; 8'hdf: sm4_sbox = 8'hb0;
                8'he0: sm4_sbox = 8'h89; 8'he1: sm4_sbox = 8'h69;
                8'he2: sm4_sbox = 8'h97; 8'he3: sm4_sbox = 8'h4a;
                8'he4: sm4_sbox = 8'h0c; 8'he5: sm4_sbox = 8'h96;
                8'he6: sm4_sbox = 8'h77; 8'he7: sm4_sbox = 8'h7e;
                8'he8: sm4_sbox = 8'h65; 8'he9: sm4_sbox = 8'hb9;
                8'hea: sm4_sbox = 8'hf1; 8'heb: sm4_sbox = 8'h09;
                8'hec: sm4_sbox = 8'hc5; 8'hed: sm4_sbox = 8'h6e;
                8'hee: sm4_sbox = 8'hc6; 8'hef: sm4_sbox = 8'h84;
                8'hf0: sm4_sbox = 8'h18; 8'hf1: sm4_sbox = 8'hf0;
                8'hf2: sm4_sbox = 8'h7d; 8'hf3: sm4_sbox = 8'hec;
                8'hf4: sm4_sbox = 8'h3a; 8'hf5: sm4_sbox = 8'hdc;
                8'hf6: sm4_sbox = 8'h4d; 8'hf7: sm4_sbox = 8'h20;
                8'hf8: sm4_sbox = 8'h79; 8'hf9: sm4_sbox = 8'hee;
                8'hfa: sm4_sbox = 8'h5f; 8'hfb: sm4_sbox = 8'h3e;
                8'hfc: sm4_sbox = 8'hd7; 8'hfd: sm4_sbox = 8'hcb;
                8'hfe: sm4_sbox = 8'h39; 8'hff: sm4_sbox = 8'h48;
                default: sm4_sbox = 8'h00;
            endcase
        end
    endfunction

    // =========================================================================
    // 密钥扩展: K[i+4] = K[i] ^ T'(K[i+1] ^ K[i+2] ^ K[i+3] ^ CK[i])
    // 使用滑动窗口: K[0..3] 总是代表当前窗口的 4 个 word
    // =========================================================================
    wire [31:0] key_xors = K[1] ^ K[2] ^ K[3] ^ get_ck(k_idx);
    wire [31:0] key_tau  = {sm4_sbox({1'b0, key_xors[31:24]}),
                            sm4_sbox({1'b0, key_xors[23:16]}),
                            sm4_sbox({1'b0, key_xors[15:8]}),
                            sm4_sbox({1'b0, key_xors[7:0]})};
    wire [31:0] key_Lp   = key_tau ^ rotl32(key_tau, 5'd13) ^ rotl32(key_tau, 5'd23);
    wire [31:0] key_next = K[0] ^ key_Lp;

    // =========================================================================
    // 分组变换: X[i+4] = X[i] ^ T(X[i+1] ^ X[i+2] ^ X[i+3] ^ rk[i])
    // 使用滑动窗口: X[0..3] 总是代表当前窗口的 4 个 word
    // =========================================================================
    wire [31:0] cipher_xors = X[1] ^ X[2] ^ X[3] ^
                               (do_decrypt ? round_keys[31-r_idx] : round_keys[r_idx]);
    wire [31:0] cipher_tau  = {sm4_sbox({1'b0, cipher_xors[31:24]}),
                               sm4_sbox({1'b0, cipher_xors[23:16]}),
                               sm4_sbox({1'b0, cipher_xors[15:8]}),
                               sm4_sbox({1'b0, cipher_xors[7:0]})};
    wire [31:0] cipher_L    = cipher_tau ^ rotl32(cipher_tau, 5'd2) ^
                               rotl32(cipher_tau, 5'd10) ^ rotl32(cipher_tau, 5'd18) ^
                               rotl32(cipher_tau, 5'd24);
    wire [31:0] cipher_next = X[0] ^ cipher_L;

    // =========================================================================
    // FSM 主逻辑
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_state <= S_IDLE;
            k_idx     <= 5'd0;
            r_idx     <= 5'd0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;
            case (fsm_state)
                S_IDLE: begin
                    if (start) begin
                        do_decrypt <= decrypt;
                        // 初始化 X[0..3] = 输入数据 (加密用明文, 解密用密文)
                        X[0] <= input_data[127:96];
                        X[1] <= input_data[95:64];
                        X[2] <= input_data[63:32];
                        X[3] <= input_data[31:0];
                        // 初始化 K[0..3] = key ^ FK
                        K[0] <= key[127:96]  ^ FK0;
                        K[1] <= key[95:64]   ^ FK1;
                        K[2] <= key[63:32]   ^ FK2;
                        K[3] <= key[31:0]    ^ FK3;
                        k_idx     <= 5'd0;
                        r_idx     <= 5'd0;
                        fsm_state <= S_KEY_EXP;
                    end
                end

                S_KEY_EXP: begin
                    // 密钥扩展: K[k_idx+4] = K[k_idx] ^ T'(K[k_idx+1]^K[k_idx+2]^K[k_idx+3]^CK[k_idx])
                    K[k_idx + 4] <= key_next;
                    round_keys[k_idx] <= key_next;

                    // 滑动窗口
                    K[0] <= K[1];
                    K[1] <= K[2];
                    K[2] <= K[3];
                    K[3] <= key_next;

                    if (k_idx == 5'd31) begin
                        k_idx     <= 5'd0;
                        r_idx     <= 5'd0;
                        fsm_state <= S_CIPHER;
                    end else begin
                        k_idx <= k_idx + 5'd1;
                    end
                end

                S_CIPHER: begin
                    // 分组变换: X[r_idx+4] = X[r_idx] ^ T(X[r_idx+1]^X[r_idx+2]^X[r_idx+3]^rk[r_idx])
                    X[r_idx + 4] <= cipher_next;

                    // 滑动窗口
                    X[0] <= X[1];
                    X[1] <= X[2];
                    X[2] <= X[3];
                    X[3] <= cipher_next;

                    if (r_idx == 5'd31) begin
                        r_idx     <= 5'd0;
                        // 输出: {X[35], X[34], X[33], X[32]} = {cipher_next, X[3], X[2], X[1]}
                        data_out  <= {cipher_next, X[3], X[2], X[1]};
                        fsm_state <= S_OUTPUT;
                        done      <= 1'b1;
                    end else begin
                        r_idx <= r_idx + 5'd1;
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
    assign result = data_out;
    assign busy   = (fsm_state != S_IDLE);

endmodule
