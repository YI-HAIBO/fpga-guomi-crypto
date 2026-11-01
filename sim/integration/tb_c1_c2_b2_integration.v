// =============================================================================
// tb_c1_c2_b2_integration.v -- C1/C2/B2 集成验证 Testbench (v1.1)
// =============================================================================
// 版本: 1.1 (2026-10-05)
// 关联: Phase 0.5 C1-2 + C2-2 + B2 集成验证
//
// 目标: 同一顶层同时例化:
//   - sm4_engine_sys_masked_wrapper (C1-2b)
//   - sm3_engine_masked v3.2 (C2-2 + B2 重构)
//   - mask_gen_lfsr (B2 共享 LFSR)
// 验证:
//   T1: SM4 GB/T 向量, wrapper_en=0 (C1 零回归)
//   T2: SM3 "abc", wrapper_en=0 (C2 零回归)
//   T3: SM4 wrapper_en=1, b_res^b_rout == ref (掩码可恢复)
//   T4: SM3 wrapper_en=1, hash 不变 + w_probe 变化
//   T5: B2 两独立实例确定性 (同 seed 同 m_out)
//   T6: C2 采纳 B2 — 不同 mask_seed → w_probe 变化, hash 不变
//   T7: 并行执行 — SM3 与 SM4 同时启动, 各自独立 done
// =============================================================================

`timescale 1ns / 1ps

module tb_c1_c2_b2_integration;

    // =========================================================================
    // 时钟与复位
    // =========================================================================
    reg clk;
    reg rst_n = 1'b0;
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;   // 100 MHz, 10ns period
    end

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // =========================================================================
    // SM4 C1-2b wrapper 双实例 (masked_off / masked_on)
    // =========================================================================
    reg          sm4_start;
    reg          sm4_decrypt;
    reg  [127:0] sm4_key;
    reg  [127:0] sm4_pt;
    reg  [127:0] sm4_ct;
    reg  [127:0] sm4_trng;
    reg          sm4_trng_valid;

    wire [127:0] sm4_a_res, sm4_a_rout;
    wire         sm4_a_done, sm4_a_busy;
    wire [127:0] sm4_b_res, sm4_b_rout;
    wire         sm4_b_done, sm4_b_busy;

    sm4_engine_sys_masked_wrapper #(.wrapper_masked_en(1'b0)) u_sm4_a (
        .clk(clk), .rst_n(rst_n),
        .start(sm4_start), .key(sm4_key), .plaintext(sm4_pt),
        .decrypt(sm4_decrypt), .ciphertext(sm4_ct),
        .trng_data(sm4_trng), .trng_valid(sm4_trng_valid),
        .result(sm4_a_res), .r_out(sm4_a_rout),
        .done(sm4_a_done), .busy(sm4_a_busy)
    );

    sm4_engine_sys_masked_wrapper #(.wrapper_masked_en(1'b1)) u_sm4_b (
        .clk(clk), .rst_n(rst_n),
        .start(sm4_start), .key(sm4_key), .plaintext(sm4_pt),
        .decrypt(sm4_decrypt), .ciphertext(sm4_ct),
        .trng_data(sm4_trng), .trng_valid(sm4_trng_valid),
        .result(sm4_b_res), .r_out(sm4_b_rout),
        .done(sm4_b_done), .busy(sm4_b_busy)
    );

    // =========================================================================
    // SM3 C2-2 双实例
    // =========================================================================
    localparam [255:0] IV_SM3 =
        256'h7380166f4914b2b9172442d7da8a0600a96f30bc163138aae38dee4db0fb0e4e;
    localparam [511:0] MSG_ABC =
        512'h61626380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018;
    localparam [255:0] HASH_ABC =
        256'h66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0;

    reg          sm3a_start, sm3b_start;
    reg  [511:0] sm3a_msg,   sm3b_msg;
    reg  [255:0] sm3a_prev,  sm3b_prev;
    reg  [31:0]  sm3a_seed,  sm3b_seed;

    wire [255:0] sm3a_out, sm3b_out;
    wire         sm3a_done, sm3b_done;
    wire         sm3a_busy, sm3b_busy;
    wire [31:0]  sm3a_probe, sm3b_probe;

    sm3_engine_masked #(.wrapper_masked_en(1'b0)) u_sm3a (
        .clk(clk), .rst_n(rst_n),
        .start(sm3a_start), .msg_block(sm3a_msg), .prev_state(sm3a_prev),
        .out_state(sm3a_out), .done(sm3a_done), .busy(sm3a_busy),
        .mask_seed(sm3a_seed), .w_stored_probe(sm3a_probe)
    );

    sm3_engine_masked #(.wrapper_masked_en(1'b1)) u_sm3b (
        .clk(clk), .rst_n(rst_n),
        .start(sm3b_start), .msg_block(sm3b_msg), .prev_state(sm3b_prev),
        .out_state(sm3b_out), .done(sm3b_done), .busy(sm3b_busy),
        .mask_seed(sm3b_seed), .w_stored_probe(sm3b_probe)
    );

    // =========================================================================
    // B2 共享 LFSR 两独立实例 (确定性验证)
    // =========================================================================
    reg [31:0] seed_ref;
    wire [31:0] lfa_m0,  lfa_m1,  lfa_m2,  lfa_m3,
                lfa_m4,  lfa_m5,  lfa_m6,  lfa_m7,
                lfa_m8,  lfa_m9,  lfa_m10, lfa_m11,
                lfa_m12, lfa_m13, lfa_m14, lfa_m15;
    wire [31:0] lfb_m0,  lfb_m1,  lfb_m2,  lfb_m3,
                lfb_m4,  lfb_m5,  lfb_m6,  lfb_m7,
                lfb_m8,  lfb_m9,  lfb_m10, lfb_m11,
                lfb_m12, lfb_m13, lfb_m14, lfb_m15;

    mask_gen_lfsr u_lfsr_a (
        .seed(seed_ref),
        .m0(lfa_m0), .m1(lfa_m1), .m2(lfa_m2), .m3(lfa_m3),
        .m4(lfa_m4), .m5(lfa_m5), .m6(lfa_m6), .m7(lfa_m7),
        .m8(lfa_m8), .m9(lfa_m9), .m10(lfa_m10), .m11(lfa_m11),
        .m12(lfa_m12), .m13(lfa_m13), .m14(lfa_m14), .m15(lfa_m15)
    );
    mask_gen_lfsr u_lfsr_b (
        .seed(seed_ref),
        .m0(lfb_m0), .m1(lfb_m1), .m2(lfb_m2), .m3(lfb_m3),
        .m4(lfb_m4), .m5(lfb_m5), .m6(lfb_m6), .m7(lfb_m7),
        .m8(lfb_m8), .m9(lfb_m9), .m10(lfb_m10), .m11(lfb_m11),
        .m12(lfb_m12), .m13(lfb_m13), .m14(lfb_m14), .m15(lfb_m15)
    );

    // =========================================================================
    // 辅助变量 (module-level, Verilog-2005 要求)
    // =========================================================================
    reg [255:0] tmp_hash_a, tmp_hash_b;
    reg [31:0]  tmp_probe;
    integer     seed_i, vary_cnt, hash_fail;

    // =========================================================================
    // 主测试流程
    // =========================================================================
    initial begin
        $dumpfile("c1_c2_b2_integ.vcd");
        $dumpvars(0, tb_c1_c2_b2_integration);

        $display("==============================================================");
        $display(" C1/C2/B2 集成验证 Testbench (v1.1)");
        $display("==============================================================");

        // ---- 复位 ----
        sm4_start       = 1'b0;
        sm4_decrypt     = 1'b0;
        sm4_key         = 128'd0;
        sm4_pt          = 128'd0;
        sm4_ct          = 128'd0;
        sm4_trng        = 128'd0;
        sm4_trng_valid  = 1'b1;
        sm3a_start      = 1'b0;
        sm3b_start      = 1'b0;
        sm3a_msg        = 512'd0;
        sm3b_msg        = 512'd0;
        sm3a_prev       = 256'd0;
        sm3b_prev       = 256'd0;
        sm3a_seed       = 32'h0;
        sm3b_seed       = 32'h0;
        seed_ref        = 32'h0;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (4)  @(posedge clk);

        // ==================================================================
        // T1: SM4 GB/T, wrapper_en=0 (C1 零回归)
        // ==================================================================
        $display("\n[T1] SM4 GB/T vector, wrapper_en=0");
        @(negedge clk);
        sm4_key         = 128'h0123456789ABCDEFFEDCBA9876543210;
        sm4_pt          = 128'h0123456789ABCDEFFEDCBA9876543210;
        sm4_ct          = sm4_pt;
        sm4_decrypt     = 1'b0;
        sm4_trng        = 128'hDEADBEEFDEADBEEFDEADBEEFDEADBEEF;
        sm4_trng_valid  = 1'b1;
        sm4_start       = 1'b1;
        @(negedge clk);
        sm4_start       = 1'b0;
        wait(sm4_a_done == 1'b1);
        #1;
        $display("  [debug] sm4_a_res = %h, sm4_a_rout = %h", sm4_a_res, sm4_a_rout);
        $display("  [debug] sm4_b_res = %h, sm4_b_rout = %h", sm4_b_res, sm4_b_rout);
        if (sm4_a_res === 128'h681EDF34D206965E86B3E94F536E4246) begin
            $display("  PASS sm4_a_res = 681EDF34D206965E86B3E94F536E4246");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL expected 681EDF... got %h", sm4_a_res);
            fail_cnt = fail_cnt + 1;
        end
        if (sm4_a_rout === 128'd0) begin
            $display("  PASS sm4_a_rout == 0");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL sm4_a_rout = %h", sm4_a_rout);
            fail_cnt = fail_cnt + 1;
        end

        // ==================================================================
        // T2: SM3 "abc", wrapper_en=0 (C2 零回归)
        // ==================================================================
        $display("\n[T2] SM3 'abc', wrapper_en=0");
        @(negedge clk);
        sm3a_msg   = MSG_ABC;
        sm3a_prev  = IV_SM3;
        sm3a_seed  = 32'h0;
        sm3a_start = 1'b1;
        @(negedge clk);
        sm3a_start = 1'b0;
        wait(sm3a_done == 1'b1);
        @(posedge clk);
        #1;
        tmp_hash_a = sm3a_out;
        if (tmp_hash_a === HASH_ABC) begin
            $display("  PASS hash_a = 66c7f0f4...8e0");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL hash_a expected 66c7f0f4... got %h", tmp_hash_a);
            fail_cnt = fail_cnt + 1;
        end

        // ==================================================================
        // T3: SM4 wrapper_en=1, (b_res ^ b_rout) == ref
        // ==================================================================
        $display("\n[T3] SM4 wrapper_en=1, masked output recoverable");
        @(negedge clk);
        sm4_key         = 128'h0123456789ABCDEFFEDCBA9876543210;
        sm4_pt          = 128'h0123456789ABCDEFFEDCBA9876543210;
        sm4_ct          = sm4_pt;
        sm4_decrypt     = 1'b0;
        sm4_trng        = 128'hA5A5A5A5A5A5A5A55A5A5A5A5A5A5A5A;
        sm4_trng_valid  = 1'b1;
        sm4_start       = 1'b1;
        @(negedge clk);
        sm4_start       = 1'b0;
        wait(sm4_b_done == 1'b1);
        #1;
        if (sm4_b_rout === 128'hA5A5A5A5A5A5A5A55A5A5A5A5A5A5A5A) begin
            $display("  PASS b_rout = A5A5...5A5A (正确采样)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL b_rout = %h", sm4_b_rout);
            fail_cnt = fail_cnt + 1;
        end
        if ((sm4_b_res ^ sm4_b_rout) === 128'h681EDF34D206965E86B3E94F536E4246) begin
            $display("  PASS (b_res^b_rout) == 681EDF...");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL (b_res^b_rout) = %h", sm4_b_res ^ sm4_b_rout);
            fail_cnt = fail_cnt + 1;
        end
        if (sm4_b_res !== 128'h681EDF34D206965E86B3E94F536E4246) begin
            $display("  PASS b_res != ref (已随机化)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL b_res == ref (未随机化)");
            fail_cnt = fail_cnt + 1;
        end

        // ==================================================================
        // T4: SM3 wrapper_en=1, hash 不变 + w_probe 随机化
        // ==================================================================
        $display("\n[T4] SM3 wrapper_en=1, hash unchanged, w_probe != W_true");
        @(negedge clk);
        sm3b_msg   = MSG_ABC;
        sm3b_prev  = IV_SM3;
        sm3b_seed  = 32'hDEADBEEF;
        sm3b_start = 1'b1;
        @(negedge clk);
        sm3b_start = 1'b0;
        wait(sm3b_done == 1'b1);
        @(posedge clk);
        #1;
        tmp_hash_b = sm3b_out;
        tmp_probe  = sm3b_probe;
        $display("  hash_b  = %h", tmp_hash_b);
        $display("  probe_b = 0x%h  (W_true = 0x61626380)", tmp_probe);
        if (tmp_hash_b === HASH_ABC) begin
            $display("  PASS hash_b unchanged");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL hash_b changed");
            fail_cnt = fail_cnt + 1;
        end
        if (tmp_probe !== 32'h61626380) begin
            $display("  PASS w_probe != W_true");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL w_probe == W_true");
            fail_cnt = fail_cnt + 1;
        end

        // ==================================================================
        // T5: B2 确定性 — 两独立 mask_gen_lfsr 实例, 同 seed 同 m_out
        // ==================================================================
        $display("\n[T5] B2 determinism: u_lfsr_a == u_lfsr_b for same seed");
        seed_ref = 32'h12345678;
        @(negedge clk);
        #1;
        begin : t5_check
            integer mismatch_cnt;
            mismatch_cnt = 0;
            if (lfa_m0  !== lfb_m0)  mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m1  !== lfb_m1)  mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m2  !== lfb_m2)  mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m3  !== lfb_m3)  mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m4  !== lfb_m4)  mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m5  !== lfb_m5)  mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m6  !== lfb_m6)  mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m7  !== lfb_m7)  mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m8  !== lfb_m8)  mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m9  !== lfb_m9)  mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m10 !== lfb_m10) mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m11 !== lfb_m11) mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m12 !== lfb_m12) mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m13 !== lfb_m13) mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m14 !== lfb_m14) mismatch_cnt = mismatch_cnt + 1;
            if (lfa_m15 !== lfb_m15) mismatch_cnt = mismatch_cnt + 1;
            if (mismatch_cnt == 0) begin
                $display("  PASS 16/16 m_out identical (DRY contract)");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL %0d/16 m_out differ", mismatch_cnt);
                fail_cnt = fail_cnt + 1;
            end
        end

        // ==================================================================
        // T6: C2 采纳 B2 — 不同 mask_seed → w_probe 变化, hash 不变
        // ==================================================================
        $display("\n[T6] C2 uses B2: different mask_seed → w_probe varies, hash same");
        begin : t6_block
            integer v_cnt, h_fail, prev_p, s_idx;
            v_cnt  = 0;
            h_fail = 0;
            prev_p = tmp_probe;  // 用 T4 的 probe 作为起点
            for (s_idx = 1; s_idx <= 8; s_idx = s_idx + 1) begin
                @(negedge clk);
                sm3b_msg   = MSG_ABC;
                sm3b_prev  = IV_SM3;
                sm3b_seed  = s_idx * 32'hDEADBEEF;
                sm3b_start = 1'b1;
                @(negedge clk);
                sm3b_start = 1'b0;
                wait(sm3b_done == 1'b1);
                @(posedge clk);
                #1;
                tmp_hash_b = sm3b_out;
                tmp_probe  = sm3b_probe;
                $display("  seed=0x%08h  probe=0x%08h  hash_match=%b",
                         s_idx * 32'hDEADBEEF, tmp_probe,
                         (tmp_hash_b == HASH_ABC));
                if (tmp_probe != prev_p) v_cnt = v_cnt + 1;
                if (tmp_hash_b != HASH_ABC) h_fail = h_fail + 1;
                prev_p = tmp_probe;
            end
            $display("  unique transitions: %0d/7  hash mismatches: %0d/8",
                     v_cnt, h_fail);
            if (v_cnt >= 6 && h_fail == 0) begin
                $display("  PASS (B2 mask_seed 驱动 w_probe 随机化, hash 不变)");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL");
                fail_cnt = fail_cnt + 1;
            end
        end

        // ==================================================================
        // T7: 并行执行 — SM3 & SM4 同时启动
        // ==================================================================
        $display("\n[T7] Parallel execution: SM3 & SM4 coexist (no multi-drive)");
        @(negedge clk);
        sm4_key         = 128'h0123456789ABCDEFFEDCBA9876543210;
        sm4_pt          = 128'h0123456789ABCDEFFEDCBA9876543210;
        sm4_ct          = sm4_pt;
        sm4_decrypt     = 1'b0;
        sm4_trng        = 128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        sm4_trng_valid  = 1'b1;
        sm3a_msg        = MSG_ABC;
        sm3a_prev       = IV_SM3;
        sm3a_seed       = 32'h0;
        sm4_start       = 1'b1;
        sm3a_start      = 1'b1;
        @(negedge clk);
        sm4_start       = 1'b0;
        sm3a_start      = 1'b0;
        wait(sm4_a_done == 1'b1 && sm3a_done == 1'b1);
        @(posedge clk);
        #1;
        begin : t7_check
            integer m_cnt;
            m_cnt = 0;
            if (sm4_a_res !== 128'h681EDF34D206965E86B3E94F536E4246) m_cnt = m_cnt + 1;
            if (sm3a_out !== HASH_ABC) m_cnt = m_cnt + 1;
            if (m_cnt == 0) begin
                $display("  PASS both engines produced correct result in parallel");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL %0d engine(s) mismatch", m_cnt);
                $display("    SM4 = %h", sm4_a_res);
                $display("    SM3 = %h", sm3a_out);
                fail_cnt = fail_cnt + 1;
            end
        end

        // ==================================================================
        // 汇总
        // ==================================================================
        $display("\n==============================================================");
        $display(" Test Summary");
        $display("   PASS: %0d", pass_cnt);
        $display("   FAIL: %0d", fail_cnt);
        $display("==============================================================");
        if (fail_cnt == 0) $display(" ALL TESTS PASSED");
        else               $display(" SOME TESTS FAILED");

        #100;
        $finish;
    end

    // =========================================================================
    // 全局超时保护
    // =========================================================================
    initial begin
        #80_000_000;
        $display("ERROR: global timeout!");
        $finish;
    end

endmodule
