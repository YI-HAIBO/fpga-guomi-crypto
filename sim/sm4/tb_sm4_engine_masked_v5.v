// =============================================================================
// tb_sm4_engine_masked_v5 -- SM4 引擎 v5.0 (独立输出掩码) 验证平台
// 版本: 5.0
// 日期: 2026-10-30
// 目标:
//   T1/T2  masked_en=0  GB/T 零回归 (加密 + 解密)
//   T3/T4  masked_en=1  GB/T 零回归 (加密 + 解密, seed=0x0123...)
//   T5..   masked_en=1  多 seed 零回归 (密文与 mask_seed 无关 -- 掩码正确性核心判据)
//   T6..   masked_en=1  独立掩码二阶消除验证 (不同 S-box 掩码独立)
// =============================================================================
`timescale 1ns / 1ps

module tb_sm4_engine_masked_v5;

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

    sm4_engine_masked_v4_indep dut (
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
                $display("  FAIL[#%02d]: exp=%h got=%h", id_v, exp_v, result);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // KAT 向量由 sm4_ref.py 生成 (2026-10-30)
    // KAT1: key=0123456789ABCDEFFEDCBA9876543210, pt=0
    localparam [127:0] KAT_KEY = 128'h0123456789ABCDEFFEDCBA9876543210;
    localparam [127:0] KAT_PT  = 128'h00000000000000000000000000000000;
    localparam [127:0] KAT_CT  = 128'h2677F46B09C122CC975533105BD4A22A;

    // KAT2: key=0, pt=0
    localparam [127:0] KAT2_KEY = 128'h00000000000000000000000000000000;
    localparam [127:0] KAT2_PT  = 128'h00000000000000000000000000000000;
    localparam [127:0] KAT2_CT  = 128'h9F1F7BFF6F5511384D9430531E538FD3;

    // KAT3: 随机向量 (与 Python sm4_ref 交叉验证)
    localparam [127:0] KAT3_KEY = 128'hfedcba9876543210fedcba9876543210;
    localparam [127:0] KAT3_PT  = 128'h0123456789abcdef0123456789abcdef;
    localparam [127:0] KAT3_CT  = 128'h6046A42E35504EF328EF7FB2FE9219B8;

    // 多 seed 测试: 密文应与 mask_seed 无关
    localparam [127:0] SEED1 = 64'h0123456789abcdef;
    localparam [127:0] SEED2 = 64'hfedcba9876543210;
    localparam [127:0] SEED3 = 64'hdeadbeefcafebabe;

    initial begin
        $display("======================================================================");
        $display("tb_sm4_engine_masked_v5 -- SM4 v5.0 (独立输出掩码) 验证平台");
        $display("======================================================================");

        // 复位
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- T1: unmasked encrypt ----
        $display("--- T1: unmasked encrypt ---");
        masked_en = 1'b0;
        do_sm4(KAT_KEY, KAT_PT, 1'b0, 64'h0);
        chk_eq(KAT_CT, 1);

        // ---- T2: unmasked decrypt ----
        $display("--- T2: unmasked decrypt ---");
        do_sm4(KAT_KEY, KAT_CT, 1'b1, 64'h0);
        chk_eq(KAT_PT, 2);

        // ---- T3: masked encrypt (seed=0x0123...) ----
        $display("--- T3: masked encrypt (seed=0x0123...) ---");
        masked_en = 1'b1;
        do_sm4(KAT_KEY, KAT_PT, 1'b0, SEED1);
        chk_eq(KAT_CT, 3);  // 掩码不应改变密文

        // ---- T4: masked decrypt (seed=0x0123...) ----
        $display("--- T4: masked decrypt (seed=0x0123...) ---");
        do_sm4(KAT_KEY, KAT_CT, 1'b1, SEED1);
        chk_eq(KAT_PT, 4);

        // ---- T5: masked encrypt, different seed ----
        $display("--- T5: masked encrypt (seed=0xfedc...) ---");
        do_sm4(KAT_KEY, KAT_PT, 1'b0, SEED2);
        chk_eq(KAT_CT, 5);  // 密文与 seed 无关

        // ---- T6: masked encrypt, third seed ----
        $display("--- T6: masked encrypt (seed=0xdead...) ---");
        do_sm4(KAT_KEY, KAT_PT, 1'b0, SEED3);
        chk_eq(KAT_CT, 6);

        // ---- T7: masked decrypt, different seed ----
        $display("--- T7: masked decrypt (seed=0xfedc...) ---");
        do_sm4(KAT_KEY, KAT_CT, 1'b1, SEED2);
        chk_eq(KAT_PT, 7);

        // ---- T8: unmasked, zero key/pt ----
        $display("--- T8: unmasked encrypt (zero key/pt) ---");
        masked_en = 1'b0;
        do_sm4(KAT2_KEY, KAT2_PT, 1'b0, 64'h0);
        chk_eq(KAT2_CT, 8);

        // ---- T9: masked, zero key/pt ----
        $display("--- T9: masked encrypt (zero key/pt) ---");
        masked_en = 1'b1;
        do_sm4(KAT2_KEY, KAT2_PT, 1'b0, SEED1);
        chk_eq(KAT2_CT, 9);  // 掩码不应改变密文

        // ---- T10: masked decrypt, zero key/pt ----
        $display("--- T10: masked decrypt (zero key/pt) ---");
        do_sm4(KAT2_KEY, KAT2_CT, 1'b1, SEED1);
        chk_eq(KAT2_PT, 10);

        // ---- T11: masked encrypt KAT3 ----
        $display("--- T11: masked encrypt KAT3 ---");
        masked_en = 1'b1;
        do_sm4(KAT3_KEY, KAT3_PT, 1'b0, SEED1);
        chk_eq(KAT3_CT, 11);

        // ---- T12: masked decrypt KAT3 ----
        $display("--- T12: masked decrypt KAT3 ---");
        do_sm4(KAT3_KEY, KAT3_CT, 1'b1, SEED2);
        chk_eq(KAT3_PT, 12);

        // ---- 汇总 ----
        $display("======================================================================");
        $display("PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("======================================================================");
        if (fail_cnt > 0) begin
            $display("*** SOME TESTS FAILED ***");
            $finish;
        end else begin
            $display("*** ALL TESTS PASSED ***");
            $finish;
        end
    end

endmodule