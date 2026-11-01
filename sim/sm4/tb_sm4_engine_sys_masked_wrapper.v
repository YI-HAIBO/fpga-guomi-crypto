// =============================================================================
// tb_sm4_engine_sys_masked_wrapper.v -- Wrapper POC 验证 (简化版)
// =============================================================================
// 目标：
//   T1: wrapper_masked_en=0 时，与参考 sm4_engine_sys 逐字节一致（零回归）
//   T2: wrapper_masked_en=1 时，result 被随机化，但 result ^ r_out == 参考
//   T3: wrapper_masked_en=1 时，两次加密 r_out 不同（掩码独立性）
//   T4: 掩码关闭时解密往返仍成立（GB/T 官方解密向量）
// =============================================================================

`timescale 1ns / 1ps

module tb_sm4_engine_sys_masked_wrapper;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         start = 1'b0;
    reg  [127:0] key = 128'd0;
    reg  [127:0] plaintext = 128'd0;
    reg         decrypt = 1'b0;
    reg  [127:0] ciphertext = 128'd0;

    // TRNG 接口
    reg  [127:0] trng_data = 128'd0;
    reg          trng_valid = 1'b1;

    // =========================================================================
    // DUT-REF: 原始 sm4_engine_sys（参考）
    // =========================================================================
    wire [127:0] ref_result;
    wire         ref_done;
    wire         ref_busy;

    sm4_engine_sys dut_ref (
        .clk(clk), .rst_n(rst_n),
        .start(start), .key(key), .plaintext(plaintext),
        .decrypt(decrypt), .ciphertext(ciphertext),
        .result(ref_result), .done(ref_done), .busy(ref_busy)
    );

    // =========================================================================
    // DUT-A: wrapper_masked_en=0（默认关闭，零回归）
    // =========================================================================
    wire [127:0] a_result, a_r_out;
    wire         a_done, a_busy;

    sm4_engine_sys_masked_wrapper #(.wrapper_masked_en(1'b0)) dut_a (
        .clk(clk), .rst_n(rst_n),
        .start(start), .key(key), .plaintext(plaintext),
        .decrypt(decrypt), .ciphertext(ciphertext),
        .trng_data(trng_data), .trng_valid(trng_valid),
        .result(a_result), .r_out(a_r_out),
        .done(a_done), .busy(a_busy)
    );

    // =========================================================================
    // DUT-B: wrapper_masked_en=1（输出掩码开启）
    // =========================================================================
    wire [127:0] b_result, b_r_out;
    wire         b_done, b_busy;

    sm4_engine_sys_masked_wrapper #(.wrapper_masked_en(1'b1)) dut_b (
        .clk(clk), .rst_n(rst_n),
        .start(start), .key(key), .plaintext(plaintext),
        .decrypt(decrypt), .ciphertext(ciphertext),
        .trng_data(trng_data), .trng_valid(trng_valid),
        .result(b_result), .r_out(b_r_out),
        .done(b_done), .busy(b_busy)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // 全局超时保护
    initial begin
        #2000000;
        $display("FAIL: global timeout at time %0t", $time);
        $finish;
    end

    initial begin
        $display("==================== wrapper POC TB ===================");

        // 复位
        rst_n = 1'b0;
        #30;
        @(negedge clk);
        rst_n = 1'b1;
        #10;

        // =========================================================================
        // T1: wrapper_en=0 应与参考完全一致（GB/T 官方向量加密）
        // =========================================================================
        $display("[T1] wrapper_en=0 encrypt: a_result == ref_result == 681EDF...");

        // 设置输入
        key       = 128'h0123456789ABCDEFFEDCBA9876543210;
        plaintext = 128'h0123456789ABCDEFFEDCBA9876543210;
        ciphertext = 128'h0123456789ABCDEFFEDCBA9876543210;
        decrypt   = 1'b0;
        trng_data = 128'hDEADBEEFDEADBEEFDEADBEEFDEADBEEF;
        trng_valid = 1'b1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // 等 ref_done 上升沿
        @(posedge ref_done);
        #1;

        // 检查
        if (ref_result === 128'h681EDF34D206965E86B3E94F536E4246) begin
            pass_cnt = pass_cnt + 1;
            $display("  PASS ref_result = 681EDF34D206965E86B3E94F536E4246");
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("  FAIL ref_result expected 681EDF34D206965E86B3E94F536E4246 got %h", ref_result);
        end
        if (a_result === ref_result) begin
            pass_cnt = pass_cnt + 1;
            $display("  PASS a_result == ref_result (零回归)");
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("  FAIL a_result (%h) != ref_result (%h)", a_result, ref_result);
        end
        if (a_r_out === 128'd0) begin
            pass_cnt = pass_cnt + 1;
            $display("  PASS a_r_out == 0 (关闭时 r_out 强制为 0)");
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("  FAIL a_r_out expected 0 got %h", a_r_out);
        end

        // =========================================================================
        // T2: wrapper_en=1 输出被随机化
        // =========================================================================
        $display("[T2] wrapper_en=1 encrypt: b_result ^ b_r_out == ref_result");

        // 设置输入（新 trng）
        key       = 128'h0123456789ABCDEFFEDCBA9876543210;
        plaintext = 128'h0123456789ABCDEFFEDCBA9876543210;
        ciphertext = 128'h0123456789ABCDEFFEDCBA9876543210;
        decrypt   = 1'b0;
        trng_data = 128'hA5A5A5A5A5A5A5A55A5A5A5A5A5A5A5A;
        trng_valid = 1'b1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        @(posedge ref_done);
        #1;

        // 保存参考值
        begin : save_ref
            reg [127:0] ref_save;
            reg [127:0] b_res_save;
            reg [127:0] b_r_save;
            ref_save = ref_result;
            b_res_save = b_result;
            b_r_save = b_r_out;
            $display("  ref_result = %h", ref_save);
            $display("  b_result   = %h", b_res_save);
            $display("  b_r_out    = %h", b_r_save);
            $display("  b_result^b_r_out = %h", b_res_save ^ b_r_save);
        end

        if (b_r_out === 128'hA5A5A5A5A5A5A5A55A5A5A5A5A5A5A5A) begin
            pass_cnt = pass_cnt + 1;
            $display("  PASS b_r_out sampled correctly");
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("  FAIL b_r_out expected A5A5...5A5A got %h", b_r_out);
        end
        if (b_result !== ref_result) begin
            pass_cnt = pass_cnt + 1;
            $display("  PASS b_result != ref_result (已随机化)");
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("  FAIL b_result == ref_result (未随机化)");
        end
        if ((b_result ^ b_r_out) === ref_result) begin
            pass_cnt = pass_cnt + 1;
            $display("  PASS (b_result^b_r_out) == ref_result (掩码可恢复)");
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("  FAIL (b_result^b_r_out)=%h != ref_result=%h", b_result ^ b_r_out, ref_result);
        end

        // =========================================================================
        // T3: wrapper_en=1 第二次加密 r_out 不同
        // =========================================================================
        $display("[T3] wrapper_en=1 second encrypt with different trng");

        key       = 128'h0123456789ABCDEFFEDCBA9876543210;
        plaintext = 128'h0123456789ABCDEFFEDCBA9876543210;
        ciphertext = 128'h0123456789ABCDEFFEDCBA9876543210;
        decrypt   = 1'b0;
        trng_data = 128'h1234567890ABCDEF1234567890ABCDEF;
        trng_valid = 1'b1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        @(posedge ref_done);
        #1;

        if (b_r_out === 128'h1234567890ABCDEF1234567890ABCDEF) begin
            pass_cnt = pass_cnt + 1;
            $display("  PASS b_r_out updated to new trng");
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("  FAIL b_r_out expected 1234567890ABCDEF... got %h", b_r_out);
        end
        if ((b_result ^ b_r_out) === 128'h681EDF34D206965E86B3E94F536E4246) begin
            pass_cnt = pass_cnt + 1;
            $display("  PASS (b_result^b_r_out) == 681EDF... (二次掩码可恢复)");
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("  FAIL (b_result^b_r_out)=%h expected 681EDF...", b_result ^ b_r_out);
        end

        // =========================================================================
        // T4: 掩码关闭时解密往返
        // =========================================================================
        $display("[T4] wrapper_en=0 decrypt round-trip (GB/T vector)");

        key       = 128'h0123456789ABCDEFFEDCBA9876543210;
        plaintext = 128'h681EDF34D206965E86B3E94F536E4246;
        ciphertext = 128'h681EDF34D206965E86B3E94F536E4246;
        decrypt   = 1'b1;
        trng_data = 128'd0;
        trng_valid = 1'b1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        @(posedge ref_done);
        #1;

        if (a_result === 128'h0123456789ABCDEFFEDCBA9876543210) begin
            pass_cnt = pass_cnt + 1;
            $display("  PASS decrypt round-trip OK (wrapper_en=0)");
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("  FAIL decrypt got %h expected 0123...43210", a_result);
        end

        // =========================================================================
        // 汇总
        // =========================================================================
        $display("");
        $display("==================== RESULTS ====================");
        $display("PASS: %0d", pass_cnt);
        $display("FAIL: %0d", fail_cnt);
        if (fail_cnt == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("SOME TESTS FAILED");
        end
        $finish;
    end

    // 时钟
    always #5 clk = ~clk;

endmodule
