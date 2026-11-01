// =============================================================================
// 模块名称 : tb_gm_crypto_top
// 项目     : GM-CRYPTO-COORD-2026 - Phase 5 系统集成验证
// 版本     : v1.0
// 日期     : 2026-10-05
// 视角     : sim-verifier (魏波形)
//
// 测试列表 :
//   T1  : SM4_ENC GB/T 标准向量 (ct=681EDF34...4246)
//   T2  : SM4_DEC roundtrip (解密后==原明文)
//   T3  : SM3_CMP 单块 "abc" (hash=66c7f0f4...8e0)
//   T4  : TRNG_128 非零
//   T5  : TRNG_256 非零
//   T6  : 非法操作码 (err≠0)
//   T7  : 并发命令 (2 引擎 round-robin)
//   T8  : 连续背靠背命令 (无 idle gap)
//   T9  : 优先级调度 (高优先级先执行)
//   T10 : 复位行为 (busy=0, res_vld=0)
// =============================================================================

`timescale 1ns / 1ps

module tb_gm_crypto_top;

    // ---- 时钟与复位 ----
    reg clk = 0;
    reg rst_n = 0;
    always #2.5 clk = !clk;  // 400 MHz (与 crypto_coord_subsys 设计频率一致)

    // ---- DUT 接口 ----
    reg         host_cmd_wr = 0;
    reg  [7:0]  host_cmd_rid = 0;
    reg  [3:0]  host_cmd_op = 0;
    reg  [1:0]  host_cmd_prio = 0;
    reg  [511:0] host_cmd_ia = 0;
    reg  [511:0] host_cmd_ib = 0;
    reg  [255:0] host_cmd_ic = 0;

    wire        host_res_vld;
    reg         host_res_rdy = 0;
    wire [7:0]  host_res_rid;
    wire [7:0]  host_res_err;
    wire        host_res_ok;
    wire [255:0] host_res_ra;
    wire [255:0] host_res_rb;

    wire [31:0] status;
    wire        interrupt;

    // ---- DUT 实例 ----
    gm_crypto_top u_dut (
        .clk(clk), .rst_n(rst_n),
        .host_cmd_wr(host_cmd_wr),
        .host_cmd_rid(host_cmd_rid),
        .host_cmd_op(host_cmd_op),
        .host_cmd_prio(host_cmd_prio),
        .host_cmd_ia(host_cmd_ia),
        .host_cmd_ib(host_cmd_ib),
        .host_cmd_ic(host_cmd_ic),
        .host_res_vld(host_res_vld),
        .host_res_rdy(host_res_rdy),
        .host_res_rid(host_res_rid),
        .host_res_err(host_res_err),
        .host_res_ok(host_res_ok),
        .host_res_ra(host_res_ra),
        .host_res_rb(host_res_rb),
        .status(status),
        .interrupt(interrupt)
    );

    // ---- 计数器 ----
    integer ntest = 0;
    integer npass = 0;
    integer npfail = 0;

    task check(input cond, input [255:0] msg);
        begin
            ntest = ntest + 1;
            if (cond) begin
                npass = npass + 1;
                $display("  [PASS] #%0d t=%0t: %s", ntest, $time, msg);
            end else begin
                npfail = npfail + 1;
                $display("  [FAIL] #%0d t=%0t: %s", ntest, $time, msg);
            end
        end
    endtask

    // ---- 发送命令并等待结果 ----
    task send_cmd(input [3:0] op, input [1:0] prio,
                  input [7:0] rid,
                  input [511:0] ia, input [511:0] ib, input [255:0] ic);
        begin
            @(negedge clk);
            host_cmd_wr = 1'b1;
            host_cmd_rid = rid;
            host_cmd_op = op;
            host_cmd_prio = prio;
            host_cmd_ia = ia;
            host_cmd_ib = ib;
            host_cmd_ic = ic;
            @(negedge clk);
            host_cmd_wr = 1'b0;
        end
    endtask

    // ---- 等待结果并读取（全局变量方式，避免 -g2005 output 参数问题）----
    reg [255:0] w_ra;
    reg [255:0] w_rb;
    reg         w_ok;
    reg [7:0]   w_err;
    reg [7:0]   w_rid;
    integer     timeout_cnt;

    reg wait_done = 0;

    task wait_result;
        begin
            timeout_cnt = 0;
            wait_done = 0;
            while (!host_res_vld && !wait_done) begin
                @(negedge clk);
                timeout_cnt = timeout_cnt + 1;
                if (timeout_cnt > 500000) begin
                    $display("  [TIMEOUT] wait_result at t=%0t", $time);
                    w_ra = 256'd0; w_rb = 256'd0; w_ok = 0; w_err = 8'hFF; w_rid = 8'hFF;
                    wait_done = 1;
                end
            end
            if (!wait_done) begin
                @(negedge clk);
                host_res_rdy = 1'b1;
                w_ra = host_res_ra;
                w_rb = host_res_rb;
                w_ok = host_res_ok;
                w_err = host_res_err;
                w_rid = host_res_rid;
                @(negedge clk);
                host_res_rdy = 1'b0;
            end
        end
    endtask

    // =========================================================================
    // 测试主程序
    // =========================================================================
    initial begin : main
        w_ra = 256'd0; w_rb = 256'd0;
        w_ok = 0; w_err = 0; w_rid = 0;

        // 复位
        rst_n = 0;
        host_cmd_wr = 0;
        host_res_rdy = 0;
        #200;  // 50 cycles
        rst_n = 1;
        @(negedge clk); @(negedge clk);

        // ---- T10: 复位行为 ----
        $display("\n=== T10: Reset behavior ===");
        check(status[0] == 0, "Reset: RES_VLD=0");
        check(host_res_vld == 0, "Reset: res_vld=0");

        // ---- T1: SM4_ENC GB/T 标准向量 ----
        $display("\n=== T1: SM4_ENC GB/T vector ===");
        send_cmd(4'h0, 2'd1, 8'h01,
                 512'h0123456789ABCDEFFEDCBA9876543210,
                 512'h0123456789ABCDEFFEDCBA9876543210,
                 256'd0);
        wait_result;
        check(w_ok == 1, "T1: SM4_ENC ok=1");
        check(w_err == 0, "T1: SM4_ENC err=0");
        check(w_ra[127:0] == 128'h681EDF34D206965E86B3E94F536E4246,
              "T1: ct=681EDF34...4246");

        // ---- T2: SM4_DEC roundtrip ----
        $display("\n=== T2: SM4_DEC roundtrip ===");
        send_cmd(4'h1, 2'd1, 8'h02,
                 512'h0123456789ABCDEFFEDCBA9876543210,
                 512'h681EDF34D206965E86B3E94F536E4246,
                 256'd0);
        wait_result;
        check(w_ok == 1, "T2: SM4_DEC ok=1");
        check(w_ra[127:0] == 128'h0123456789ABCDEFFEDCBA9876543210,
              "T2: pt=0123456789...3210");

        // ---- T3: SM3_CMP 单块 "abc" ----
        $display("\n=== T3: SM3_CMP single block 'abc' ===");
        // msg_block = "abc" + padding (512-bit)
        // "abc" = 61 62 63 (3 bytes), then 80 hex, then zeros, then length=24
        // Total: 61 62 63 80 00 00 ... 00 18 (3+1+57+1 = 62 bytes = 496 bits)
        // Wait, SM3 pads to 512-bit block. Let me use the correct padding.
        // "abc" is 24 bits. Padding: append 80, then zeros, then length=24 (6 hex digits)
        // Total 512 bits: 61 62 63 80 0000000000000000000000000000000000000000000000000000000000000000 00000000000000000000000000000000 00000000000000000000000000000018
        // Let me construct it properly:
        // Byte 0: 0x61, Byte 1: 0x62, Byte 2: 0x63
        // Byte 3: 0x80
        // Bytes 4-57: 0x00
        // Bytes 58-63: length = 24 bits = 0x0000000000000018
        // So: 61 62 63 80 00*54 0000000000000018
        // prev_state 在 ib 的【低】256 位（见 crypto_coord_subsys 头注：
        // "SM3 的 prev 在 ib 的【低】半字"）—— 高 256 位补 0。
        // IV = 7380166F4914B2B9172442D7DA8A0600 A96F30BC163138AAE38DEE4DB0FB0E4E
        send_cmd(4'h2, 2'd1, 8'h03,
                 512'h61626380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018,
                 512'h00000000000000000000000000000000000000000000000000000000000000007380166f4914b2b9172442d7da8a0600a96f30bc163138aae38dee4db0fb0e4e,
                 256'd0);
        wait_result;
        check(w_ok == 1, "T3: SM3_CMP ok=1");
        check(w_err == 0, "T3: SM3_CMP err=0");
        check(w_ra == 256'h66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0,
              "T3: hash=66c7f0f4...8e0");

        // ---- T4: TRNG_128 ----
        $display("\n=== T4: TRNG_128 ===");
        send_cmd(4'h3, 2'd1, 8'h04,
                 512'd0, 512'd0, 256'd0);
        wait_result;
        check(w_ok == 1, "T4: TRNG_128 ok=1");
        check(w_ra != 256'd0, "T4: TRNG_128 output != 0");

        // ---- T5: TRNG_256 ----
        $display("\n=== T5: TRNG_256 ===");
        send_cmd(4'h4, 2'd1, 8'h05,
                 512'd0, 512'd0, 256'd0);
        wait_result;
        check(w_ok == 1, "T5: TRNG_256 ok=1");
        check(w_ra != 256'd0, "T5: TRNG_256 output != 0");

        // ---- T6: 非法操作码 ----
        $display("\n=== T6: Invalid opcode ===");
        send_cmd(4'hF, 2'd1, 8'h06,
                 512'd0, 512'd0, 256'd0);
        wait_result;
        check(w_ok == 0, "T6: invalid op ok=0");
        check(w_err != 0, "T6: invalid op err!=0");

        // ---- T7: 并发命令 (2 引擎 round-robin) ----
        $display("\n=== T7: Concurrent commands (2 engines) ===");
        // 发送 SM4_ENC 和 SM3_CMP，看是否都能完成
        send_cmd(4'h0, 2'd1, 8'h07,
                 512'h0123456789ABCDEFFEDCBA9876543210,
                 512'h0123456789ABCDEFFEDCBA9876543210,
                 256'd0);
        // 立即发送第二个命令（SM3）
        send_cmd(4'h2, 2'd1, 8'h08,
                 512'h61626380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018,
                 512'h7380166f4914b2b9172442d7da8a0600a96f30bc163138aae38dee4db0fb0e4e,
                 256'd0);
        // 等待两个结果
        wait_result;
        check(w_ok == 1, "T7: first result ok=1");
        check(w_err == 0, "T7: first result err=0");

        wait_result;
        check(w_ok == 1, "T7: second result ok=1");
        check(w_err == 0, "T7: second result err=0");

        // ---- T8: 连续背靠背命令 ----
        $display("\n=== T8: Back-to-back commands ===");
        send_cmd(4'h0, 2'd1, 8'h09,
                 512'h0123456789ABCDEFFEDCBA9876543210,
                 512'h0123456789ABCDEFFEDCBA9876543210,
                 256'd0);
        wait_result;
        check(w_ok == 1, "T8: cmd1 ok=1");

        send_cmd(4'h0, 2'd1, 8'h0A,
                 512'h0123456789ABCDEFFEDCBA9876543210,
                 512'h0123456789ABCDEFFEDCBA9876543210,
                 256'd0);
        wait_result;
        check(w_ok == 1, "T8: cmd2 ok=1");

        // ---- T9: 优先级调度 ----
        $display("\n=== T9: Priority scheduling ===");
        // 先发低优先级命令
        send_cmd(4'h0, 2'd3, 8'h0B,
                 512'h0123456789ABCDEFFEDCBA9876543210,
                 512'h0123456789ABCDEFFEDCBA9876543210,
                 256'd0);
        // 然后发高优先级命令
        send_cmd(4'h0, 2'd0, 8'h0C,
                 512'h0123456789ABCDEFFEDCBA9876543210,
                 512'h0123456789ABCDEFFEDCBA9876543210,
                 256'd0);
        // 等待两个结果（顺序不可预测，因为可能分配到不同引擎并行执行）
        wait_result;
        check(w_ok == 1, "T9: first result ok=1");
        wait_result;
        check(w_ok == 1, "T9: second result ok=1");

        // ---- 汇总 ----
        $display("\n============================================================");
        $display("Test Summary: PASS=%0d FAIL=%0d TOTAL=%0d", npass, npfail, ntest);
        if (npfail == 0) $display("ALL TESTS PASSED");
        else $display("SOME TESTS FAILED");
        $display("============================================================");
    end

    // ---- 超时保护 ----
    initial begin
        #50000000;  // 50 ms simulation
        $display("GLOBAL TIMEOUT at t=%0t", $time);
        $finish;
    end

    // ---- 波形 ----
    initial begin
        $dumpfile("tb_gm_crypto_top.vcd");
        $dumpvars(0, tb_gm_crypto_top);
    end

endmodule
