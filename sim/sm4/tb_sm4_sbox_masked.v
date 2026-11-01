`timescale 1ns / 1ps

// =============================================================================
// tb_sm4_sbox_masked.v -- 自动生成
// 生成脚本: sim/sm4/gen_tb_sm4_sbox_masked.py
// 权威 S 盒来源: rtl/sm4/sm4_engine_sys.v
// 铁律: TB 单一来源；改 S 盒 -> 重跑本脚本
// =============================================================================

module tb_sm4_sbox_masked;

    // =========================================================================
    // 1. 权威 S 盒表（从 sm4_engine_sys.v 正则解析）
    // =========================================================================
    reg [7:0] S_EXPECTED [0:255];

    initial begin
        S_EXPECTED[  0] = 8'hd6;
        S_EXPECTED[  1] = 8'h90;
        S_EXPECTED[  2] = 8'he9;
        S_EXPECTED[  3] = 8'hfe;
        S_EXPECTED[  4] = 8'hcc;
        S_EXPECTED[  5] = 8'he1;
        S_EXPECTED[  6] = 8'h3d;
        S_EXPECTED[  7] = 8'hb7;
        S_EXPECTED[  8] = 8'h16;
        S_EXPECTED[  9] = 8'hb6;
        S_EXPECTED[ 10] = 8'h14;
        S_EXPECTED[ 11] = 8'hc2;
        S_EXPECTED[ 12] = 8'h28;
        S_EXPECTED[ 13] = 8'hfb;
        S_EXPECTED[ 14] = 8'h2c;
        S_EXPECTED[ 15] = 8'h05;
        S_EXPECTED[ 16] = 8'h2b;
        S_EXPECTED[ 17] = 8'h67;
        S_EXPECTED[ 18] = 8'h9a;
        S_EXPECTED[ 19] = 8'h76;
        S_EXPECTED[ 20] = 8'h2a;
        S_EXPECTED[ 21] = 8'hbe;
        S_EXPECTED[ 22] = 8'h04;
        S_EXPECTED[ 23] = 8'hc3;
        S_EXPECTED[ 24] = 8'haa;
        S_EXPECTED[ 25] = 8'h44;
        S_EXPECTED[ 26] = 8'h13;
        S_EXPECTED[ 27] = 8'h26;
        S_EXPECTED[ 28] = 8'h49;
        S_EXPECTED[ 29] = 8'h86;
        S_EXPECTED[ 30] = 8'h06;
        S_EXPECTED[ 31] = 8'h99;
        S_EXPECTED[ 32] = 8'h9c;
        S_EXPECTED[ 33] = 8'h42;
        S_EXPECTED[ 34] = 8'h50;
        S_EXPECTED[ 35] = 8'hf4;
        S_EXPECTED[ 36] = 8'h91;
        S_EXPECTED[ 37] = 8'hef;
        S_EXPECTED[ 38] = 8'h98;
        S_EXPECTED[ 39] = 8'h7a;
        S_EXPECTED[ 40] = 8'h33;
        S_EXPECTED[ 41] = 8'h54;
        S_EXPECTED[ 42] = 8'h0b;
        S_EXPECTED[ 43] = 8'h43;
        S_EXPECTED[ 44] = 8'hed;
        S_EXPECTED[ 45] = 8'hcf;
        S_EXPECTED[ 46] = 8'hac;
        S_EXPECTED[ 47] = 8'h62;
        S_EXPECTED[ 48] = 8'he4;
        S_EXPECTED[ 49] = 8'hb3;
        S_EXPECTED[ 50] = 8'h1c;
        S_EXPECTED[ 51] = 8'ha9;
        S_EXPECTED[ 52] = 8'hc9;
        S_EXPECTED[ 53] = 8'h08;
        S_EXPECTED[ 54] = 8'he8;
        S_EXPECTED[ 55] = 8'h95;
        S_EXPECTED[ 56] = 8'h80;
        S_EXPECTED[ 57] = 8'hdf;
        S_EXPECTED[ 58] = 8'h94;
        S_EXPECTED[ 59] = 8'hfa;
        S_EXPECTED[ 60] = 8'h75;
        S_EXPECTED[ 61] = 8'h8f;
        S_EXPECTED[ 62] = 8'h3f;
        S_EXPECTED[ 63] = 8'ha6;
        S_EXPECTED[ 64] = 8'h47;
        S_EXPECTED[ 65] = 8'h07;
        S_EXPECTED[ 66] = 8'ha7;
        S_EXPECTED[ 67] = 8'hfc;
        S_EXPECTED[ 68] = 8'hf3;
        S_EXPECTED[ 69] = 8'h73;
        S_EXPECTED[ 70] = 8'h17;
        S_EXPECTED[ 71] = 8'hba;
        S_EXPECTED[ 72] = 8'h83;
        S_EXPECTED[ 73] = 8'h59;
        S_EXPECTED[ 74] = 8'h3c;
        S_EXPECTED[ 75] = 8'h19;
        S_EXPECTED[ 76] = 8'he6;
        S_EXPECTED[ 77] = 8'h85;
        S_EXPECTED[ 78] = 8'h4f;
        S_EXPECTED[ 79] = 8'ha8;
        S_EXPECTED[ 80] = 8'h68;
        S_EXPECTED[ 81] = 8'h6b;
        S_EXPECTED[ 82] = 8'h81;
        S_EXPECTED[ 83] = 8'hb2;
        S_EXPECTED[ 84] = 8'h71;
        S_EXPECTED[ 85] = 8'h64;
        S_EXPECTED[ 86] = 8'hda;
        S_EXPECTED[ 87] = 8'h8b;
        S_EXPECTED[ 88] = 8'hf8;
        S_EXPECTED[ 89] = 8'heb;
        S_EXPECTED[ 90] = 8'h0f;
        S_EXPECTED[ 91] = 8'h4b;
        S_EXPECTED[ 92] = 8'h70;
        S_EXPECTED[ 93] = 8'h56;
        S_EXPECTED[ 94] = 8'h9d;
        S_EXPECTED[ 95] = 8'h35;
        S_EXPECTED[ 96] = 8'h1e;
        S_EXPECTED[ 97] = 8'h24;
        S_EXPECTED[ 98] = 8'h0e;
        S_EXPECTED[ 99] = 8'h5e;
        S_EXPECTED[100] = 8'h63;
        S_EXPECTED[101] = 8'h58;
        S_EXPECTED[102] = 8'hd1;
        S_EXPECTED[103] = 8'ha2;
        S_EXPECTED[104] = 8'h25;
        S_EXPECTED[105] = 8'h22;
        S_EXPECTED[106] = 8'h7c;
        S_EXPECTED[107] = 8'h3b;
        S_EXPECTED[108] = 8'h01;
        S_EXPECTED[109] = 8'h21;
        S_EXPECTED[110] = 8'h78;
        S_EXPECTED[111] = 8'h87;
        S_EXPECTED[112] = 8'hd4;
        S_EXPECTED[113] = 8'h00;
        S_EXPECTED[114] = 8'h46;
        S_EXPECTED[115] = 8'h57;
        S_EXPECTED[116] = 8'h9f;
        S_EXPECTED[117] = 8'hd3;
        S_EXPECTED[118] = 8'h27;
        S_EXPECTED[119] = 8'h52;
        S_EXPECTED[120] = 8'h4c;
        S_EXPECTED[121] = 8'h36;
        S_EXPECTED[122] = 8'h02;
        S_EXPECTED[123] = 8'he7;
        S_EXPECTED[124] = 8'ha0;
        S_EXPECTED[125] = 8'hc4;
        S_EXPECTED[126] = 8'hc8;
        S_EXPECTED[127] = 8'h9e;
        S_EXPECTED[128] = 8'hea;
        S_EXPECTED[129] = 8'hbf;
        S_EXPECTED[130] = 8'h8a;
        S_EXPECTED[131] = 8'hd2;
        S_EXPECTED[132] = 8'h40;
        S_EXPECTED[133] = 8'hc7;
        S_EXPECTED[134] = 8'h38;
        S_EXPECTED[135] = 8'hb5;
        S_EXPECTED[136] = 8'ha3;
        S_EXPECTED[137] = 8'hf7;
        S_EXPECTED[138] = 8'hf2;
        S_EXPECTED[139] = 8'hce;
        S_EXPECTED[140] = 8'hf9;
        S_EXPECTED[141] = 8'h61;
        S_EXPECTED[142] = 8'h15;
        S_EXPECTED[143] = 8'ha1;
        S_EXPECTED[144] = 8'he0;
        S_EXPECTED[145] = 8'hae;
        S_EXPECTED[146] = 8'h5d;
        S_EXPECTED[147] = 8'ha4;
        S_EXPECTED[148] = 8'h9b;
        S_EXPECTED[149] = 8'h34;
        S_EXPECTED[150] = 8'h1a;
        S_EXPECTED[151] = 8'h55;
        S_EXPECTED[152] = 8'had;
        S_EXPECTED[153] = 8'h93;
        S_EXPECTED[154] = 8'h32;
        S_EXPECTED[155] = 8'h30;
        S_EXPECTED[156] = 8'hf5;
        S_EXPECTED[157] = 8'h8c;
        S_EXPECTED[158] = 8'hb1;
        S_EXPECTED[159] = 8'he3;
        S_EXPECTED[160] = 8'h1d;
        S_EXPECTED[161] = 8'hf6;
        S_EXPECTED[162] = 8'he2;
        S_EXPECTED[163] = 8'h2e;
        S_EXPECTED[164] = 8'h82;
        S_EXPECTED[165] = 8'h66;
        S_EXPECTED[166] = 8'hca;
        S_EXPECTED[167] = 8'h60;
        S_EXPECTED[168] = 8'hc0;
        S_EXPECTED[169] = 8'h29;
        S_EXPECTED[170] = 8'h23;
        S_EXPECTED[171] = 8'hab;
        S_EXPECTED[172] = 8'h0d;
        S_EXPECTED[173] = 8'h53;
        S_EXPECTED[174] = 8'h4e;
        S_EXPECTED[175] = 8'h6f;
        S_EXPECTED[176] = 8'hd5;
        S_EXPECTED[177] = 8'hdb;
        S_EXPECTED[178] = 8'h37;
        S_EXPECTED[179] = 8'h45;
        S_EXPECTED[180] = 8'hde;
        S_EXPECTED[181] = 8'hfd;
        S_EXPECTED[182] = 8'h8e;
        S_EXPECTED[183] = 8'h2f;
        S_EXPECTED[184] = 8'h03;
        S_EXPECTED[185] = 8'hff;
        S_EXPECTED[186] = 8'h6a;
        S_EXPECTED[187] = 8'h72;
        S_EXPECTED[188] = 8'h6d;
        S_EXPECTED[189] = 8'h6c;
        S_EXPECTED[190] = 8'h5b;
        S_EXPECTED[191] = 8'h51;
        S_EXPECTED[192] = 8'h8d;
        S_EXPECTED[193] = 8'h1b;
        S_EXPECTED[194] = 8'haf;
        S_EXPECTED[195] = 8'h92;
        S_EXPECTED[196] = 8'hbb;
        S_EXPECTED[197] = 8'hdd;
        S_EXPECTED[198] = 8'hbc;
        S_EXPECTED[199] = 8'h7f;
        S_EXPECTED[200] = 8'h11;
        S_EXPECTED[201] = 8'hd9;
        S_EXPECTED[202] = 8'h5c;
        S_EXPECTED[203] = 8'h41;
        S_EXPECTED[204] = 8'h1f;
        S_EXPECTED[205] = 8'h10;
        S_EXPECTED[206] = 8'h5a;
        S_EXPECTED[207] = 8'hd8;
        S_EXPECTED[208] = 8'h0a;
        S_EXPECTED[209] = 8'hc1;
        S_EXPECTED[210] = 8'h31;
        S_EXPECTED[211] = 8'h88;
        S_EXPECTED[212] = 8'ha5;
        S_EXPECTED[213] = 8'hcd;
        S_EXPECTED[214] = 8'h7b;
        S_EXPECTED[215] = 8'hbd;
        S_EXPECTED[216] = 8'h2d;
        S_EXPECTED[217] = 8'h74;
        S_EXPECTED[218] = 8'hd0;
        S_EXPECTED[219] = 8'h12;
        S_EXPECTED[220] = 8'hb8;
        S_EXPECTED[221] = 8'he5;
        S_EXPECTED[222] = 8'hb4;
        S_EXPECTED[223] = 8'hb0;
        S_EXPECTED[224] = 8'h89;
        S_EXPECTED[225] = 8'h69;
        S_EXPECTED[226] = 8'h97;
        S_EXPECTED[227] = 8'h4a;
        S_EXPECTED[228] = 8'h0c;
        S_EXPECTED[229] = 8'h96;
        S_EXPECTED[230] = 8'h77;
        S_EXPECTED[231] = 8'h7e;
        S_EXPECTED[232] = 8'h65;
        S_EXPECTED[233] = 8'hb9;
        S_EXPECTED[234] = 8'hf1;
        S_EXPECTED[235] = 8'h09;
        S_EXPECTED[236] = 8'hc5;
        S_EXPECTED[237] = 8'h6e;
        S_EXPECTED[238] = 8'hc6;
        S_EXPECTED[239] = 8'h84;
        S_EXPECTED[240] = 8'h18;
        S_EXPECTED[241] = 8'hf0;
        S_EXPECTED[242] = 8'h7d;
        S_EXPECTED[243] = 8'hec;
        S_EXPECTED[244] = 8'h3a;
        S_EXPECTED[245] = 8'hdc;
        S_EXPECTED[246] = 8'h4d;
        S_EXPECTED[247] = 8'h20;
        S_EXPECTED[248] = 8'h79;
        S_EXPECTED[249] = 8'hee;
        S_EXPECTED[250] = 8'h5f;
        S_EXPECTED[251] = 8'h3e;
        S_EXPECTED[252] = 8'hd7;
        S_EXPECTED[253] = 8'hcb;
        S_EXPECTED[254] = 8'h39;
        S_EXPECTED[255] = 8'h48;
    end

    // =========================================================================
    // 2. DUT signals
    // =========================================================================
    reg         clk = 1'b0;
    reg         rst_n = 1'b1;
    reg  [7:0]  x       = 8'h00;
    reg  [7:0]  trng_data = 8'h00;
    reg         trng_valid = 1'b0;
    wire [7:0]  y;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    reg seen_y3 [0:255];   // T3 均匀性检查

    // =========================================================================
    // 3. DUT 例化：3 组 —— 掩码关闭 / 掩码开启 / 掩码开但 trng_valid=0
    // =========================================================================

    // DUT-A: 掩码关闭 (sm4_sbox_masked_en = 0) —— 透传 S(x)
    sm4_sbox_masked #(.sm4_sbox_masked_en(1'b0)) dut_a (
        .clk(clk), .rst_n(rst_n), .x(x), .trng_data(trng_data),
        .trng_valid(trng_valid), .y(y_a)
    );
    wire [7:0] y_a;

    // DUT-B: 掩码开启，trng_valid=1 —— y = S(x) ^ trng_data
    sm4_sbox_masked #(.sm4_sbox_masked_en(1'b1)) dut_b (
        .clk(clk), .rst_n(rst_n), .x(x), .trng_data(trng_data),
        .trng_valid(1'b1), .y(y_b)
    );
    wire [7:0] y_b;

    // DUT-C: 掩码开启但 trng_valid=0 —— 退化为 S(x)
    sm4_sbox_masked #(.sm4_sbox_masked_en(1'b1)) dut_c (
        .clk(clk), .rst_n(rst_n), .x(x), .trng_data(trng_data),
        .trng_valid(1'b0), .y(y_c)
    );
    wire [7:0] y_c;

    // =========================================================================
    // 4. 测试序列
    // =========================================================================
    initial begin
        $display("==================== sm4_sbox_masked TB ===================");
        $display("权威 S 盒条目数: 256");
        $display("S[0]=%h S[1]=%h S[4]=%h S[128]=%h", S_EXPECTED[0], S_EXPECTED[1], S_EXPECTED[4], S_EXPECTED[128]);

        // 复位
        rst_n = 1'b0;
        #5;
        rst_n = 1'b1;
        #5;

        // ---------------------------------------------------------------------
        // T1: 掩码关闭 —— y_a 必须逐点等于 S_EXPECTED[x] (256/256)
        // ---------------------------------------------------------------------
        trng_valid = 1'b0;   // 掩码关闭下 trng_valid 也应无关
        trng_data  = 8'h00;
        $display("\n[T1] Mask DISABLED: 256/256 y_a == S_EXPECTED");
        for (integer i = 0; i < 256; i = i + 1) begin
            x = i[7:0];
            #2;
            if (y_a != S_EXPECTED[i]) begin
                $display("  FAIL x=%02d y_a=%h expected=%h", i, y_a, S_EXPECTED[i]);
                fail_cnt = fail_cnt + 1;
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end

        // ---------------------------------------------------------------------
        // T2: 掩码开启 + trng_valid=1 —— y_b ^ trng_data == S_EXPECTED
        //     注意：因 y 为组合信号，需采样 #1 越 NBA
        // ---------------------------------------------------------------------
        trng_valid = 1'b1;
        $display("\n[T2] Mask ENABLED, trng_valid=1: y_b ^ trng_data == S_EXPECTED");
        // 用 4 组不同 trng_data 值
        trng_data = 8'hAA; #1;
        for (integer i = 0; i < 256; i = i + 1) begin
            x = i[7:0];
            #2;
            #1;   // 越 NBA 采样（DUT 纯组合，无需 clk）
            if ((y_b ^ trng_data) != S_EXPECTED[i]) begin
                if (fail_cnt < 5) $display("  FAIL T2 trng=AA x=%02d y_b=%h trng=%h got=%h expected=%h",
                    i, y_b, trng_data, y_b ^ trng_data, S_EXPECTED[i]);
                fail_cnt = fail_cnt + 1;
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end

        // T2b: trng_data=0x5A 再验一次
        trng_data = 8'h5A; #1;
        for (integer i = 0; i < 256; i = i + 1) begin
            x = i[7:0];
            #2;
            #1;
            if ((y_b ^ trng_data) != S_EXPECTED[i]) begin
                if (fail_cnt < 5) $display("  FAIL T2b trng=5A x=%02d y_b=%h got=%h expected=%h",
                    i, y_b, y_b ^ trng_data, S_EXPECTED[i]);
                fail_cnt = fail_cnt + 1;
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end

        // T2c: trng_data=0x00 —— 应等于 S(x)（掩码为 0 时退化）
        trng_data = 8'h00; #1;
        for (integer i = 0; i < 256; i = i + 1) begin
            x = i[7:0];
            #2;
            #1;
            if (y_b != S_EXPECTED[i]) begin
                if (fail_cnt < 5) $display("  FAIL T2c trng=00 x=%02d y_b=%h expected=%h",
                    i, y_b, S_EXPECTED[i]);
                fail_cnt = fail_cnt + 1;
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end

        // ---------------------------------------------------------------------
        // T3: 掩码开启 + trng_valid=0 —— 退化为 S(x)
        // ---------------------------------------------------------------------
        $display("\n[T3] Mask ENABLED but trng_valid=0: y_c == S_EXPECTED");
        for (integer i = 0; i < 256; i = i + 1) begin
            x = i[7:0];
            trng_data = 8'hFF;   // 无关，应被 trng_valid 屏蔽
            #2;
            #1;
            if (y_c !== S_EXPECTED[i]) begin
                if (fail_cnt < 5) $display("  FAIL T3 x=%02d y_c=%h expected=%h",
                    i, y_c, S_EXPECTED[i]);
                fail_cnt = fail_cnt + 1;
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end

        // ---------------------------------------------------------------------
        // T3b: 均匀性 —— 固定 x=0, 遍历 trng_data, y_b 覆盖 0..255 各一次
        //      (份额均匀性直接检查；因 S 双射 + XOR 保双射)
        // ---------------------------------------------------------------------
        $display("\n[T3b] Uniformity: fixed x=0, scan trng_data, y_b covers 0..255 once");
        trng_valid = 1'b1;
        x = 8'h00;
        for (integer k = 0; k < 256; k = k + 1) seen_y3[k] = 0;
        for (integer t = 0; t < 256; t = t + 1) begin
            trng_data = t[7:0];
            #1;
            if (seen_y3[y_b] != 0) begin
                if (fail_cnt < 5) $display("  FAIL T3 trng=%02h y_b=%h (duplicate)", t, y_b);
                fail_cnt = fail_cnt + 1;
            end else begin
                seen_y3[y_b] = 1;
                pass_cnt = pass_cnt + 1;
            end
        end

        // ---------------------------------------------------------------------
        // T4: 交叉验证 —— y_a (关闭) 与 y_c (开启但 valid=0) 一致
        $display("\n[T4] Cross-check: y_a (disabled) == y_c (enabled, valid=0)");
        trng_valid = 1'b0;
        for (integer i = 0; i < 256; i = i + 1) begin
            x = i[7:0];
            #2;
            #1;
            if (y_a != y_c) begin
                if (fail_cnt < 5) $display("  FAIL T4 x=%02d y_a=%h y_c=%h", i, y_a, y_c);
                fail_cnt = fail_cnt + 1;
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end

        // =========================================================================
        // 汇总
        // =========================================================================
        $display("\n==================== RESULTS ====================");
        $display("PASS: %0d", pass_cnt);
        $display("FAIL: %0d", fail_cnt);
        if (fail_cnt == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("SOME TESTS FAILED");
            $fatal(1);
        end
    end

endmodule