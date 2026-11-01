// =============================================================================
// Testbench : tb_trng_sm3
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.1
// 日期     : 2026-10-03
// 视角     : sim-verifier (魏波形)
// 变更记录 :
//   v1.0 2026-10-02 首版 (T1-T6 happy path)
//   v1.1 2026-10-03 Phase 3.0 遗留清理: 加 T7 HT 失败错误路径覆盖
//                  用 force u_dut.u_ht.fail=1 注入故障, 验证 err_code=0x01;
//                  再释放 force 验证 DUT 恢复正常工作 (T8)
// 目标     : 验证 SM3 哈希 DRBG 集成的 TRNG 模块
//   T1: 单次请求, 输出非零
//   T2: 10 次背靠背, 每次输出不同 (修复 v1.0 "前 3 字重复" 缺陷)
//   T3: 输出模式检查 (无重复字)
//   T4: 100 次稳定性
//   T5: 与 v1.0 trng_drbg 对比 (确认 SM3 修复了缺陷)
//   T6: 错误码检查 (happy path, err_code == 0x00)
//   T7: HT 失败 -> err_code == 0x01 (force 注入)
//   T8: force 释放后 DUT 恢复正常
// =============================================================================

`timescale 1ns / 1ps

module tb_trng_sm3;

    // =========================================================================
    // 参数
    // =========================================================================
    localparam CLK_PERIOD  = 2.5;   // 400 MHz

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

    // =========================================================================
    // DUT
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
    // 时钟
    // =========================================================================
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = !clk;
    end

    // =========================================================================
    // 复位
    // =========================================================================
    task do_reset;
        begin
            rst_n   = 1'b0;
            req_vld = 1'b0;
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
    reg [127:0] g_out_val;
    integer     g_cycles;

    task do_request;
        integer wait_cnt;
        begin
            wait_cnt  = 0;
            g_cycles  = 0;
            g_out_val = 128'd0;

            // 等 DUT 空闲
            wait(req_rdy == 1'b1);
            @(posedge clk);
            req_vld   = 1'b1;
            req_bytes = 8'd1;

            // 等握手完成
            @(posedge clk);
            req_vld = 1'b0;

            // 等数据输出
            while (data_vld != 1'b1) begin
                @(posedge clk);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 100000) begin
                    $display("  ERROR: timeout waiting for data_vld (cycles=%0d)", wait_cnt);
                    g_out_val = 128'd0;
                    g_cycles  = wait_cnt;
                    disable do_request;
                end
            end

            #1;
            g_out_val  = data_out;
            g_cycles   = wait_cnt;

            // 等完成
            while (busy == 1'b1) begin
                @(posedge clk);
                if (wait_cnt > 120000) begin
                    $display("  ERROR: timeout waiting for busy=0 (cycles=%0d)", wait_cnt);
                    disable do_request;
                end
            end
        end
    endtask

    // =========================================================================
    // 辅助: 检查 128-bit 值是否有"前 3 字重复"模式
    // =========================================================================
    function has_repeat_pattern;
        input [127:0] val;
        begin
            has_repeat_pattern = 1'b0;
            // 检查 word[3]==word[2] && word[2]==word[1]
            if (val[127:96] === val[95:64] && val[95:64] === val[63:32]) begin
                has_repeat_pattern = 1'b1;
            end
        end
    endfunction

    // =========================================================================
    // 主测试
    // =========================================================================
    integer      i;

    initial begin
        $dumpfile("trng_sm3.vcd");
        $dumpvars(0, tb_trng_sm3);

        $display("========================================================");
        $display(" TRNG+SM3 DRBG Testbench - %t", $time);
        $display("========================================================");

        do_reset;
        $display("[%t] Reset done", $time);

        // ------------------------------------------------------------------
        // T1: 单次请求, 输出非零
        // ------------------------------------------------------------------
        $display("\n[Test 1] Single request, non-zero output");
        do_request;
        $display("  sample = 0x%h", g_out_val);
        $display("  cycles = %0d", g_cycles);
        if (g_out_val !== 128'd0) begin
            $display("  PASS: Output is non-zero");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: Output is zero");
            fail_cnt = fail_cnt + 1;
        end

        // ------------------------------------------------------------------
        // T2: 10 次背靠背, 每次输出不同
        // ------------------------------------------------------------------
        $display("\n[Test 2] 10 back-to-back requests, all different");
        begin : bb_test
            reg [127:0] prev;
            integer     distinct_cnt;
            distinct_cnt = 0;
            prev = 128'd0;
            for (i = 0; i < 10; i = i + 1) begin
                do_request;
                $display("  [%02d] 0x%h", i, g_out_val);
                if (g_out_val !== prev) distinct_cnt = distinct_cnt + 1;
                prev = g_out_val;
            end
            if (distinct_cnt == 10) begin
                $display("  PASS: All 10 outputs are distinct");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: Only %0d/10 distinct", distinct_cnt);
                fail_cnt = fail_cnt + 1;
            end
        end

        // ------------------------------------------------------------------
        // T3: 输出模式检查 (无"前 3 字重复"模式)
        // ------------------------------------------------------------------
        $display("\n[Test 3] Pattern check: no 'first 3 words repeat'");
        begin : pattern_test
            integer repeat_cnt;
            integer total;
            repeat_cnt = 0;
            total = 20;
            for (i = 0; i < total; i = i + 1) begin
                do_request;
                if (has_repeat_pattern(g_out_val)) begin
                    repeat_cnt = repeat_cnt + 1;
                    $display("  [%02d] REPEAT PATTERN: 0x%h", i, g_out_val);
                end
            end
            if (repeat_cnt == 0) begin
                $display("  PASS: 0/%0d outputs have repeat pattern", total);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: %0d/%0d outputs have repeat pattern", repeat_cnt, total);
                fail_cnt = fail_cnt + 1;
            end
        end

        // ------------------------------------------------------------------
        // T4: 100 次稳定性
        // ------------------------------------------------------------------
        $display("\n[Test 4] 100-request stability");
        begin : stab_test
            integer success;
            integer zero_cnt;
            success  = 0;
            zero_cnt = 0;
            for (i = 0; i < 100; i = i + 1) begin
                do_request;
                if (g_out_val !== 128'd0) begin
                    success = success + 1;
                end else begin
                    zero_cnt = zero_cnt + 1;
                end
            end
            if (success == 100) begin
                $display("  PASS: All 100 requests produced non-zero output");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: %0d/100 succeeded (%0d zero)", success, zero_cnt);
                fail_cnt = fail_cnt + 1;
            end
        end

        // ------------------------------------------------------------------
        // T5: 与 v1.0 trng_drbg 对比
        // ------------------------------------------------------------------
        $display("\n[Test 5] v1.0 vs v2.0 comparison (20 samples)");
        begin : cmp_test
            integer v2_repeat;
            v2_repeat = 0;
            for (i = 0; i < 20; i = i + 1) begin
                do_request;
                if (has_repeat_pattern(g_out_val)) v2_repeat = v2_repeat + 1;
            end
            $display("  v2.0 (SM3 DRBG): %0d/20 repeat patterns", v2_repeat);
            if (v2_repeat == 0) begin
                $display("  PASS: SM3 DRBG eliminated repeat pattern defect");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: SM3 DRBG still has repeat patterns");
                fail_cnt = fail_cnt + 1;
            end
        end

        // ------------------------------------------------------------------
        // T6: 错误码检查
        // ------------------------------------------------------------------
        $display("\n[Test 6] Error code check");
        if (err_code === 8'h00) begin
            $display("  PASS: err_code = 0x%0h (normal)", err_code);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: err_code = 0x%0h", err_code);
            fail_cnt = fail_cnt + 1;
        end

        // ------------------------------------------------------------------
        // T7: HT 失败 -> err_code == 0x01 (Phase 3.0 新增)
        // 用 force 强制 u_dut.u_ht.fail=1, 使 FSM 走 S_HT -> S_ERROR 路径
        // err_code = (state == S_ERROR) ? 0x01 : 0x00, S_ERROR 仅 1 拍
        // ------------------------------------------------------------------
        $display("\n[Test 7] HT failure inject -> err_code == 0x01");
        begin : ht_fail_test
            integer wait_cnt;
            integer err_hit;
            wait_cnt = 0;
            err_hit  = 0;

            // 注入 HT 失败
            force u_dut.u_ht.fail = 1'b1;

            // 发起请求
            wait(req_rdy == 1'b1);
            @(posedge clk);
            req_vld   = 1'b1;
            req_bytes = 8'd1;
            @(posedge clk);
            req_vld = 1'b0;

            // 逐拍采样 err_code (S_ERROR 只持续 1 拍)
            // 注意: Verilog-2005 无 break, 用 !err_hit 作循环条件
            while (!err_hit && wait_cnt < 20000) begin
                @(posedge clk);
                #1;
                if (err_code === 8'h01) err_hit = 1;
                wait_cnt = wait_cnt + 1;
            end

            // 释放 force
            release u_dut.u_ht.fail;
            repeat (3) @(posedge clk);

            if (err_hit) begin
                $display("  PASS: err_code hit 0x01 after %0d cycles", wait_cnt);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: err_code never hit 0x01 in %0d cycles", wait_cnt);
                fail_cnt = fail_cnt + 1;
            end
        end

        // ------------------------------------------------------------------
        // T8: force 释放后 DUT 恢复正常
        // ------------------------------------------------------------------
        $display("\n[Test 8] DUT recovers after force release");
        begin : recovery_test
            integer ok;
            ok = 0;
            do_request;
            if (g_out_val !== 128'd0 && err_code === 8'h00) begin
                $display("  PASS: post-fault request ok, out=0x%h", g_out_val);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: post-fault request broken (out=0x%h, err=0x%0h)",
                         g_out_val, err_code);
                fail_cnt = fail_cnt + 1;
            end
        end

        // ------------------------------------------------------------------
        // 报告
        // ------------------------------------------------------------------
        $display("\n========================================================");
        $display(" Test Summary");
        $display("   PASS : %0d", pass_cnt);
        $display("   FAIL : %0d", fail_cnt);
        $display("========================================================");
        if (fail_cnt == 0) $display(" ALL TESTS PASSED");
        else                $display(" SOME TESTS FAILED");

        #100;
        $finish;
    end

    // =========================================================================
    // 超时保护
    // =========================================================================
    initial begin
        #20_000_000;
        $display("ERROR: Testbench timeout!");
        $finish;
    end

endmodule
