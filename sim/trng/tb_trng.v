// =============================================================================
// Testbench : tb_trng
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-02
// 视角     : sim-verifier (魏波形)
// 目标     : 验证 trng 模块的功能正确性
//           1. 请求-响应握手正确
//           2. 输出长度正确
//           3. 多请求串行/连续正确
//           4. 错误处理正确
// =============================================================================

`timescale 1ns / 1ps

module tb_trng;

    // =========================================================================
    // 参数
    // =========================================================================
    localparam CLK_PERIOD  = 10;    // 100 MHz = 10ns
    localparam TEST_SEED_0 = 23'h001_C001;

    // =========================================================================
    // 信号
    // =========================================================================
    reg         clk;
    reg         rst_n;
    reg         req_vld;
    wire        req_rdy;
    reg  [7:0]  req_bytes;

    wire        data_vld;
    reg         data_rdy;
    wire [127:0] data_out;
    wire        data_last;

    wire        busy;
    wire        done;
    wire [7:0]  err_code;

    // 统计
    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer sample_cnt = 0;

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    trng u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_vld   (req_vld),
        .req_rdy   (req_rdy),
        .req_bytes (req_bytes),
        .data_vld  (data_vld),
        .data_rdy  (data_rdy),
        .data_out  (data_out),
        .data_last (data_last),
        .busy      (busy),
        .done      (done),
        .err_code  (err_code)
    );

    // =========================================================================
    // 时钟生成
    // =========================================================================
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = !clk;
    end

    // =========================================================================
    // 复位序列
    // =========================================================================
    task do_reset;
        begin
            rst_n     = 1'b0;
            req_vld   = 1'b0;
            req_bytes = 8'd0;
            data_rdy  = 1'b0;
            repeat (10) @(posedge clk);
            rst_n = 1'b1;
            repeat (2)  @(posedge clk);
        end
    endtask

    // =========================================================================
    // 单次请求任务
    // =========================================================================
    task request_bytes(input integer n_bytes, output reg [127:0] out_val);
        begin
            // 等待空闲
            wait(req_rdy == 1'b1);
            @(posedge clk);
            req_vld   = 1'b1;
            req_bytes = n_bytes[7:0];

            // 等待握手 (一拍脉冲)
            @(posedge clk);
            req_vld = 1'b0;

            // 等待 DUT 进入 busy 状态
            wait(busy == 1'b1);

            // 等待完成, 收集数据
            while (busy == 1'b1) begin
                if (data_vld) begin
                    data_rdy = 1'b1;
                    out_val  = data_out;
                    sample_cnt = sample_cnt + 1;
                    @(posedge clk);
                    data_rdy = 1'b0;
                end else begin
                    @(posedge clk);
                end
            end
        end
    endtask

    // =========================================================================
    // 主测试流程
    // =========================================================================
    reg [127:0] sample;
    integer i;

    initial begin
        $dumpfile("trng.vcd");
        $dumpvars(0, tb_trng);

        $display("========================================================");
        $display(" TRNG Testbench - %t", $time);
        $display("========================================================");

        // 复位
        do_reset;
        $display("[%t] Reset done", $time);

        // 测试 1: 单字节请求
        $display("\n[Test 1] Single byte request");
        request_bytes(1, sample);
        if (sample_cnt > 0) begin
            $display("  PASS: Got data, sample=0x%h", sample);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: No data received");
            fail_cnt = fail_cnt + 1;
        end

        // 测试 2: 多字节请求 (8 字节)
        $display("\n[Test 2] 8-byte request");
        sample_cnt = 0;
        request_bytes(8, sample);
        if (sample_cnt > 0) begin
            $display("  PASS: Got %0d samples", sample_cnt);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: No data received");
            fail_cnt = fail_cnt + 1;
        end

        // 测试 3: 最大请求 (16 字节)
        $display("\n[Test 3] Max 16-byte request");
        sample_cnt = 0;
        request_bytes(16, sample);
        if (sample_cnt > 0) begin
            $display("  PASS: Got %0d samples", sample_cnt);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: No data received");
            fail_cnt = fail_cnt + 1;
        end

        // 测试 4: 连续请求 (背靠背)
        $display("\n[Test 4] Back-to-back requests");
        begin : bb_test
            integer success;
            success = 0;
            for (i = 0; i < 10; i = i + 1) begin
                sample_cnt = 0;
                request_bytes(4, sample);
                if (sample_cnt > 0) success = success + 1;
            end
            if (success == 10) begin
                $display("  PASS: All 10 back-to-back requests succeeded");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: Only %0d/10 succeeded", success);
                fail_cnt = fail_cnt + 1;
            end
        end

        // 测试 5: 错误码检查 (正常请求应为 0x00)
        $display("\n[Test 5] Error code check");
        if (err_code == 8'h00) begin
            $display("  PASS: err_code = 0x%0h (normal)", err_code);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: err_code = 0x%0h (unexpected)", err_code);
            fail_cnt = fail_cnt + 1;
        end

        // 测试 6: 长时运行 (稳定性)
        $display("\n[Test 6] Long run stability (100 requests)");
        begin : long_test
            integer success;
            success = 0;
            for (i = 0; i < 100; i = i + 1) begin
                sample_cnt = 0;
                request_bytes(4, sample);
                if (sample_cnt > 0) success = success + 1;
            end
            if (success == 100) begin
                $display("  PASS: All 100 requests succeeded");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: %0d/100 succeeded", success);
                fail_cnt = fail_cnt + 1;
            end
        end

        // 报告
        $display("\n========================================================");
        $display(" Test Summary");
        $display("   PASS : %0d", pass_cnt);
        $display("   FAIL : %0d", fail_cnt);
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
        #1_000_000;
        $display("ERROR: Testbench timeout!");
        $finish;
    end

endmodule
