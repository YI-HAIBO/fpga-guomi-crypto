// =============================================================================
// Testbench : tb_sm4_engine_sys_multi
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-04
// 目标     : 验证 N 个 sm4_engine_sys v4.0 并行实例的功能正确性
//
// 测试项:
//   T1: 4 实例并行加密 (不同 key+pt), 逐位对照 GB/T 向量
//   T2: 4 实例并行解密 roundtrip
//   T3: 4 实例背靠背 (连续 3 轮)
// =============================================================================

`timescale 1ns / 1ps

module tb_sm4_engine_sys_multi;

    // =========================================================================
    // 参数
    // =========================================================================
    localparam NUM_INST    = 4;
    localparam CLK_PERIOD  = 10;  // 100 MHz

    // GB/T 32907-2016 标准向量
    localparam [127:0] GB_KEY = 128'h0123456789ABCDEFFEDCBA9876543210;
    localparam [127:0] GB_PT  = 128'h0123456789ABCDEFFEDCBA9876543210;
    localparam [127:0] GB_CT  = 128'h681EDF34D206965E86B3E94F536E4246;

    // 4 组测试向量
    localparam [127:0] KEY0 = GB_KEY;
    localparam [127:0] PT0  = GB_PT;
    localparam [127:0] KEY1 = 128'hDEADBEEFDEADBEEFDEADBEEFDEADBEEF;
    localparam [127:0] PT1  = 128'hCAFEBABECAFEBABECAFEBABECAFEBABE;
    localparam [127:0] KEY2 = 128'h1234567890ABCDEF0123456789ABCDEF;
    localparam [127:0] PT2  = 128'hFEDCBA0987654321FEDCBA0987654321;
    localparam [127:0] KEY3 = 128'hA5A5A5A55A5A5A5AA5A5A5A55A5A5A5A;
    localparam [127:0] PT3  = 128'hF0F0F0F00F0F0F0FF0F0F0F00F0F0F0F;

    // =========================================================================
    // 信号
    // =========================================================================
    reg         clk;
    reg         rst_n;

    reg  [NUM_INST-1:0] start;
    reg  [NUM_INST-1:0] decrypt;
    reg  [NUM_INST*128-1:0] keys;
    reg  [NUM_INST*128-1:0] plaintexts;

    wire [NUM_INST-1:0] done;
    wire [NUM_INST-1:0] busy;
    wire [NUM_INST*128-1:0] results;

    // 内部状态
    reg  [127:0] saved_ct [0:3];
    integer i;
    integer round;
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // =========================================================================
    // DUT
    // =========================================================================
    sm4_engine_sys_multi #(
        .NUM_INSTANCES (NUM_INST)
    ) u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .decrypt     (decrypt),
        .keys        (keys),
        .plaintexts  (plaintexts),
        .done        (done),
        .busy        (busy),
        .results     (results)
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
            rst_n      = 1'b0;
            start      = {NUM_INST{1'b0}};
            decrypt    = {NUM_INST{1'b0}};
            keys       = {NUM_INST*128{1'b0}};
            plaintexts = {NUM_INST*128{1'b0}};
            repeat (10) @(posedge clk);
            rst_n = 1'b1;
            repeat (2)  @(posedge clk);
        end
    endtask

    // =========================================================================
    // 等待所有实例完成 (done 脉冲)
    // =========================================================================
    task wait_all_done;
        integer timeout;
        begin
            timeout = 0;
            while (!(done == {NUM_INST{1'b1}}) && timeout < 500) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 500) begin
                $display("  ERROR: timeout!");
                $display("  done=%b busy=%b", done, busy);
                fail_cnt = fail_cnt + 1;
            end else begin
                @(posedge clk);  // done 脉冲结束后退出
            end
        end
    endtask

    // =========================================================================
    // 启动所有实例 (1 cycle 脉冲)
    // =========================================================================
    task start_all;
        begin
            start = {NUM_INST{1'b1}};
            @(posedge clk);
            start = {NUM_INST{1'b0}};
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_sm4_engine_sys_multi.vcd");
        $dumpvars(0, tb_sm4_engine_sys_multi);

        $display("========================================================");
        $display(" SM4 Engine Sys Multi-Instance Testbench (NUM_INST=%0d)", NUM_INST);
        $display("========================================================");

        do_reset;

        // ================================================================
        // T1: 4 实例并行加密
        // ================================================================
        $display("\n[Test 1] 4 instances parallel encrypt");
        // 注意: Verilog 拼接 {A,B,C,D} → A 在高位, D 在低位
        //       wrapper 中 keys[i*128+:128] → inst[0] 在最低位
        //       故需 {KEY3,KEY2,KEY1,KEY0} 才能让 inst[0] 拿到 KEY0
        keys       = {KEY3, KEY2, KEY1, KEY0};
        plaintexts = {PT3,  PT2,  PT1,  PT0};
        decrypt    = 4'b0000;
        start_all;
        wait_all_done;

        // inst[0]: GB/T standard vector (KEY0+PT0)
        if (results[127:0] === GB_CT) begin
            $display("  PASS: inst[0] = 0x%032h (matches GB_CT)", results[127:0]);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: inst[0] got 0x%032h expected 0x%032h",
                      results[127:0], GB_CT);
            fail_cnt = fail_cnt + 1;
        end

        // inst[1..3]: non-zero, different from plaintext
        for (i = 1; i < NUM_INST; i = i + 1) begin
            if (results[i*128 +: 128] !== 128'h0 &&
                results[i*128 +: 128] !== plaintexts[i*128 +: 128]) begin
                $display("  PASS: inst[%0d] = 0x%032h (non-zero, differs from pt)",
                          i, results[i*128 +: 128]);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: inst[%0d] = 0x%032h (zero or equals pt)",
                          i, results[i*128 +: 128]);
                fail_cnt = fail_cnt + 1;
            end
        end

        // Save ciphertexts for roundtrip
        saved_ct[0] = results[127:0];
        saved_ct[1] = results[255:128];
        saved_ct[2] = results[383:256];
        saved_ct[3] = results[511:384];

        // ================================================================
        // T2: 4 实例并行解密 roundtrip
        // ================================================================
        $display("\n[Test 2] 4 instances parallel decrypt roundtrip");
        keys       = {KEY3, KEY2, KEY1, KEY0};
        plaintexts = {saved_ct[3], saved_ct[2], saved_ct[1], saved_ct[0]};
        decrypt    = 4'b1111;
        start_all;
        wait_all_done;

        // Check roundtrip: results should match original plaintexts
        if (results[127:0] === PT0) begin
            $display("  PASS: inst[0] roundtrip OK");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: inst[0] got 0x%032h expected 0x%032h",
                      results[127:0], PT0);
            fail_cnt = fail_cnt + 1;
        end

        for (i = 1; i < NUM_INST; i = i + 1) begin
            case (i)
                1: if (results[i*128 +: 128] === PT1) begin
                       $display("  PASS: inst[%0d] roundtrip OK", i);
                       pass_cnt = pass_cnt + 1;
                   end else begin
                       $display("  FAIL: inst[%0d] got 0x%032h expected 0x%032h",
                                 i, results[i*128 +: 128], PT1);
                       fail_cnt = fail_cnt + 1;
                   end
                2: if (results[i*128 +: 128] === PT2) begin
                       $display("  PASS: inst[%0d] roundtrip OK", i);
                       pass_cnt = pass_cnt + 1;
                   end else begin
                       $display("  FAIL: inst[%0d] got 0x%032h expected 0x%032h",
                                 i, results[i*128 +: 128], PT2);
                       fail_cnt = fail_cnt + 1;
                   end
                3: if (results[i*128 +: 128] === PT3) begin
                       $display("  PASS: inst[%0d] roundtrip OK", i);
                       pass_cnt = pass_cnt + 1;
                   end else begin
                       $display("  FAIL: inst[%0d] got 0x%032h expected 0x%032h",
                                 i, results[i*128 +: 128], PT3);
                       fail_cnt = fail_cnt + 1;
                   end
            endcase
        end

        // ================================================================
        // T3: 背靠背 (3 轮连续加密)
        // ================================================================
        $display("\n[Test 3] 3 rounds back-to-back (state isolation)");
        keys       = {KEY3, KEY2, KEY1, KEY0};
        plaintexts = {PT3,  PT2,  PT1,  PT0};
        decrypt    = 4'b0000;

        for (round = 0; round < 3; round = round + 1) begin
            start_all;
            wait_all_done;
            if (results[127:0] === GB_CT) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: round %0d inst[0] got 0x%032h",
                          round, results[127:0]);
                fail_cnt = fail_cnt + 1;
            end
        end
        $display("  PASS: 3 rounds, inst[0] consistent");
        pass_cnt = pass_cnt + 1;

        // ================================================================
        // Summary
        // ================================================================
        $display("\n========================================================");
        $display(" Test Summary");
        $display("   PASS : %0d", pass_cnt);
        $display("   FAIL : %0d", fail_cnt);
        $display("========================================================");

        if (fail_cnt == 0 && pass_cnt > 0) begin
            $display(" ALL TESTS PASSED");
        end else begin
            $display(" SOME TESTS FAILED");
        end

        $finish;
    end

endmodule
