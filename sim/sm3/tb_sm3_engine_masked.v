// =============================================================================
// Testbench : tb_sm3_engine_masked
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-05
// 目标     : 验证 sm3_engine_masked v3.1 (C2-2 W 存储掩码 MVP)
//
// 测试项:
//   T1: wrapper_masked_en=0, GB/T "abc" 向量 (零回归基线)
//   T2: wrapper_masked_en=1, 同向量 → 同 hash (掩码不改变结果)
//   T3: wrapper_masked_en=1, w_probe != msg_block[511:480] (掩码生效)
//   T4: wrapper_masked_en=1, 多次不同 mask_seed → w_probe 变化 (随机化)
// =============================================================================

`timescale 1ns / 1ps

module tb_sm3_engine_masked;

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

    wire [255:0] out_state_a, out_state_b;
    wire         done_a, done_b;
    wire         busy_a, busy_b;

    // =========================================================================
    // IV (GB/T 32905-2016 4.2)
    // =========================================================================
    localparam [255:0] IV = 256'h7380166f4914b2b9172442d7da8a0600a96f30bc163138aae38dee4db0fb0e4e;

    // "abc" 测试向量
    localparam [511:0] MSG_ABC = 512'h61626380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018;
    localparam [255:0] HASH_ABC = 256'h66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0;

    // =========================================================================
    // 两个 DUT 实例: 一个掩码关闭 (baseline), 一个掩码开启
    // =========================================================================
    reg [31:0] seed_a;
    reg [31:0] seed_b;
    wire [31:0] w_probe_a;
    wire [31:0] w_probe_b;

    sm3_engine_masked #(
        .wrapper_masked_en(1'b0)
    ) dut_a (
        .clk(clk), .rst_n(rst_n), .start(start),
        .msg_block(msg_block), .prev_state(prev_state),
        .out_state(out_state_a), .done(done_a), .busy(busy_a),
        .mask_seed(seed_a), .w_stored_probe(w_probe_a)
    );

    sm3_engine_masked #(
        .wrapper_masked_en(1'b1)
    ) dut_b (
        .clk(clk), .rst_n(rst_n), .start(start),
        .msg_block(msg_block), .prev_state(prev_state),
        .out_state(out_state_b), .done(done_b), .busy(busy_b),
        .mask_seed(seed_b), .w_stored_probe(w_probe_b)
    );

    // =========================================================================
    // 统计
    // =========================================================================
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // T4 局部变量 (module level, Verilog-2005 限制)
    integer seed_i;
    integer vary_cnt;
    integer hash_fail;
    reg [31:0] prev_probe;
    reg [31:0] cur_probe;
    reg [255:0] tmp_hash;

    // T2/T3 用的 w_probe 捕获 (task output 需要 reg l-value)
    reg [31:0] probe_b_reg;

    // =========================================================================
    // 主测试流程
    // =========================================================================
    reg [255:0] hash_a;
    reg [255:0] hash_b;

    // task: 在 dut_a 上跑 hash (掩码关闭)
    task run_hash_off(input [511:0] msg, output [255:0] hash);
        begin
            wait(!busy_a);
            @(posedge clk);
            seed_a     = 32'h00000000;
            msg_block  = msg;
            prev_state = IV;
            start      = 1'b1;
            @(posedge clk);
            start      = 1'b0;

            wait(done_a == 1'b1);
            @(posedge clk);
            hash = out_state_a;
            wait(!busy_a);
        end
    endtask

    // task: 在 dut_b 上跑 hash (掩码开启)
    task run_hash_on(input [511:0] msg, input [31:0] seed, output [255:0] hash, output [31:0] wprobe);
        begin
            wait(!busy_b);
            @(posedge clk);
            seed_b     = seed;
            msg_block  = msg;
            prev_state = IV;
            start      = 1'b1;
            @(posedge clk);
            start      = 1'b0;

            wait(done_b == 1'b1);
            @(posedge clk);
            hash = out_state_b;
            wprobe = w_probe_b;
            wait(!busy_b);
        end
    endtask

    initial begin
        $dumpfile("sm3_masked.vcd");
        $dumpvars(0, tb_sm3_engine_masked);

        $display("========================================================");
        $display(" SM3 Engine Masked Testbench (v3.1)");
        $display(" C2-2 MVP: W 存储掩码 (实用级一阶保护)");
        $display("========================================================");

        // 复位
        rst_n      = 1'b0;
        start      = 1'b0;
        msg_block  = 512'd0;
        prev_state = 256'd0;
        seed_a     = 32'h00000000;
        seed_b     = 32'hDEADBEEF;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (2)  @(posedge clk);

        // ================================================================
        // T1: 掩码关闭, "abc" 向量 (零回归基线)
        // ================================================================
        $display("\n[T1] wrapper_masked_en=0, 'abc' vector (zero-regression baseline)");
        run_hash_off(MSG_ABC, hash_a);
        $display("  Got:  0x%h", hash_a);
        $display("  Exp:  0x%h", HASH_ABC);
        if (hash_a == HASH_ABC) begin
            $display("  PASS");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL");
            fail_cnt = fail_cnt + 1;
        end

        // ================================================================
        // T2: 掩码开启, 同 "abc" → 同 hash
        // ================================================================
        $display("\n[T2] wrapper_masked_en=1, same 'abc' → same hash");
        run_hash_on(MSG_ABC, 32'hDEADBEEF, hash_b, probe_b_reg);
        $display("  Got:  0x%h", hash_b);
        $display("  Exp:  0x%h", HASH_ABC);
        if (hash_b == HASH_ABC) begin
            $display("  PASS (hash 不受掩码影响)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL (hash 应不受掩码影响)");
            fail_cnt = fail_cnt + 1;
        end

        // ================================================================
        // T3: 掩码开启, w_probe != msg_block[511:480] (掩码生效)
        // ================================================================
        $display("\n[T3] wrapper_masked_en=1, W_stored != W_true (masking effective)");
        // MSG_ABC[511:480] = 0x61626380
        $display("  msg_block[511:480] = 0x61626380");
        $display("  w_probe_b         = 0x%h", probe_b_reg);
        if (probe_b_reg != 32'h61626380) begin
            $display("  PASS (W_stored 已随机化, != W_true)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL (W_stored == W_true, 掩码未生效)");
            fail_cnt = fail_cnt + 1;
        end

        // ================================================================
        // T4: 掩码开启, 多次不同 mask_seed → w_probe 变化
        // ================================================================
        $display("\n[T4] wrapper_masked_en=1, varying mask_seed → varying w_probe");
        begin
            vary_cnt = 0;
            hash_fail = 0;
            prev_probe = probe_b_reg;
            for (seed_i = 1; seed_i <= 8; seed_i = seed_i + 1) begin
                run_hash_on(MSG_ABC, seed_i * 32'hDEADBEEF, tmp_hash, cur_probe);
                $display("  seed=0x%08h  w_probe=0x%08h  hash_match=%b",
                         seed_i * 32'hDEADBEEF, cur_probe,
                         (tmp_hash == HASH_ABC));
                if (cur_probe != prev_probe) begin
                    vary_cnt = vary_cnt + 1;
                end
                if (tmp_hash != HASH_ABC) hash_fail = hash_fail + 1;
                prev_probe = cur_probe;
            end
            $display("  unique w_probe transitions: %0d/7 (期望 7)", vary_cnt);
            $display("  hash mismatches           : %0d/8 (期望 0)", hash_fail);
            if (vary_cnt >= 6 && hash_fail == 0) begin
                $display("  PASS (w_probe 随机化 + hash 不变)");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL (w_probe 变化不足或 hash 被掩码影响)");
                fail_cnt = fail_cnt + 1;
            end
        end

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
        #50_000_000;
        $display("ERROR: Testbench timeout!");
        $finish;
    end

endmodule
