// =============================================================================
// 模块名称 : tb_sm4_engine_sys
// 项目     : GM-CRYPTO-COORD-2026 - Phase 2 验证 (sm4_engine_sys v1.0)
// 视角     : sim-verifier
// 目标     :
//   1) GB/T 32907-2016 官方向量: key=pt=0123456789ABCDEFFEDCBA9876543210
//      -> ct=681EDF34D206965E86B3E94F536E4246
//   2) 解密往返: ct -> pt
//   3) 100 组背靠背吞吐 (首块延迟 + 稳态吞吐)
//   4) 覆盖 do_decrypt 分支
// =============================================================================

`timescale 1ns / 1ps

module tb_sm4_engine_sys;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         start = 1'b0;
    reg  [127:0] key = 128'd0;
    reg  [127:0] plaintext = 128'd0;
    reg         decrypt = 1'b0;
    reg  [127:0] ciphertext = 128'd0;

    wire [127:0] result;
    wire         done;
    wire         busy;

    // 时钟: 10ns 周期 (100 MHz, 与 Phase 3 约束一致)
    always #5 clk = ~clk;

    sm4_engine_sys dut (
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

    // 任务: 发起一次加/解密并等 done
    integer cycles;
    integer timeout_cnt;

    task do_sm4;
        input [127:0] k_in;
        input [127:0] data_in;
        input dec_in;
        begin
            @(negedge clk);
            key       = k_in;
            plaintext = data_in;
            ciphertext = data_in;  // 双向接口, 无所谓 (input_data 会选)
            decrypt   = dec_in;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            // 等 done
            timeout_cnt = 0;
            @(posedge clk);
            while (!done && timeout_cnt < 500) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (timeout_cnt >= 500) begin
                $display("FAIL: timeout after %0d cycles", timeout_cnt);
                $finish;
            end
        end
    endtask

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer total_cycles = 0;

    initial begin
        $dumpfile("tb_sm4_engine_sys.vcd");
        $dumpvars(0, tb_sm4_engine_sys);

        // 复位
        rst_n = 1'b0;
        #30;
        @(negedge clk);
        rst_n = 1'b1;
        #10;

        // =====================================================================
        // TEST 1: GB/T 32907-2016 官方向量 (加密)
        // =====================================================================
        $display("=== TEST 1: GB/T 32907-2016 official vector (encrypt) ===");
        cycles = $time;
        do_sm4(
            128'h0123456789ABCDEFFEDCBA9876543210,
            128'h0123456789ABCDEFFEDCBA9876543210,
            1'b0
        );
        total_cycles = total_cycles + ($time - cycles);
        if (result === 128'h681EDF34D206965E86B3E94F536E4246) begin
            $display("  PASS: ct = 681EDF34D206965E86B3E94F536E4246");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: expected 681EDF34D206965E86B3E94F536E4246");
            $display("        got      %h", result);
            fail_cnt = fail_cnt + 1;
        end

        // =====================================================================
        // TEST 2: GB/T 32907-2016 官方向量 (解密)
        // =====================================================================
        $display("=== TEST 2: GB/T 32907-2016 official vector (decrypt) ===");
        cycles = $time;
        do_sm4(
            128'h0123456789ABCDEFFEDCBA9876543210,
            128'h681EDF34D206965E86B3E94F536E4246,
            1'b1
        );
        total_cycles = total_cycles + ($time - cycles);
        if (result === 128'h0123456789ABCDEFFEDCBA9876543210) begin
            $display("  PASS: pt recovered = 0123456789ABCDEFFEDCBA9876543210");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: expected 0123456789ABCDEFFEDCBA9876543210");
            $display("        got      %h", result);
            fail_cnt = fail_cnt + 1;
        end

        // =====================================================================
        // TEST 3: 加密 -> 解密 往返 (随机向量)
        // =====================================================================
        $display("=== TEST 3: enc -> dec round-trip (5 random vectors) ===");
        begin : roundtrip
            integer i;
            reg [127:0] pt_rand;
            reg [127:0] ct_rand;
            reg [127:0] pt_back;
            for (i = 0; i < 5; i = i + 1) begin
                pt_rand = {$random, $random, $random, $random};
                cycles = $time;
                do_sm4(
                    128'hFEDCBA9876543210FEDCBA9876543210,
                    pt_rand, 1'b0
                );
                total_cycles = total_cycles + ($time - cycles);
                ct_rand = result;
                cycles = $time;
                do_sm4(
                    128'hFEDCBA9876543210FEDCBA9876543210,
                    ct_rand, 1'b1
                );
                total_cycles = total_cycles + ($time - cycles);
                pt_back = result;
                if (pt_back === pt_rand) begin
                    $display("  PASS: round-trip[%0d] pt=%h", i, pt_rand);
                    pass_cnt = pass_cnt + 1;
                end else begin
                    $display("  FAIL: round-trip[%0d] pt=%h got=%h", i, pt_rand, pt_back);
                    fail_cnt = fail_cnt + 1;
                end
            end
        end

        // =====================================================================
        // TEST 4: 背靠背吞吐 - 100 块连续 (测首块延迟 + 稳态吞吐)
        // =====================================================================
        $display("=== TEST 4: back-to-back throughput (100 blocks) ===");
        begin : b2b
            integer i;
            reg [127:0] pt_b2b;
            integer t_start, t_end;
            // 首块延迟测量
            @(negedge clk);
            key       = 128'h0123456789ABCDEFFEDCBA9876543210;
            plaintext = 128'h0123456789ABCDEFFEDCBA9876543210;
            ciphertext = 128'h0123456789ABCDEFFEDCBA9876543210;
            decrypt   = 1'b0;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            t_start = $time;
            timeout_cnt = 0;
            @(posedge clk);
            while (!done && timeout_cnt < 200) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            t_end = $time;
            $display("  first-block latency = %0d cycles (%0d ns)",
                     (t_end - t_start) / 10, (t_end - t_start));
            if (((t_end - t_start) / 10) <= 70) begin
                $display("  PASS: first-block latency <= 70 cycles");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: first-block latency too high");
                fail_cnt = fail_cnt + 1;
            end

            // 99 块连续背靠背
            t_start = $time;
            for (i = 1; i < 100; i = i + 1) begin
                // 在 done 的同一拍发起下一次
                @(posedge clk);
                @(negedge clk);
                start = 1'b1;
                pt_b2b = {i[31:0], i[31:0], i[31:0], i[31:0]};
                plaintext = pt_b2b;
                @(negedge clk);
                start = 1'b0;
                timeout_cnt = 0;
                @(posedge clk);
                while (!done && timeout_cnt < 200) begin
                    @(posedge clk);
                    timeout_cnt = timeout_cnt + 1;
                end
            end
            t_end = $time;
            $display("  99 back-to-back blocks: %0d cycles (%0d ns)",
                     (t_end - t_start) / 10, (t_end - t_start));
            if (((t_end - t_start) / 10) <= 6600) begin
                $display("  PASS: 99 b2b <= 6600 cycles");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: 99 b2b too slow: %0d cycles",
                         (t_end - t_start) / 10);
                fail_cnt = fail_cnt + 1;
            end
        end

        // =====================================================================
        // 汇总
        // =====================================================================
        $display("====================================================");
        $display("SM4_ENGINE_SYS REGRESSION SUMMARY");
        $display("  PASS: %0d", pass_cnt);
        $display("  FAIL: %0d", fail_cnt);
        $display("====================================================");
        if (fail_cnt == 0) begin
            $display("ALL PASS");
        end else begin
            $display("SOME FAILED");
        end
        $finish;
    end

    // 全局超时保护
    initial begin
        #2000000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
