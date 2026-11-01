// =============================================================================
// sm4_engine_masked_v4_indep.v -- SM4 v4 引擎 + 独立输出掩码 (二阶消除)
// 版本: 5.0
// 日期: 2026-10-30
// 设计: 齐流晶 (FPGA Full-Flow Lead)
//
// 修订相对 v4.0 的本质变化:
//   v4.0: mout8 单字节共享 -> tau_m[b0]^tau_m[b1] = S(...)^S(...) (掩码抵消)
//         -> 二阶 tau×tau 泄漏 (|t|=49.84, CPA 6/6 恢复)
//   v5.0: mout8 逐字节独立 -> tau_m[b0]^tau_m[b1] = S(...)^S(...)^mout8[0]^mout8[1]
//         -> 二阶通道关闭 (独立均匀掩码不可差分)
//   代价: +3 个 8-bit 掩码寄存器 (~12 LUT), 随机数消耗 1.125→4.5 bit/S盒
//
// 关联文档:
//   docs/Phase0_5_C1_SM4_v4_输出再掩码_微规格书_v1.md
//   docs/毛刺扩展模型安全性评估_P1-2_v1.md
// =============================================================================

`timescale 1ns / 1ps

module sm4_engine_masked_v4_indep (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [127:0] key,
    input  wire [127:0] plaintext,
    input  wire         decrypt,
    input  wire [127:0] ciphertext,
    output wire [127:0] result,
    output reg          done,
    output wire         busy,
    input  wire         masked_en,
    input  wire [63:0]  mask_seed
);

    // 常量
    localparam [31:0] FK0 = 32'ha3b1bac6;
    localparam [31:0] FK1 = 32'h56aa3350;
    localparam [31:0] FK2 = 32'h677d9197;
    localparam [31:0] FK3 = 32'hb27022dc;

    // 状态机
    localparam [4:0] S_IDLE   = 5'd0;
    localparam [4:0] S_KEY    = 5'd1;
    localparam [4:0] S_DATA   = 5'd2;
    localparam [4:0] S_OUTPUT = 5'd3;

    reg [4:0]  fsm_state;
    reg [4:0]  k_idx;
    reg [5:0]  blk_cycle;
    reg [5:0]  key_cycle_cnt;
    reg        do_decrypt;
    reg [127:0] input_window;
    reg [127:0] key_window;
    reg [31:0]  round_keys [0:31];
    reg [7:0]   tbl_src [0:255];

    // ---- 掩码状态 ----
    reg [7:0]   K;              // 表输入掩码 (块内固定, 非 0)
    reg [7:0]   mout8_base;     // 表输出基掩码 (块内固定, 用于表生成)
    reg [7:0]   mout8 [0:3];    // 逐字节独立输出掩码 (v5.0 新增)
    reg [31:0]  M32;
    reg [31:0]  mword [0:3];

    // 过程变量
    reg [31:0] key_xors1, key_tau1, key_Lp1, key_next1;
    reg [31:0] key_xors2, key_tau2, key_Lp2, key_next2;
    reg [31:0] rk;
    reg [31:0] t_in, comp, addr;
    reg [31:0] tau_m_raw, tau_m;    // v5.0: 拆分 raw 和 per-byte 掩码
    reg [31:0] L_m, new_word, Ltmp;
    reg [31:0] mtotal;              // v5.0: 逐字节总掩码 (base ^ per-byte)
    reg [63:0] s1, s2;
    reg [7:0]  kk, mm_base;
    reg [31:0] nn0, nn1, nn2, nn3;
    integer    gi;

    // ---- 函数 ----
    function [31:0] rotl32;
        input [31:0] x;
        input [4:0]  n;
        begin
            rotl32 = (x << n) | (x >> (32 - n));
        end
    endfunction

    function [63:0] xs64;
        input [63:0] x;
        reg [63:0] t;
        begin
            t = x ^ (x << 13);
            t = t ^ (t >> 7);
            xs64 = t ^ (t << 17);
        end
    endfunction

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

    // CK 常量 (32 项)
    function [31:0] get_ck;
        input [4:0] i;
        begin
            case (i)
                5'd0:  get_ck = 32'h00070e15;  5'd1:  get_ck = 32'h1c232a31;
                5'd2:  get_ck = 32'h383f464d;  5'd3:  get_ck = 32'h545b6269;
                5'd4:  get_ck = 32'h70777e85;  5'd5:  get_ck = 32'h8c939aa1;
                5'd6:  get_ck = 32'ha8afb6bd;  5'd7:  get_ck = 32'hc4cbd2d9;
                5'd8:  get_ck = 32'he0e7eef5;  5'd9:  get_ck = 32'hfc030a11;
                5'd10: get_ck = 32'h181f262d;  5'd11: get_ck = 32'h343b4249;
                5'd12: get_ck = 32'h50575e65;  5'd13: get_ck = 32'h6c737a81;
                5'd14: get_ck = 32'h888f969d;  5'd15: get_ck = 32'ha4abb2b9;
                5'd16: get_ck = 32'hc0c7ced5;  5'd17: get_ck = 32'hdce3eaf1;
                5'd18: get_ck = 32'hf8ff060d;  5'd19: get_ck = 32'h141b2229;
                5'd20: get_ck = 32'h30373e45;  5'd21: get_ck = 32'h4c535a61;
                5'd22: get_ck = 32'h686f767d;  5'd23: get_ck = 32'h848b9299;
                5'd24: get_ck = 32'ha0a7aeb5;  5'd25: get_ck = 32'hbcc3cad1;
                5'd26: get_ck = 32'hd8dfe6ed;  5'd27: get_ck = 32'hf4fb0209;
                5'd28: get_ck = 32'h10171e25;  5'd29: get_ck = 32'h2c333a41;
                5'd30: get_ck = 32'h484f565d;  5'd31: get_ck = 32'h646b7279;
                default: get_ck = 32'h0;
            endcase
        end
    endfunction

    // 输出
    reg [127:0] data_out;
    assign result = data_out;
    assign busy   = (fsm_state != S_IDLE);

    // FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_state      <= S_IDLE;
            k_idx          <= 5'd0;
            blk_cycle      <= 5'd0;
            key_cycle_cnt  <= 6'd0;
            done           <= 1'b0;
            input_window   <= 128'd0;
            key_window     <= 128'd0;
            K              <= 8'h00;
            mout8_base     <= 8'h00;
            mout8[0]       <= 8'h00;
            mout8[1]       <= 8'h00;
            mout8[2]       <= 8'h00;
            mout8[3]       <= 8'h00;
            M32            <= 32'd0;
            mword[0]       <= 32'd0;
            mword[1]       <= 32'd0;
            mword[2]       <= 32'd0;
            mword[3]       <= 32'd0;
            for (gi = 0; gi < 256; gi = gi + 1)
                tbl_src[gi] <= sm4_sbox(gi);
        end else begin
            case (fsm_state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        do_decrypt <= decrypt;
                        key_window <= {key[127:96] ^ FK0, key[95:64] ^ FK1,
                                       key[63:32] ^ FK2, key[31:0] ^ FK3};
                        k_idx          <= 5'd0;
                        blk_cycle      <= 5'd0;
                        key_cycle_cnt  <= 6'd0;
                        fsm_state      <= S_KEY;

                        if (masked_en) begin
                            s1 = xs64(mask_seed);
                            s2 = xs64(s1);
                            // 均匀掩码: 允许取 0
                            kk       = mask_seed[63:56];
                            mm_base  = mask_seed[55:48];   // 表基掩码
                            // v5.0: 4 路独立逐字节输出掩码
                            mout8[0] <= mask_seed[47:40];
                            mout8[1] <= mask_seed[39:32];
                            mout8[2] <= mask_seed[31:24];
                            mout8[3] <= mask_seed[23:16];
                            nn0 = mask_seed[15:0];
                            nn1 = {mask_seed[63:48], s1[63:62]};
                            nn2 = s1[61:32];
                            nn3 = {s1[31:0], s2[63:32]};
                            // v5.0 修正: M32 必须包含逐字节独立输出掩码
                            // 总掩码 = {mb^ms[23:16], mb^ms[31:24], mb^ms[39:32], mb^ms[47:40]}
                            // 其中 mb=mask_seed[55:48], ms=mask_seed
                            mtotal = {mm_base ^ mask_seed[23:16],
                                      mm_base ^ mask_seed[31:24],
                                      mm_base ^ mask_seed[39:32],
                                      mm_base ^ mask_seed[47:40]};
                            mword[0] <= nn3;
                            mword[1] <= nn2;
                            mword[2] <= nn1;
                            mword[3] <= nn0;
                            K       <= kk;
                            mout8_base <= mm_base;
                            M32     <= mtotal ^ rotl32(mtotal, 5'd2) ^ rotl32(mtotal, 5'd10)
                                       ^ rotl32(mtotal, 5'd18) ^ rotl32(mtotal, 5'd24);
                            if (decrypt)
                                input_window <= {ciphertext[127:96] ^ nn0, ciphertext[95:64] ^ nn1,
                                                 ciphertext[63:32] ^ nn2, ciphertext[31:0] ^ nn3};
                            else
                                input_window <= {plaintext[127:96] ^ nn0, plaintext[95:64] ^ nn1,
                                                 plaintext[63:32] ^ nn2, plaintext[31:0] ^ nn3};
                        end else begin
                            mword[0] <= 32'd0;  mword[1] <= 32'd0;
                            mword[2] <= 32'd0;  mword[3] <= 32'd0;
                            K <= 8'h00;  mout8_base <= 8'h00;
                            mout8[0] <= 8'h00;  mout8[1] <= 8'h00;
                            mout8[2] <= 8'h00;  mout8[3] <= 8'h00;
                            M32 <= 32'd0;
                            input_window <= decrypt ? ciphertext : plaintext;
                        end
                    end
                end

                S_KEY: begin
                    key_xors1 = key_window[95:64] ^ key_window[63:32] ^ key_window[31:0] ^ get_ck(k_idx);
                    key_tau1  = {sm4_sbox(key_xors1[31:24]), sm4_sbox(key_xors1[23:16]),
                                 sm4_sbox(key_xors1[15:8]), sm4_sbox(key_xors1[7:0])};
                    key_Lp1   = key_tau1 ^ rotl32(key_tau1, 5'd13) ^ rotl32(key_tau1, 5'd23);
                    key_next1 = key_window[127:96] ^ key_Lp1;

                    key_xors2 = key_window[63:32] ^ key_window[31:0] ^ key_next1 ^ get_ck(k_idx+5'd1);
                    key_tau2  = {sm4_sbox(key_xors2[31:24]), sm4_sbox(key_xors2[23:16]),
                                 sm4_sbox(key_xors2[15:8]), sm4_sbox(key_xors2[7:0])};
                    key_Lp2   = key_tau2 ^ rotl32(key_tau2, 5'd13) ^ rotl32(key_tau2, 5'd23);
                    key_next2 = key_window[95:64] ^ key_Lp2;

                    round_keys[k_idx]   <= key_next1;
                    round_keys[k_idx+1] <= key_next2;
                    key_window <= {key_window[63:32], key_window[31:0], key_next1, key_next2};

                    // 掩码表刷新: tbl[z] = S(z ^ K) ^ mout8_base (基掩码, 非逐字节)
                    for (gi = 0; gi < 16; gi = gi + 1)
                        tbl_src[{key_cycle_cnt[4:0], gi[3:0]}] <=
                            sm4_sbox({key_cycle_cnt[4:0], gi[3:0]} ^ K) ^ mout8_base;

                    if (k_idx == 5'd30) begin
                        fsm_state <= S_DATA;
                    end else begin
                        key_cycle_cnt <= key_cycle_cnt + 6'd1;
                        k_idx <= k_idx + 5'd2;
                    end
                end

                S_DATA: begin
                    rk    = do_decrypt ? round_keys[31-blk_cycle] : round_keys[blk_cycle];
                    t_in  = input_window[31:0] ^ input_window[63:32] ^ input_window[95:64] ^ rk;
                    comp  = mword[0] ^ mword[1] ^ mword[2] ^ {4{K}};
                    addr  = t_in ^ comp;
                    // v5.0: 表查表 (含基掩码) -> 逐字节独立掩码 XOR
                    tau_m_raw = {tbl_src[addr[31:24]], tbl_src[addr[23:16]],
                                 tbl_src[addr[15:8]],  tbl_src[addr[7:0]]};
                    tau_m = tau_m_raw ^ {mout8[3], mout8[2], mout8[1], mout8[0]};
                    L_m   = tau_m ^ rotl32(tau_m, 5'd2) ^ rotl32(tau_m, 5'd10)
                             ^ rotl32(tau_m, 5'd18) ^ rotl32(tau_m, 5'd24);
                    new_word = input_window[127:96] ^ L_m;

                    input_window <= {input_window[95:64], input_window[63:32],
                                     input_window[31:0], new_word};
                    mword[0] <= mword[3] ^ M32;
                    mword[1] <= mword[0];
                    mword[2] <= mword[1];
                    mword[3] <= mword[2];
                    blk_cycle <= blk_cycle + 5'd1;

                    if (blk_cycle >= 5'd31) begin
                        fsm_state <= S_OUTPUT;
                    end
                end

                S_OUTPUT: begin
                    data_out <= {input_window[31:0]   ^ mword[0],
                                 input_window[63:32]  ^ mword[1],
                                 input_window[95:64]  ^ mword[2],
                                 input_window[127:96] ^ mword[3]};
                    done <= 1'b1;
                    fsm_state <= S_IDLE;
                end

                default: fsm_state <= S_IDLE;
            endcase
        end
    end

endmodule