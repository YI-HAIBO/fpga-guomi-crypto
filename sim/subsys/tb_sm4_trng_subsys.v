// =============================================================================
// Testbench : tb_sm4_trng_subsys
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-02
// 视角     : sim-verifier (魏波形)
// 目标     : 验证 sm4_trng_subsys 集成模块
//   T1: 外部密钥 + GB/T 标准向量加密 (对照已知密文)
//   T2: 外部密钥 解密 roundtrip
//   T3: TRNG 生成密钥加密 (key 非零 + 输出不等于输入)
//   T4: TRNG 密钥加密→解密 roundtrip
//   T5: 10 次背靠背 (确定性, 结果一致)
//   T6: 复位行为
// =============================================================================

`timescale 1ns / 1ps

module tb_sm4_trng_subsys;

    // =========================================================================
    // 参数 (GB/T 32907-2016 标准向量)
    // =========================================================================
    localparam CLK_PERIOD  = 5;   // 200 MHz
    localparam [127:0] GB_KEY = 128'h0123456789ABCDEFFEDCBA9876543210;
    localparam [127:0] GB_PT  = 128'h0123456789ABCDEFFEDCBA9876543210;
    localparam [127:0] GB_CT  = 128'h681EDF34D206965E86B3E94F536E4246;

    // =========================================================================
    // 信号
    // =========================================================================
    reg         clk;
    reg         rst_n;
    reg         start;
    reg         gen_key;
    reg         decrypt;
    reg  [127:0] ext_key;
    reg  [127:0] data_in;

    wire [127:0] data_out;
    wire [127:0] used_key;
    wire        done;
    wire        busy;
    wire [7:0]  err_code;

    // 统计
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // =========================================================================
    // DUT
    // =========================================================================
    sm4_trng_subsys u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .gen_key   (gen_key),
        .decrypt   (decrypt),
        .ext_key   (ext_key),
        .data_in   (data_in),
        .data_out  (data_out),
        .used_key  (used_key),
        .done      (done),
        .busy      (busy),
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
            start   = 1'b0;
            gen_key = 1'b0;
            decrypt = 1'b0;
            ext_key = 128'd0;
            data_in = 128'd0;
            repeat (10) @(posedge clk);
            rst_n = 1'b1;
            repeat (2)  @(posedge clk);
        end
    endtask

    // =========================================================================
    // 单次请求任务 (阻塞直至 done)
    // =========================================================================
    // input: gen_k, dec, k, d
    // output: out_val (结果), ukey (使用的密钥), err (错误码)
    task do_request(input        gk,
                    input        dc,
                    input  [127:0] k, input  [127:0] d,
                    output [127:0] out_val,
                    output [127:0] ukey,
                    output [7:0]   err);
        integer wait_cnt;
        reg timed_out;
        begin
            wait_cnt  = 0;
            timed_out = 1'b0;
            // 等 DUT 空闲
            while (busy == 1'b1) @(posedge clk);
            @(negedge clk);
            // 设置激励
            start   = 1'b1;
            gen_key = gk;
            decrypt = dc;
            ext_key = k;
            data_in = d;
            @(posedge clk);
            #1;
            start = 1'b0;

            // 等 done
            while (done != 1'b1) begin
                @(posedge clk);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 20000) begin
                    $display("  ERROR: timeout waiting for done (cycles=%0d)", wait_cnt);
                    timed_out = 1'b1;
                    disable do_request;
                end
            end
            // 采样 (done 脉冲期间)
            #1;
            out_val = data_out;
            ukey    = used_key;
            err     = err_code;
            if (timed_out) begin
                out_val = 128'd0;
                ukey    = 128'd0;
                err     = 8'hFF;
            end
        end
    endtask

    // =========================================================================
    // 主测试
    // =========================================================================
    reg  [127:0] r_val;
    reg  [127:0] r_key;
    reg  [7:0]   r_err;
    integer      i;

    initial begin
        $dumpfile("sm4_trng_subsys.vcd");
        $dumpvars(0, tb_sm4_trng_subsys);

        $display("========================================================");
        $display(" SM4+TRNG Subsystem Testbench - %t", $time);
        $display("========================================================");

        do_reset;

        // ------------------------------------------------------------------
        // T1: 外部密钥 + GB/T 向量加密
        // ------------------------------------------------------------------
        $display("\n[Test 1] External key + GB/T vector encrypt");
        do_request(1'b0, 1'b0, GB_KEY, GB_PT, r_val, r_key, r_err);
        if (r_val === GB_CT && r_key === GB_KEY && r_err === 8'h00) begin
            $display("  PASS: data_out=0x%h (matches GB_CT)", r_val);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: data_out=0x%h expected 0x%h", r_val, GB_CT);
            $display("        used_key=0x%h err=0x%h", r_key, r_err);
            fail_cnt = fail_cnt + 1;
        end

        // ------------------------------------------------------------------
        // T2: 外部密钥解密 roundtrip
        // ------------------------------------------------------------------
        $display("\n[Test 2] External key decrypt roundtrip");
        // 用 GB_CT 作为输入, decrypt=1, 应恢复 GB_PT
        do_request(1'b0, 1'b1, GB_KEY, GB_CT, r_val, r_key, r_err);
        if (r_val === GB_PT) begin
            $display("  PASS: decrypted=0x%h (matches GB_PT)", r_val);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: decrypted=0x%h expected 0x%h", r_val, GB_PT);
            fail_cnt = fail_cnt + 1;
        end

        // ------------------------------------------------------------------
        // T3: TRNG 密钥加密 (key 非零 + 输出非平凡)
        // ------------------------------------------------------------------
        $display("\n[Test 3] TRNG-generated key encrypt");
        do_request(1'b1, 1'b0, GB_KEY, GB_PT, r_val, r_key, r_err);
        if (r_key !== 128'd0 && r_val !== GB_PT && r_err === 8'h00) begin
            $display("  PASS: used_key=0x%h data_out=0x%h", r_key, r_val);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: key=0x%h out=0x%h err=0x%h", r_key, r_val, r_err);
            fail_cnt = fail_cnt + 1;
        end

        // ------------------------------------------------------------------
        // T4: TRNG 密钥 roundtrip (加密→用相同密钥解密)
        // ------------------------------------------------------------------
        $display("\n[Test 4] TRNG key encrypt then decrypt roundtrip");
        begin : rt_test
            reg [127:0] ct;
            reg [127:0] rt_key;
            reg [127:0] pt_recovered;
            reg [7:0]   e1, e2;
            // 加密
            do_request(1'b1, 1'b0, 128'd0, GB_PT, ct, rt_key, e1);
            // 解密 (用外部密钥, 强制为刚才生成的 rt_key)
            do_request(1'b0, 1'b1, rt_key, ct, pt_recovered, r_key, e2);
            if (pt_recovered === GB_PT && rt_key !== 128'd0) begin
                $display("  PASS: key=0x%h roundtrip OK", rt_key);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: recovered=0x%h expected 0x%h (key=0x%h)",
                         pt_recovered, GB_PT, rt_key);
                fail_cnt = fail_cnt + 1;
            end
        end

        // ------------------------------------------------------------------
        // T5: 10 次背靠背 (确定性: 相同 key+pt → 相同 ct)
        // ------------------------------------------------------------------
        $display("\n[Test 5] 10x back-to-back external-key encrypt");
        begin : bb_test
            integer success;
            reg [127:0] first_ct;
            success = 0;
            for (i = 0; i < 10; i = i + 1) begin
                do_request(1'b0, 1'b0, GB_KEY, GB_PT, r_val, r_key, r_err);
                if (i == 0) first_ct = r_val;
                if (r_val === first_ct) success = success + 1;
            end
            if (success == 10) begin
                $display("  PASS: All 10 iterations produced 0x%h", first_ct);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: %0d/10 consistent", success);
                fail_cnt = fail_cnt + 1;
            end
        end

        // ------------------------------------------------------------------
        // T6: 复位行为 (复位期间所有输出为 0)
        // ------------------------------------------------------------------
        $display("\n[Test 6] Reset behavior");
        begin : rst_test
            reg pass;
            pass = 1'b1;
            // 发起一次请求, 中途复位
            @(negedge clk);
            start   = 1'b1;
            gen_key = 1'b0;
            decrypt = 1'b0;
            ext_key = GB_KEY;
            data_in = GB_PT;
            @(posedge clk);
            #1;
            start = 1'b0;
            // 等 DUT 进入 busy
            repeat (5) @(posedge clk);
            // 复位
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            // 检查输出
            if (data_out !== 128'd0) begin
                $display("  FAIL: data_out=0x%h not zeroed", data_out);
                pass = 1'b0;
            end
            if (used_key !== 128'd0) begin
                $display("  FAIL: used_key=0x%h not zeroed", used_key);
                pass = 1'b0;
            end
            if (err_code !== 8'h00) begin
                $display("  FAIL: err_code=0x%h not zeroed", err_code);
                pass = 1'b0;
            end
            if (busy !== 1'b0) begin
                $display("  FAIL: busy=%b not zeroed", busy);
                pass = 1'b0;
            end
            // 解除复位
            rst_n = 1'b1;
            repeat (3) @(posedge clk);
            if (pass) begin
                $display("  PASS: All outputs zeroed during reset");
                pass_cnt = pass_cnt + 1;
            end else begin
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
        #5_000_000;
        $display("ERROR: Testbench timeout!");
        $finish;
    end

endmodule
