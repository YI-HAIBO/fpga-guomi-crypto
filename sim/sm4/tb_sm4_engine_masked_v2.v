// =============================================================================
// 模块名称 : tb_sm4_engine_masked_v2
// 项目     : GM-CRYPTO-COORD-2026 - B-3 验证 (sm4_engine_masked_v2 v1.0)
// 视角     : sim-verifier
// 生成     : b3_vectors.py + emit_tb_b3.py (期望值由已裁决参考模型计算)
// 参考模型 : 与 gmssl 逐位一致, T(A)=L(tau(A)) 无恒等项, 滑动窗口
// 目标     :
//   T1/T2  masked_en=0  GB/T 零回归 (加密 + 解密)
//   T3/T4  masked_en=1  GB/T 零回归 (加密 + 解密)  << 核心判据
//   T5     masked_en=1  6 组向量密文 == Python 参考
//   T6     masked_en=1  6 组向量 enc->dec 往返
//   T7     双模式一致性 en=0 vs en=1 (6 组)
//   T8     masked_en=1  16 块连续 (双缓冲轮换) 逐块比对
//   T9     侧信道观测端口自洽 (addr_tap == ref ^ c_tap)
//   T10    masked_en=1  连续 8 块 c_tap 互异非零 (LFSR 多样性)
//   T11    外部注入模式 4 组 c_ext, 数值正确性
//   T12    外部注入 -> 内部刷新 模式切换回归
// =============================================================================
`timescale 1ns / 1ps
module tb_sm4_engine_masked_v2;

    reg          clk = 1'b0;
    reg          rst_n = 1'b0;
    reg          start = 1'b0;
    reg  [127:0] key = 128'h00000000000000000000000000000000;
    reg  [127:0] plaintext = 128'h00000000000000000000000000000000;
    reg          decrypt = 1'b0;
    reg  [127:0] ciphertext = 128'h00000000000000000000000000000000;

    reg          masked_en = 1'b0;
    reg          sbox_mask_ext_en = 1'b0;
    reg  [7:0]   sbox_mask_c_ext = 8'h00;
    reg  [2047:0] sbox_mask_tbl_ext = 2048'h0;

    wire [127:0] result;
    wire         done;
    wire         busy;
    wire [7:0]   sbox_addr_tap;
    wire [7:0]   sbox_mask_c_tap;
    wire         sbox_mask_valid;

    // 时钟 10ns (100 MHz)
    always #5 clk = ~clk;

    sm4_engine_masked_v2 dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (start),
        .key               (key),
        .plaintext         (plaintext),
        .decrypt           (decrypt),
        .ciphertext        (ciphertext),
        .result            (result),
        .done              (done),
        .busy              (busy),
        .masked_en         (masked_en),
        .sbox_mask_ext_en  (sbox_mask_ext_en),
        .sbox_mask_c_ext   (sbox_mask_c_ext),
        .sbox_mask_tbl_ext (sbox_mask_tbl_ext),
        .sbox_addr_tap     (sbox_addr_tap),
        .sbox_mask_c_tap   (sbox_mask_c_tap),
        .sbox_mask_valid   (sbox_mask_valid)
    );

    integer timeout_cnt;
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // 发起一次加/解密并等 done
    task do_sm4;
        input [127:0] k_in;
        input [127:0] data_in;
        input         dec_in;
        begin
            @(negedge clk);
            key        = k_in;
            plaintext  = data_in;
            ciphertext = data_in;
            decrypt    = dec_in;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            timeout_cnt = 0;
            @(posedge clk);
            while (!done && timeout_cnt < 500) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (timeout_cnt >= 500) begin
                $display("  FAIL: timeout after %0d cycles", timeout_cnt);
                $finish;
            end
        end
    endtask

    // 比对当前 result 与期望值
    task chk_eq;
        input [127:0] exp_v;
        input [9:0]   id_v;
        begin
            if (result === exp_v) begin
                $display("  PASS[#%02d]", id_v);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL[#%02d]: exp %h", id_v, exp_v);
                $display("           got      %h", result);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_sm4_engine_masked_v2.vcd");
        $dumpvars(0, dut.fsm_state, dut.k_idx, dut.sbox_buf_sel,
                  dut.sbox_c_a, dut.sbox_c_b, dut.sbox_seed,
                  dut.sbox_mg_cnt, dut.sbox_mask_valid, done, busy);

        rst_n            = 1'b0;
        masked_en        = 1'b0;
        sbox_mask_ext_en = 1'b0;
        #30;
        @(negedge clk);
        rst_n = 1'b1;
        #10;

        // =====================================================================
        // T1: masked_en=0  GB/T 官方向量 (加密)  -- 零回归基线
        // =====================================================================
        $display("=== T1: masked_en=0  GB/T official vector (encrypt) ===");
        do_sm4(128'h0123456789abcdeffedcba9876543210, 128'h0123456789abcdeffedcba9876543210, 1'b0);
        chk_eq(128'h681edf34d206965e86b3e94f536e4246, 10'd1);

        // =====================================================================
        // T2: masked_en=0  GB/T 官方向量 (解密)
        // =====================================================================
        $display("=== T2: masked_en=0  GB/T official vector (decrypt) ===");
        do_sm4(128'h0123456789abcdeffedcba9876543210, 128'h681edf34d206965e86b3e94f536e4246, 1'b1);
        chk_eq(128'h0123456789abcdeffedcba9876543210, 10'd2);

        // =====================================================================
        // T3: masked_en=1  GB/T 官方向量 (加密)  -- B-3 核心零回归判据
        // =====================================================================
        $display("=== T3: masked_en=1  GB/T official vector (encrypt) ===");
        masked_en = 1'b1;
        do_sm4(128'h0123456789abcdeffedcba9876543210, 128'h0123456789abcdeffedcba9876543210, 1'b0);
        chk_eq(128'h681edf34d206965e86b3e94f536e4246, 10'd3);

        // =====================================================================
        // T4: masked_en=1  GB/T 官方向量 (解密)
        // =====================================================================
        $display("=== T4: masked_en=1  GB/T official vector (decrypt) ===");
        do_sm4(128'h0123456789abcdeffedcba9876543210, 128'h681edf34d206965e86b3e94f536e4246, 1'b1);
        chk_eq(128'h0123456789abcdeffedcba9876543210, 10'd4);

        // =====================================================================
        // T5: masked_en=1  6 组向量密文 == Python 参考
        // =====================================================================
        $display("=== T5: masked_en=1  6 vectors vs python reference ===");
        begin : t5
            integer i;
            reg [127:0] pt_v;
            reg [127:0] ct_ref;
            reg [127:0] k_v;
            for (i = 0; i < 6; i = i + 1) begin
                case (i)
                    3'd0: begin
                        k_v    = 128'h0123456789abcdeffedcba9876543210;
                        pt_v   = 128'h0123456789abcdeffedcba9876543210;
                        ct_ref = 128'h681edf34d206965e86b3e94f536e4246;
                    end
                    3'd1: begin
                        k_v    = 128'hfedcba9876543210fedcba9876543210;
                        pt_v   = 128'h00112233445566778899aabbccddeeff;
                        ct_ref = 128'hb1199b9b7c1be97be6842f2b47aafb3c;
                    end
                    3'd2: begin
                        k_v    = 128'h000102030405060708090a0b0c0d0e0f;
                        pt_v   = 128'hdeadbeefcafebabe1234567890abcdef;
                        ct_ref = 128'h661f07ed3d9e24a8a49b4bb0639e6a89;
                    end
                    3'd3: begin
                        k_v    = 128'hffffffffffffffffffffffffffffffff;
                        pt_v   = 128'h00000000000000000000000000000000;
                        ct_ref = 128'he28f2c531ed6183dd16487c1614710e6;
                    end
                    3'd4: begin
                        k_v    = 128'ha5a5a5a55a5a5a5affffffff00000000;
                        pt_v   = 128'ha5a5a5a55a5a5a5a5a5a5a5a5a5a5a5a;
                        ct_ref = 128'h3b425d649689a8285a6fcd31b1970a3f;
                    end
                    3'd5: begin
                        k_v    = 128'h1234567890abcdef1234567890abcdef;
                        pt_v   = 128'hfedcba9876543210fedcba9876543210;
                        ct_ref = 128'hf9c67cd1f679e3a3f59150e9f4ffe44e;
                    end
                endcase
                do_sm4(k_v, pt_v, 1'b0);
                chk_eq(ct_ref, 10'd50 + i);
            end
        end

        // =====================================================================
        // T6: masked_en=1  enc -> dec 往返
        // =====================================================================
        $display("=== T6: masked_en=1  enc->dec round-trip (6 vectors) ===");
        begin : t6
            integer i;
            reg [127:0] pt_v;
            reg [127:0] ct_v;
            reg [127:0] k_v;
            for (i = 0; i < 6; i = i + 1) begin
                case (i)
                    3'd0: begin
                        k_v  = 128'h0123456789abcdeffedcba9876543210;
                        pt_v = 128'h0123456789abcdeffedcba9876543210;
                    end
                    3'd1: begin
                        k_v  = 128'hfedcba9876543210fedcba9876543210;
                        pt_v = 128'h00112233445566778899aabbccddeeff;
                    end
                    3'd2: begin
                        k_v  = 128'h000102030405060708090a0b0c0d0e0f;
                        pt_v = 128'hdeadbeefcafebabe1234567890abcdef;
                    end
                    3'd3: begin
                        k_v  = 128'hffffffffffffffffffffffffffffffff;
                        pt_v = 128'h00000000000000000000000000000000;
                    end
                    3'd4: begin
                        k_v  = 128'ha5a5a5a55a5a5a5affffffff00000000;
                        pt_v = 128'ha5a5a5a55a5a5a5a5a5a5a5a5a5a5a5a;
                    end
                    3'd5: begin
                        k_v  = 128'h1234567890abcdef1234567890abcdef;
                        pt_v = 128'hfedcba9876543210fedcba9876543210;
                    end
                endcase
                do_sm4(k_v, pt_v, 1'b0);
                ct_v = result;
                do_sm4(k_v, ct_v, 1'b1);
                chk_eq(pt_v, 10'd60 + i);
            end
        end

        // =====================================================================
        // T7: 双模式一致性 (同一向量 en=0 与 en=1 必须逐位相同)
        // =====================================================================
        $display("=== T7: dual-mode consistency en=0 vs en=1 (6 vectors) ===");
        begin : t7
            integer i;
            reg [127:0] pt_v;
            reg [127:0] ct_v;
            reg [127:0] k_v;
            for (i = 0; i < 6; i = i + 1) begin
                case (i)
                    3'd0: begin
                        k_v  = 128'h0123456789abcdeffedcba9876543210;
                        pt_v = 128'h0123456789abcdeffedcba9876543210;
                    end
                    3'd1: begin
                        k_v  = 128'hfedcba9876543210fedcba9876543210;
                        pt_v = 128'h00112233445566778899aabbccddeeff;
                    end
                    3'd2: begin
                        k_v  = 128'h000102030405060708090a0b0c0d0e0f;
                        pt_v = 128'hdeadbeefcafebabe1234567890abcdef;
                    end
                    3'd3: begin
                        k_v  = 128'hffffffffffffffffffffffffffffffff;
                        pt_v = 128'h00000000000000000000000000000000;
                    end
                    3'd4: begin
                        k_v  = 128'ha5a5a5a55a5a5a5affffffff00000000;
                        pt_v = 128'ha5a5a5a55a5a5a5a5a5a5a5a5a5a5a5a;
                    end
                    3'd5: begin
                        k_v  = 128'h1234567890abcdef1234567890abcdef;
                        pt_v = 128'hfedcba9876543210fedcba9876543210;
                    end
                endcase
                masked_en = 1'b0;
                do_sm4(k_v, pt_v, 1'b0);
                ct_v = result;
                masked_en = 1'b1;
                do_sm4(k_v, pt_v, 1'b0);
                chk_eq(ct_v, 10'd70 + i);
            end
        end
        masked_en = 1'b1;

        // =====================================================================
        // T8: masked_en=1  16 块连续 (双缓冲轮换), 逐块与参考比对
        // =====================================================================
        $display("=== T8: masked_en=1  16 consecutive blocks ===");
        begin : t8
            integer i;
            reg [127:0] pt_v;
            reg [127:0] ct_ref;
            for (i = 0; i < 16; i = i + 1) begin
                case (i)
                    4'd0: begin
                        pt_v   = 128'h00000000000000000000000000000000;
                        ct_ref = 128'h2677f46b09c122cc975533105bd4a22a;
                    end
                    4'd1: begin
                        pt_v   = 128'h00000001000000010000000100000001;
                        ct_ref = 128'h5e8bd818e0ff695014bacee0c3b4d6cb;
                    end
                    4'd2: begin
                        pt_v   = 128'h00000002000000020000000200000002;
                        ct_ref = 128'he0e0b1becbc1c68496007a462084ce0f;
                    end
                    4'd3: begin
                        pt_v   = 128'h00000003000000030000000300000003;
                        ct_ref = 128'h251222e823f8ab91cd8d8b3bff070668;
                    end
                    4'd4: begin
                        pt_v   = 128'h00000004000000040000000400000004;
                        ct_ref = 128'hd90fd85db294362f4f0b137bed5459fa;
                    end
                    4'd5: begin
                        pt_v   = 128'h00000005000000050000000500000005;
                        ct_ref = 128'h2f89d36adb0fcd6ac463a28295c89742;
                    end
                    4'd6: begin
                        pt_v   = 128'h00000006000000060000000600000006;
                        ct_ref = 128'hee5ac11581e2b8507e6494ffd77dbf7c;
                    end
                    4'd7: begin
                        pt_v   = 128'h00000007000000070000000700000007;
                        ct_ref = 128'h60033bf96af417607fed39d6ac00870e;
                    end
                    4'd8: begin
                        pt_v   = 128'h00000008000000080000000800000008;
                        ct_ref = 128'hc8cd9cdc974974a4c2b067775e8f2975;
                    end
                    4'd9: begin
                        pt_v   = 128'h00000009000000090000000900000009;
                        ct_ref = 128'h8aebe0f7fafee803066e759a97f714fa;
                    end
                    4'd10: begin
                        pt_v   = 128'h0000000a0000000a0000000a0000000a;
                        ct_ref = 128'hbb22f082d767e022fd9c647499ab412f;
                    end
                    4'd11: begin
                        pt_v   = 128'h0000000b0000000b0000000b0000000b;
                        ct_ref = 128'h526956374b4f9bee3504c17c30e14a12;
                    end
                    4'd12: begin
                        pt_v   = 128'h0000000c0000000c0000000c0000000c;
                        ct_ref = 128'h71463e16318e06bb545aee48d82a12b8;
                    end
                    4'd13: begin
                        pt_v   = 128'h0000000d0000000d0000000d0000000d;
                        ct_ref = 128'hc9b4e0cf4e345e2770f8ce0ed52795b8;
                    end
                    4'd14: begin
                        pt_v   = 128'h0000000e0000000e0000000e0000000e;
                        ct_ref = 128'h31c5c302dc7c9b3324da321aa3e4d874;
                    end
                    4'd15: begin
                        pt_v   = 128'h0000000f0000000f0000000f0000000f;
                        ct_ref = 128'hf2bdaaf7a0aa71a3bb373acf22709422;
                    end
                endcase
                do_sm4(128'h0123456789abcdeffedcba9876543210, pt_v, 1'b0);
                chk_eq(ct_ref, 10'd80 + i);
            end
        end

        // =====================================================================
        // T9: 侧信道观测端口自洽
        //   sbox_addr_tap 必须 == 真实查询点 ^ 当前生效掩码 c
        // =====================================================================
        $display("=== T9: side-channel observation ports ===");
        begin : t9
            reg [127:0] ct_v;
            reg [7:0]   c_v;
            reg [7:0]   exp_addr;
            do_sm4(128'h0123456789abcdeffedcba9876543210, 128'h0123456789abcdeffedcba9876543210, 1'b0);
            ct_v = result;
            c_v  = sbox_mask_c_tap;
            exp_addr = 8'hf0 ^ c_v;
            if (sbox_mask_valid === 1'b1) begin
                $display("  PASS[#90]: sbox_mask_valid=1");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL[#90]: sbox_mask_valid=0");
                fail_cnt = fail_cnt + 1;
            end
            if (c_v !== 8'h00) begin
                $display("  PASS[#91]: c_tap=%h (non-zero)", c_v);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL[#91]: c_tap=0 (degenerate)");
                fail_cnt = fail_cnt + 1;
            end
            if (sbox_addr_tap === exp_addr) begin
                $display("  PASS[#92]: addr_tap=%h == ref^c (%h^%h)",
                         sbox_addr_tap, 8'hf0, c_v);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL[#92]: addr_tap=%h exp=%h",
                         sbox_addr_tap, exp_addr);
                fail_cnt = fail_cnt + 1;
            end
        end

        // =====================================================================
        // T10: 连续 8 块 c_tap 互异非零 (LFSR 多样性)
        // =====================================================================
        $display("=== T10: 8 consecutive blocks, c_tap diversity ===");
        begin : t10
            integer i;
            integer j;
            integer distinct_ok;
            reg [127:0] pt_v;
            reg [127:0] ct_ref;
            reg [7:0]   c_hist [0:7];
            for (i = 0; i < 16; i = i + 1) begin
                case (i)
                    4'd0: begin
                        pt_v   = 128'h00000000000000000000000000000000;
                        ct_ref = 128'h2677f46b09c122cc975533105bd4a22a;
                    end
                    4'd1: begin
                        pt_v   = 128'h00000001000000010000000100000001;
                        ct_ref = 128'h5e8bd818e0ff695014bacee0c3b4d6cb;
                    end
                    4'd2: begin
                        pt_v   = 128'h00000002000000020000000200000002;
                        ct_ref = 128'he0e0b1becbc1c68496007a462084ce0f;
                    end
                    4'd3: begin
                        pt_v   = 128'h00000003000000030000000300000003;
                        ct_ref = 128'h251222e823f8ab91cd8d8b3bff070668;
                    end
                    4'd4: begin
                        pt_v   = 128'h00000004000000040000000400000004;
                        ct_ref = 128'hd90fd85db294362f4f0b137bed5459fa;
                    end
                    4'd5: begin
                        pt_v   = 128'h00000005000000050000000500000005;
                        ct_ref = 128'h2f89d36adb0fcd6ac463a28295c89742;
                    end
                    4'd6: begin
                        pt_v   = 128'h00000006000000060000000600000006;
                        ct_ref = 128'hee5ac11581e2b8507e6494ffd77dbf7c;
                    end
                    4'd7: begin
                        pt_v   = 128'h00000007000000070000000700000007;
                        ct_ref = 128'h60033bf96af417607fed39d6ac00870e;
                    end
                    4'd8: begin
                        pt_v   = 128'h00000008000000080000000800000008;
                        ct_ref = 128'hc8cd9cdc974974a4c2b067775e8f2975;
                    end
                    4'd9: begin
                        pt_v   = 128'h00000009000000090000000900000009;
                        ct_ref = 128'h8aebe0f7fafee803066e759a97f714fa;
                    end
                    4'd10: begin
                        pt_v   = 128'h0000000a0000000a0000000a0000000a;
                        ct_ref = 128'hbb22f082d767e022fd9c647499ab412f;
                    end
                    4'd11: begin
                        pt_v   = 128'h0000000b0000000b0000000b0000000b;
                        ct_ref = 128'h526956374b4f9bee3504c17c30e14a12;
                    end
                    4'd12: begin
                        pt_v   = 128'h0000000c0000000c0000000c0000000c;
                        ct_ref = 128'h71463e16318e06bb545aee48d82a12b8;
                    end
                    4'd13: begin
                        pt_v   = 128'h0000000d0000000d0000000d0000000d;
                        ct_ref = 128'hc9b4e0cf4e345e2770f8ce0ed52795b8;
                    end
                    4'd14: begin
                        pt_v   = 128'h0000000e0000000e0000000e0000000e;
                        ct_ref = 128'h31c5c302dc7c9b3324da321aa3e4d874;
                    end
                    4'd15: begin
                        pt_v   = 128'h0000000f0000000f0000000f0000000f;
                        ct_ref = 128'hf2bdaaf7a0aa71a3bb373acf22709422;
                    end
                endcase
                do_sm4(128'h0123456789abcdeffedcba9876543210, pt_v, 1'b0);
                chk_eq(ct_ref, 10'd100 + i);
            end
            distinct_ok = 1;
            for (i = 0; i < 8; i = i + 1) begin
                c_hist[i] = 8'h00;
            end
            // 重跑 8 块仅记录 c_tap
            for (i = 0; i < 8; i = i + 1) begin
                do_sm4(128'h0123456789abcdeffedcba9876543210, 128'h0123456789abcdeffedcba9876543210, 1'b0);
                c_hist[i] = sbox_mask_c_tap;
                if (sbox_mask_c_tap === 8'h00) distinct_ok = 0;
                for (j = 0; j < i; j = j + 1) begin
                    if (sbox_mask_c_tap === c_hist[j]) distinct_ok = 0;
                end
            end
            if (distinct_ok) begin
                $display("  PASS[#110]: 8 blocks c_tap all distinct & non-zero");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL[#110]: c_tap repeated or zero");
                fail_cnt = fail_cnt + 1;
            end
        end

        // =====================================================================
        // T11: 外部注入模式 (生产环境接 trng_sm3 的接口路径)
        // =====================================================================
        $display("=== T11: external mask table injection (4 constants) ===");
        begin : t11
            integer i;
            for (i = 0; i < 4; i = i + 1) begin
                case (i)
                    2'd0: begin
                        sbox_mask_c_ext   = 8'h3c;
                        sbox_mask_tbl_ext = 2048'h92af1b8d7fbcddbb415cd911d85a101f8831c10abd7bcda512d0742db0b4e5b84a9769897e77960c09f1b96584c66ec5ec7df018204ddc3a3e5fee794839cbd7d28abfeab538c740cef2f7a3a11561f9a45daee0551a349b303293ade3b18cf52ee2f61d60ca6682ab2329c06f4e530d4537dbd52f8efdde726aff03515b6c6dfca70747ba1773f3193c5983a84f85e6b2816b688bda64714b0febf8359d56705e0e241ea2d158633b7c222587782101574600d45227d39fe702364c9ec8c4a0fee990d6b73de1ccc214b616052cfb28769a672bc304be2a261344aa99068649f450429c7a98ef91430b543362accfeda91cb3e495e808c9fa94df80a63f8f75;
                    end
                    2'd1: begin
                        sbox_mask_c_ext   = 8'ha5;
                        sbox_mask_tbl_ext = 2048'h0f4bf8eb9d35705681b2686bda8b71643c1983594fa8e685a7fc470717baf37302e74c36c89ea0c44657d40027529fd37c3b2522788701210e5e1e24d1a263581326aa44069949869a762b6704c32abe14c216b62c0528fbe9fed6903db7cce194fa80df3fa6758f1ca9e4b3e895c9080b433354ac62edcf50f49c42987a91efd0122d74b4b0b8e531880ac17bbda5cd5c4111d95ad81f10af928d1bbc7fbbdd5f3e79ee3948d7cb7dec18f04d203adcf10965b9c684c56e974a8969777e0c963230ad93b1e3f58c5da4e0ae1a559b34f2cea3f715a1f9618ad2eabf38b540c76a7203ff5b516d6c3745d5db8e2fdefd23abc0294e6f0d53e22e1df6ca608266;
                    end
                    2'd2: begin
                        sbox_mask_c_ext   = 8'hf1;
                        sbox_mask_tbl_ext = 2048'h2c0528fb14c216b63db7cce1e9fed690069949861326aa4404c32abe9a762b67ac62edcf0b433354987a91ef50f49c423fa6758f94fa80dfe895c9081ca9e4b34fa8e6853c19835917baf373a7fc47079d3570560f4bf8ebda8b716481b2686b788701217c3b2522d1a263580e5e1e24c89ea0c402e74c3627529fd34657d40015a1f961f2cea3f738b540c78ad2eabfb1e3f58c3230ad931a559b345da4e0ae4e6f0d5323abc029ca608266e22e1df65b516d6c6a7203ff8e2fdefd3745d5db5ad81f105c4111d9bc7fbbddaf928d1bb4b0b8e5d0122d747bbda5cd31880ac1c684c56ef10965b9777e0c96974a89693948d7cb5f3e79ee4d203adc7dec18f0;
                    end
                    2'd3: begin
                        sbox_mask_c_ext   = 8'h02;
                        sbox_mask_tbl_ext = 2048'hcbd74839ee793e5fdc3a204df018ec7d6ec584c6b96509f1960c7e7769894a97e5b8b0b4742d12d0cda5bd7bc10a8831101fd85ad911415cddbb7fbc1b8d92af6c6d515bff03726afdde2f8edbd54537530d6f4e29c0ab23668260caf61d2ee28cf5e3b193ad3032349b551aaee0a45d61f9a115f7a3cef2c740b538bfead28ac4a09ec8364ce702d39f522700d457462101877822253b7c5863a2d1241e5e0e5670359debf84b0f64718bda6b68b28185e6a84f5983193c73f3ba170747fca78f75a63fdf80fa9408c995e8b3e4a91ccfed62ac5433430bef917a98429cf4508649990644aa2613be2ac304672b769afb28052cb616c214e1ccb73d90d6fee9;
                    end
                endcase
                sbox_mask_ext_en = 1'b1;
                do_sm4(128'h0123456789abcdeffedcba9876543210, 128'h0123456789abcdeffedcba9876543210, 1'b0);
                chk_eq(128'h681edf34d206965e86b3e94f536e4246, 10'd120 + i);
            end
            sbox_mask_ext_en = 1'b0;
        end

        // =====================================================================
        // T12: 外部注入 -> 内部刷新 模式切换回归
        // =====================================================================
        $display("=== T12: ext-inject -> internal-refresh switchback ===");
        do_sm4(128'h0123456789abcdeffedcba9876543210, 128'h0123456789abcdeffedcba9876543210, 1'b0);
        chk_eq(128'h681edf34d206965e86b3e94f536e4246, 10'd130);
        do_sm4(128'h0123456789abcdeffedcba9876543210, 128'h681edf34d206965e86b3e94f536e4246, 1'b1);
        chk_eq(128'h0123456789abcdeffedcba9876543210, 10'd131);

        // =====================================================================
        // 汇总
        // =====================================================================
        $display("====================================================");
        $display("SM4_ENGINE_MASKED_V2 (B-3) REGRESSION SUMMARY");
        $display("  PASS: %0d", pass_cnt);
        $display("  FAIL: %0d", fail_cnt);
        $display("====================================================");
        if (fail_cnt == 0) $display("ALL PASS");
        else               $display("SOME FAILED");
        $finish;
    end

    initial begin
        #3000000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
