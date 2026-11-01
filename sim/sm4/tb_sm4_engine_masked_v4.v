// =============================================================================
// tb_sm4_engine_masked_v4 -- SM4 引擎 v4 验证平台
// 版本: 4.0
// 日期: 2026-10-25
// 目标:
//   T1/T2  masked_en=0  GB/T 零回归 (加密 + 解密)
//   T3/T4  masked_en=1  GB/T 零回归 (加密 + 解密, seed=0x0123...)
//   T5..   masked_en=1  多 seed 零回归 (密文与 mask_seed 无关 -- 掩码正确性核心判据)
// =============================================================================
`timescale 1ns / 1ps

module tb_sm4_engine_masked_v4;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg [127:0] key = 128'h0;
    reg [127:0] plaintext = 128'h0;
    reg decrypt = 1'b0;
    reg [127:0] ciphertext = 128'h0;

    reg masked_en = 1'b0;
    reg [63:0] mask_seed = 64'h0;

    wire [127:0] result;
    wire done, busy;

    sm4_engine_masked_v4 dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .key(key), .plaintext(plaintext), .decrypt(decrypt), .ciphertext(ciphertext),
        .result(result), .done(done), .busy(busy),
        .masked_en(masked_en), .mask_seed(mask_seed)
    );

    always #5 clk = ~clk;

    integer timeout_cnt;
    integer pass_cnt = 0;
    integer fail_cnt = 0;
    reg [127:0] ct_ref;

    // 发起一次加/解密并等 done
    task do_sm4;
        input [127:0] k_in;
        input [127:0] data_in;
        input dec_in;
        input [63:0] seed_in;
        begin
            @(negedge clk);
            key        = k_in;
            plaintext  = data_in;
            ciphertext = data_in;
            decrypt    = dec_in;
            mask_seed  = seed_in;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            timeout_cnt = 0;
            @(posedge clk);
            while (!done && timeout_cnt < 1000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (timeout_cnt >= 1000) begin
                $display("  FAIL: timeout after %0d cycles", timeout_cnt);
                $finish;
            end
        end
    endtask

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

    localparam [127:0] KAT_KEY = 128'h0123456789abcdeffedcba9876543210;
    localparam [127:0] KAT_PT  = 128'h0123456789abcdeffedcba9876543210;
    localparam [127:0] KAT_CT  = 128'h681edf34d206965e86b3e94f536e4246;

    initial begin
        rst_n     = 1'b0;
        masked_en = 1'b0;
        #30;
        @(negedge clk);
        rst_n = 1'b1;
        #10;

        // T1: en=0 加密
        $display("=== T1: masked_en=0 GB/T official (encrypt) ===");
        do_sm4(KAT_KEY, KAT_PT, 1'b0, 64'h0);
        chk_eq(KAT_CT, 10'd1);

        // T2: en=0 解密
        $display("=== T2: masked_en=0 GB/T official (decrypt) ===");
        do_sm4(KAT_KEY, KAT_CT, 1'b1, 64'h0);
        chk_eq(KAT_PT, 10'd2);

        // T3: en=1 加密 (seed A)
        $display("=== T3: masked_en=1 GB/T official (encrypt, seedA) ===");
        masked_en = 1'b1;
        do_sm4(KAT_KEY, KAT_PT, 1'b0, 64'h0123456789ABCDEF);
        chk_eq(KAT_CT, 10'd3);

        // T4: en=1 解密 (seed A)
        $display("=== T4: masked_en=1 GB/T official (decrypt, seedA) ===");
        do_sm4(KAT_KEY, KAT_CT, 1'b1, 64'h0123456789ABCDEF);
        chk_eq(KAT_PT, 10'd4);

        // T5..T10: en=1 多 seed 零回归 (密文与 seed 无关)
        $display("=== T5-T10: masked_en=1 multi-seed zero-regression (encrypt) ===");
        do_sm4(KAT_KEY, KAT_PT, 1'b0, 64'h0000000000000001); chk_eq(KAT_CT, 10'd5);
        do_sm4(KAT_KEY, KAT_PT, 1'b0, 64'hB000000000000000); chk_eq(KAT_CT, 10'd6);
        do_sm4(KAT_KEY, KAT_PT, 1'b0, 64'hFFFFFFFFFFFFFFFF); chk_eq(KAT_CT, 10'd7);
        do_sm4(KAT_KEY, KAT_PT, 1'b0, 64'hDEADBEEFCAFEBABE); chk_eq(KAT_CT, 10'd8);
        do_sm4(KAT_KEY, KAT_PT, 1'b0, 64'h7FFFFFFFFFFFFFFF); chk_eq(KAT_CT, 10'd9);
        do_sm4(KAT_KEY, KAT_PT, 1'b0, 64'h0000000000000000); chk_eq(KAT_CT, 10'd10);

        // T11: en=1 解密 (seed B)
        $display("=== T11: masked_en=1 GB/T official (decrypt, seedB) ===");
        do_sm4(KAT_KEY, KAT_CT, 1'b1, 64'hCAFEBABEDEADBEEF);
        chk_eq(KAT_PT, 10'd11);

        // T12: 非官方向量跨 seed 一致性 (同一 key/pt, 两个 seed, 结果必须相同且等于 en=0)
        $display("=== T12: random vector cross-seed consistency ===");
        masked_en = 1'b0;
        do_sm4(128'hAABBCCDDEEFF00112233445566778899,
               128'h00112233445566778899AABBCCDDEEFF, 1'b0, 64'h0);
        ct_ref = result;
        masked_en = 1'b1;
        do_sm4(128'hAABBCCDDEEFF00112233445566778899,
               128'h00112233445566778899AABBCCDDEEFF, 1'b0, 64'h1111111111111111);
        if (result === ct_ref) begin
            $display("  PASS[#12]");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL[#12]: exp %h", ct_ref);
            $display("           got      %h", result);
            fail_cnt = fail_cnt + 1;
        end
        do_sm4(128'hAABBCCDDEEFF00112233445566778899,
               128'h00112233445566778899AABBCCDDEEFF, 1'b0, 64'h2222222222222222);
        if (result === ct_ref) begin
            $display("  PASS[#13]");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL[#13]: exp %h", ct_ref);
            $display("           got      %h", result);
            fail_cnt = fail_cnt + 1;
        end

        $display("====================================================");
        $display("SM4_ENGINE_MASKED_V4 (v4.0) REGRESSION SUMMARY");
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
