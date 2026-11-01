// =============================================================================
// tb_sm4_engine_masked_v3 -- SM4 引擎 v3 验证平台 (修复版)
// 版本: 3.0 (v3.0: 1 轮/周期串行化，解决 LUT 超用问题)
// 日期: 2026-10-06
// 目标:
//   T1/T2  masked_en=0  GB/T 零回归 (加密 + 解密)
//   T3/T4  masked_en=1  GB/T 零回归 (加密 + 解密)  << 核心判据
// =============================================================================
`timescale 1ns / 1ps

module tb_sm4_engine_masked_v3;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg [127:0] key = 128'h00000000000000000000000000000000;
    reg [127:0] plaintext = 128'h00000000000000000000000000000000;
    reg decrypt = 1'b0;
    reg [127:0] ciphertext = 128'h00000000000000000000000000000000;

    reg masked_en = 1'b0;
    reg sbox_mask_ext_en = 1'b0;
    reg [7:0] sbox_mask_c_ext = 8'h00;
    reg [2047:0] sbox_mask_tbl_ext = 2048'h0;

    wire [127:0] result;
    wire done, busy;
    wire [7:0] sbox_addr_tap, sbox_mask_c_tap;
    wire sbox_mask_valid, sbox_tbl_valid;

    sm4_engine_masked_v3 dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .key(key), .plaintext(plaintext), .decrypt(decrypt), .ciphertext(ciphertext),
        .result(result), .done(done), .busy(busy),
        .masked_en(masked_en), .sbox_mask_ext_en(sbox_mask_ext_en),
        .sbox_mask_c_ext(sbox_mask_c_ext), .sbox_mask_tbl_ext(sbox_mask_tbl_ext),
        .sbox_addr_tap(sbox_addr_tap), .sbox_mask_c_tap(sbox_mask_c_tap),
        .sbox_mask_valid(sbox_mask_valid), .sbox_tbl_valid(sbox_tbl_valid)
    );

    always #5 clk = ~clk;

    integer timeout_cnt;
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // 发起一次加/解密并等 done
    task do_sm4;
        input [127:0] k_in;
        input [127:0] data_in;
        input dec_in;
        begin
            @(negedge clk);
            key        = k_in;
            plaintext  = data_in;
            ciphertext = data_in;
            decrypt    = dec_in;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            timeout_cnt = 0;
            @(posedge clk);
            while (!done && timeout_cnt < 1000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (timeout_cnt >= 1000) begin
                $display("  FAIL: timeout after %0d cycles", timeout_cnt);
                $finish;
            end
        end
    endtask

    // 比对当前 result 与期望值
    task chk_eq;
        input [127:0] exp_v;
        input [9:0]   id_v;
        begin
            if (result === exp_v) begin
                $display("  PASS[#%02d]", id_v);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL[#%02d]: exp %h", id_v, exp_v);
                $display("           got      %h", result);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_sm4_engine_masked_v3.vcd");
        $dumpvars(0, dut.fsm_state, dut.k_idx, dut.buf_sel,
                  dut.c_a, dut.c_b, dut.seed,
                  dut.sbox_mask_valid, done, busy);

        rst_n            = 1'b0;
        masked_en        = 1'b0;
        sbox_mask_ext_en = 1'b0;
        #30;
        @(negedge clk);
        rst_n = 1'b1;
        #10;

        // =====================================================================
        // T1: masked_en=0  GB/T 官方向量 (加密)  -- 零回归基线
        // =====================================================================
        $display("=== T1: masked_en=0  GB/T official vector (encrypt) ===");
        do_sm4(128'h0123456789abcdeffedcba9876543210, 128'h0123456789abcdeffedcba9876543210, 1'b0);
        chk_eq(128'h681edf34d206965e86b3e94f536e4246, 10'd1);

        // =====================================================================
        // T2: masked_en=0  GB/T 官方向量 (解密)
        // =====================================================================
        $display("=== T2: masked_en=0  GB/T official vector (decrypt) ===");
        do_sm4(128'h0123456789abcdeffedcba9876543210, 128'h681edf34d206965e86b3e94f536e4246, 1'b1);
        chk_eq(128'h0123456789abcdeffedcba9876543210, 10'd2);

        // =====================================================================
        // T3: masked_en=1  GB/T 官方向量 (加密)  -- B-3 核心零回归判据
        // =====================================================================
        $display("=== T3: masked_en=1  GB/T official vector (encrypt) ===");
        masked_en = 1'b1;
        do_sm4(128'h0123456789abcdeffedcba9876543210, 128'h0123456789abcdeffedcba9876543210, 1'b0);
        chk_eq(128'h681edf34d206965e86b3e94f536e4246, 10'd3);

        // =====================================================================
        // T4: masked_en=1  GB/T 官方向量 (解密)
        // =====================================================================
        $display("=== T4: masked_en=1  GB/T official vector (decrypt) ===");
        do_sm4(128'h0123456789abcdeffedcba9876543210, 128'h681edf34d206965e86b3e94f536e4246, 1'b1);
        chk_eq(128'h0123456789abcdeffedcba9876543210, 10'd4);

        // =====================================================================
        // 汇总
        // =====================================================================
        $display("====================================================");
        $display("SM4_ENGINE_MASKED_V3 (v3.0) REGRESSION SUMMARY");
        $display("  PASS: %0d", pass_cnt);
        $display("  FAIL: %0d", fail_cnt);
        $display("====================================================");
        if (fail_cnt == 0) $display("ALL PASS");
        else               $display("SOME FAILED");
        $finish;
    end

    initial begin
        #3000000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
