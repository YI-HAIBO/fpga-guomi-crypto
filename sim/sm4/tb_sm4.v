// =============================================================================
// Testbench : tb_sm4
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-02
// 视角     : sim-verifier (魏波形)
// 目标     : 验证 sm4_engine 与 gmssl 参考实现一致
//
// 测试向量来源 : gmssl-3.2.2 (https://github.com/abatilo/gmssl.py)
//                独立 SM4 实现交叉验证 (gen_vectors.py)
//                GB/T 32907-2016 官方测试向量 (Test 1)
// =============================================================================

`timescale 1ns / 1ps

module tb_sm4;

    // =========================================================================
    // 时钟
    // =========================================================================
    reg clk;
    initial begin
        clk = 0;
        forever #5 clk = !clk;   // 100 MHz = 10 ns period
    end

    // =========================================================================
    // 信号
    // =========================================================================
    reg          rst_n;
    reg          start;
    reg  [127:0] key;
    reg  [127:0] plaintext;
    reg          decrypt;
    reg  [127:0] ciphertext;

    wire [127:0] result;
    wire         done;
    wire         busy;

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    sm4_engine u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .key        (key),
        .plaintext  (plaintext),
        .decrypt    (decrypt),
        .ciphertext (ciphertext),
        .result     (result),
        .done       (done),
        .busy       (busy)
    );

    // =========================================================================
    // 测试统计
    // =========================================================================
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // =========================================================================
    // 单次加/解密任务
    // =========================================================================
    task run_sm4(
        input  [127:0] k,
        input  [127:0] d_in,
        input          dec,
        output [127:0] d_out
    );
        begin
            wait(!busy);
            // 在负边沿设置信号, 确保在正边沿之前稳定
            @(negedge clk);
            start      = 1'b1;
            key        = k;
            plaintext  = d_in;
            ciphertext = d_in;
            decrypt    = dec;
            @(posedge clk);
            #1;  // 确保 FSM 已经采样 start=1
            start = 1'b0;

            // 等待 done 脉冲
            wait(done == 1'b1);
            @(posedge clk);
            d_out = result;
            wait(!busy);
        end
    endtask

    // =========================================================================
    // 主测试流程
    // =========================================================================
    reg [127:0] d_out;

    initial begin
        $dumpfile("sm4.vcd");
        $dumpvars(0, tb_sm4);

        $display("========================================================");
        $display(" SM4 Testbench - GB/T 32907-2016");
        $display(" Reference: gmssl-3.2.2 + independent impl");
        $display("========================================================");

        // 复位
        rst_n      = 1'b0;
        start      = 1'b0;
        key        = 128'd0;
        plaintext  = 128'd0;
        decrypt    = 1'b0;
        ciphertext = 128'd0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (2)  @(posedge clk);

        // ================================================================
        // Test 1: GB/T 32907-2016 官方测试向量 (加密)
        // ================================================================
        $display("\n[Test 1] GB/T 32907-2016 Official Vector (Encrypt)");
        run_sm4(
            128'h0123456789abcdeffedcba9876543210,   // Key
            128'h0123456789abcdeffedcba9876543210,   // Plaintext
            1'b0,                                      // Encrypt
            d_out
        );
        $display("  Got:  0x%h", d_out);
        $display("  Exp:  0x681edf34d206965e86b3e94f536e4246");
        if (d_out == 128'h681edf34d206965e86b3e94f536e4246) begin
            $display("  PASS");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL");
            fail_cnt = fail_cnt + 1;
        end

        // ================================================================
        // Test 1b: 用 Test 1 的密文解密, 验证 roundtrip
        // ================================================================
        $display("\n[Test 1b] Roundtrip (Decrypt Test 1 ciphertext)");
        run_sm4(
            128'h0123456789abcdeffedcba9876543210,   // Key
            128'h681edf34d206965e86b3e94f536e4246,   // Ciphertext
            1'b1,                                      // Decrypt
            d_out
        );
        $display("  Got:  0x%h", d_out);
        $display("  Exp:  0x0123456789abcdeffedcba9876543210");
        if (d_out == 128'h0123456789abcdeffedcba9876543210) begin
            $display("  PASS");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL");
            fail_cnt = fail_cnt + 1;
        end

        // ================================================================
        // Test 2: 零密钥 + 零明文
        // ================================================================
        $display("\n[Test 2] Zero Key + Zero Plaintext (Encrypt)");
        run_sm4(
            128'h00000000000000000000000000000000,
            128'h00000000000000000000000000000000,
            1'b0,
            d_out
        );
        $display("  Got:  0x%h", d_out);
        $display("  Exp:  0x9f1f7bff6f5511384d9430531e538fd3");
        if (d_out == 128'h9f1f7bff6f5511384d9430531e538fd3) begin
            $display("  PASS");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL");
            fail_cnt = fail_cnt + 1;
        end

        // ================================================================
        // Test 3: 全 FF 密钥 + 全 FF 明文
        // ================================================================
        $display("\n[Test 3] All-FF Key + All-FF Plaintext (Encrypt)");
        run_sm4(
            128'hffffffffffffffffffffffffffffffff,
            128'hffffffffffffffffffffffffffffffff,
            1'b0,
            d_out
        );
        $display("  Got:  0x%h", d_out);
        $display("  Exp:  0xedb119f8455fd2327ad6fbedcb5b4f5d");
        if (d_out == 128'hedb119f8455fd2327ad6fbedcb5b4f5d) begin
            $display("  PASS");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL");
            fail_cnt = fail_cnt + 1;
        end

        // ================================================================
        // Test 4: 随机密钥 + 随机明文 + roundtrip
        // ================================================================
        $display("\n[Test 4] Random Key + Random Plaintext (Encrypt)");
        run_sm4(
            128'hdeadbeefcafebabe12345678abcdef00,
            128'ha5f0b2c1d3e4f5a6b7c8d9e0f1a2b3c4,
            1'b0,
            d_out
        );
        $display("  Got:  0x%h", d_out);
        $display("  Exp:  0xd8709ee04ecf5ecdeb0833f075c434bd");
        if (d_out == 128'hd8709ee04ecf5ecdeb0833f075c434bd) begin
            $display("  PASS");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL");
            fail_cnt = fail_cnt + 1;
        end

        // Test 4b: Roundtrip decrypt
        $display("\n[Test 4b] Roundtrip (Decrypt Test 4 ciphertext)");
        run_sm4(
            128'hdeadbeefcafebabe12345678abcdef00,
            128'hd8709ee04ecf5ecdeb0833f075c434bd,
            1'b1,
            d_out
        );
        $display("  Got:  0x%h", d_out);
        $display("  Exp:  0xa5f0b2c1d3e4f5a6b7c8d9e0f1a2b3c4");
        if (d_out == 128'ha5f0b2c1d3e4f5a6b7c8d9e0f1a2b3c4) begin
            $display("  PASS");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL");
            fail_cnt = fail_cnt + 1;
        end

        // ================================================================
        // 汇总
        // ================================================================
        $display("\n========================================================");
        $display(" Test Summary");
        $display("   PASS: %0d", pass_cnt);
        $display("   FAIL: %0d", fail_cnt);
        $display("========================================================");

        if (fail_cnt == 0) begin
            $display(" ALL TESTS PASSED");
        end else begin
            $display(" SOME TESTS FAILED");
        end

        #100;
        $finish;
    end

    // =========================================================================
    // 超时保护
    // =========================================================================
    initial begin
        #50_000_000;
        $display("ERROR: Testbench timeout!");
        $finish;
    end

endmodule
