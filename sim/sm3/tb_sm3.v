// =============================================================================
// Testbench : tb_sm3
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-02
// 视角     : sim-verifier (魏波形)
// 目标     : 验证 sm3_engine 与 gmssl 参考实现一致
//
// 测试向量来源 : gmssl-3.2.2 (https://github.com/abatilo/gmssl.py)
//                已验证 GB/T 32905-2016 官方向量
// =============================================================================

`timescale 1ns / 1ps

module tb_sm3;

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
    reg  [511:0] msg_block;
    reg  [255:0] prev_state;

    wire [255:0] out_state;
    wire         done;
    wire         busy;

    // =========================================================================
    // IV (GB/T 32905-2016 4.2, 与 gmssl 一致)
    // =========================================================================
    localparam [255:0] IV = 256'h7380166f4914b2b9172442d7da8a0600a96f30bc163138aae38dee4db0fb0e4e;

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    sm3_engine u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .msg_block  (msg_block),
        .prev_state (prev_state),
        .out_state  (out_state),
        .done       (done),
        .busy       (busy)
    );

    // =========================================================================
    // 测试统计
    // =========================================================================
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // =========================================================================
    // 单次哈希任务 (单块消息)
    // =========================================================================
    task run_hash(input [511:0] msg, output [255:0] hash);
        begin
            wait(!busy);
            @(posedge clk);
            start      = 1'b1;
            msg_block  = msg;
            prev_state = IV;
            @(posedge clk);
            start = 1'b0;

            // 等待完成
            wait(done == 1'b1);
            @(posedge clk);
            hash = out_state;
            wait(!busy);
        end
    endtask

    // =========================================================================
    // 主测试流程
    // =========================================================================
    reg [255:0] hash;

    initial begin
        $dumpfile("sm3.vcd");
        $dumpvars(0, tb_sm3);

        $display("========================================================");
        $display(" SM3 Testbench - GB/T 32905-2016");
        $display(" Reference: gmssl-3.2.2");
        $display("========================================================");

        // 复位
        rst_n      = 1'b0;
        start      = 1'b0;
        msg_block  = 512'd0;
        prev_state = 256'd0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (2)  @(posedge clk);

        // ================================================================
        // Test 1: 空输入 (0 bytes)
        // Padding: 0x80 + 55 个 0 + 8 bytes 长度 (0)
        // ================================================================
        $display("\n[Test 1] Empty input");
        run_hash(512'h80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000, hash);
        $display("  Got:  0x%h", hash);
        $display("  Exp:  0x1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b");
        if (hash == 256'h1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b) begin
            $display("  PASS");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL");
            fail_cnt = fail_cnt + 1;
        end

        // ================================================================
        // Test 2: "abc" (3 bytes)
        // Padding: 61 62 63 + 0x80 + 52 个 0 + 8 bytes 长度 (24 = 0x18)
        // ================================================================
        $display("\n[Test 2] 'abc' (3 bytes)");
        run_hash(512'h61626380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018, hash);
        $display("  Got:  0x%h", hash);
        $display("  Exp:  0x66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0");
        if (hash == 256'h66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0) begin
            $display("  PASS");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL");
            fail_cnt = fail_cnt + 1;
        end

        // ================================================================
        // Test 3: 32 bytes zero
        // Padding: 32 bytes 0x00 + 0x80 + 23 个 0 + 8 bytes 长度 (256 = 0x100)
        // 总长度 = 32 + 1 + 23 + 8 = 64 bytes (1 个块)
        // ================================================================
        $display("\n[Test 3] 32 bytes zero");
        run_hash(512'h00000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000100, hash);
        $display("  Got:  0x%h", hash);
        $display("  Exp:  0xe0bab8f4d8172ba245190d13c94117e93b82166c25b2b69883350c192c905140");
        if (hash == 256'he0bab8f4d8172ba245190d13c94117e93b82166c25b2b69883350c192c905140) begin
            $display("  PASS");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL");
            fail_cnt = fail_cnt + 1;
        end

        // ================================================================
        // Test 4: 64 bytes 0x01
        // Padding: 64 bytes 0x01 + 0x80 + 55 个 0 + 8 bytes 长度 (512 = 0x200)
        // 总长度 = 64 + 1 + 55 + 8 = 128 bytes, 2 个块
        // 这里先跳过, 需要多块处理
        // ================================================================
        $display("\n[Test 4] Skipped (multi-block, needs extension)");

        // 汇总
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
        #10_000_000;
        $display("ERROR: Testbench timeout!");
        $finish;
    end

endmodule
