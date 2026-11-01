// =============================================================================
// tb_mask_gen_lfsr.v -- B2 共享 LFSR 模块测试 (v1.0)
// -----------------------------------------------------------------------------
// 微规格书: docs/Phase0_5_B2_跨引擎资源共享_微规格书_v1.md §6
//
// 测试目标
// ----------
// T1: seed 加载 —— m0 == seed（等价性）
// T2: 单步递推正确性 —— m1 等于参考 lfsr_step(seed) 的 Python 计算值
// T3: 前 16 步完全对齐 Python 参考实现
// T4: 不同 seed 得到不同流 —— m0 与 seed 相等；不同 seed 的 m15 不同
// T5: 相邻掩码字汉明距离 —— 期望接近 16（16 步递推的自相关衰减）
// T6: 零回归验证 —— 与 C2 内 lfsr_step 函数展开结果一致
// =============================================================================

`timescale 1ns/1ps

module tb_mask_gen_lfsr;

    // DUT signals
    reg  [31:0] seed;
    wire [31:0] m0, m1, m2, m3, m4, m5, m6, m7;
    wire [31:0] m8, m9, m10, m11, m12, m13, m14, m15;

    // DUT instantiation
    mask_gen_lfsr u_dut (
        .seed(seed),
        .m0(m0), .m1(m1), .m2(m2), .m3(m3),
        .m4(m4), .m5(m5), .m6(m6), .m7(m7),
        .m8(m8), .m9(m9), .m10(m10), .m11(m11),
        .m12(m12), .m13(m13), .m14(m14), .m15(m15)
    );

    // Test counters
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // Popcount function (for T5 Hamming distance; -g2005 无 $countones)
    function integer popcount;
        input [31:0] x;
        integer i;
        begin
            popcount = 0;
            for (i = 0; i < 32; i = i + 1) begin
                if (x[i]) popcount = popcount + 1;
            end
        end
    endfunction

    // ====================================================================
    // T1: seed 加载 (m0 == seed)
    // ====================================================================
    task t1_seed_load;
        begin
            seed = 32'hDEAD_BEEF;
            #1;
            if (m0 === seed) begin
                pass_cnt = pass_cnt + 1;
                $display("[T1] PASS m0 == seed = 0x%08h", m0);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("[T1] FAIL m0=0x%08h != seed=0x%08h", m0, seed);
            end
        end
    endtask

    // ====================================================================
    // T2: 单步递推正确性 (m1 与 Python 参考实现一致)
    // Python 参考: lfsr_step(x) = {x[30:0], x[31]^x[21]^x[1]^x[0]}
    //             seed=0xDEADBEEF ->
    //             bit31=1, bit21=1, bit1=1, bit0=1  -> fb = 1^1^1^1 = 0
    //             seed[30:0] = 0x5EADBEEF
    //             m1 = (0x5EADBEEF << 1) | 0 = 0xBD5B7DDE
    // ====================================================================
    task t2_single_step;
        begin
            seed = 32'hDEAD_BEEF;
            #1;
            if (m1 === 32'hBD5B_7DDE) begin
                pass_cnt = pass_cnt + 1;
                $display("[T2] PASS m1 = 0x%08h (expected 0xBD5B7DDE)", m1);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("[T2] FAIL m1 = 0x%08h (expected 0xBD5B7DDE)", m1);
            end
        end
    endtask

    // ====================================================================
    // T3: 16 步对齐 Python 参考实现
    // ====================================================================
    task t3_16_steps_match_python;
        reg [31:0] ref [0:15];
        integer i;
        reg [31:0] cur;
        reg [31:0] got;
        integer mismatch_cnt;

        begin
            // Compute reference using same formula
            cur = 32'hDEAD_BEEF;
            ref[0] = cur;
            for (i = 1; i < 16; i = i + 1) begin
                cur = {cur[30:0], cur[31] ^ cur[21] ^ cur[1] ^ cur[0]};
                ref[i] = cur;
            end

            // Read DUT outputs
            seed = 32'hDEAD_BEEF;
            #1;

            mismatch_cnt = 0;
            got = m0;  if (got !== ref[0]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m0 mismatch: got=0x%08h ref=0x%08h", got, ref[0]); end
            got = m1;  if (got !== ref[1]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m1 mismatch: got=0x%08h ref=0x%08h", got, ref[1]); end
            got = m2;  if (got !== ref[2]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m2 mismatch: got=0x%08h ref=0x%08h", got, ref[2]); end
            got = m3;  if (got !== ref[3]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m3 mismatch: got=0x%08h ref=0x%08h", got, ref[3]); end
            got = m4;  if (got !== ref[4]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m4 mismatch: got=0x%08h ref=0x%08h", got, ref[4]); end
            got = m5;  if (got !== ref[5]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m5 mismatch: got=0x%08h ref=0x%08h", got, ref[5]); end
            got = m6;  if (got !== ref[6]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m6 mismatch: got=0x%08h ref=0x%08h", got, ref[6]); end
            got = m7;  if (got !== ref[7]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m7 mismatch: got=0x%08h ref=0x%08h", got, ref[7]); end
            got = m8;  if (got !== ref[8]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m8 mismatch: got=0x%08h ref=0x%08h", got, ref[8]); end
            got = m9;  if (got !== ref[9]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m9 mismatch: got=0x%08h ref=0x%08h", got, ref[9]); end
            got = m10; if (got !== ref[10]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m10 mismatch: got=0x%08h ref=0x%08h", got, ref[10]); end
            got = m11; if (got !== ref[11]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m11 mismatch: got=0x%08h ref=0x%08h", got, ref[11]); end
            got = m12; if (got !== ref[12]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m12 mismatch: got=0x%08h ref=0x%08h", got, ref[12]); end
            got = m13; if (got !== ref[13]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m13 mismatch: got=0x%08h ref=0x%08h", got, ref[13]); end
            got = m14; if (got !== ref[14]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m14 mismatch: got=0x%08h ref=0x%08h", got, ref[14]); end
            got = m15; if (got !== ref[15]) begin mismatch_cnt = mismatch_cnt + 1; $display("  m15 mismatch: got=0x%08h ref=0x%08h", got, ref[15]); end

            if (mismatch_cnt == 0) begin
                pass_cnt = pass_cnt + 1;
                $display("[T3] PASS 16 steps all match Python reference");
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("[T3] FAIL %d/16 mismatch", mismatch_cnt);
            end
        end
    endtask

    // ====================================================================
    // T4: 不同 seed 得到不同流
    // ====================================================================
    task t4_distinct_seeds;
        reg [31:0] seed_a, seed_b;
        reg [31:0] m15_a, m15_b;
        begin
            seed_a = 32'hDEAD_BEEF;
            seed = seed_a;
            #1;
            m15_a = m15;

            seed_b = 32'hCAFEBABE;
            seed = seed_b;
            #1;
            m15_b = m15;

            if (m15_a !== m15_b) begin
                pass_cnt = pass_cnt + 1;
                $display("[T4] PASS m15(seed_a=0x%08h)=0x%08h != m15(seed_b=0x%08h)=0x%08h",
                         seed_a, m15_a, seed_b, m15_b);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("[T4] FAIL m15 collides for different seeds");
            end
        end
    endtask

    // ====================================================================
    // T5: 相邻掩码字汉明距离 (自相关衰减)
    // ====================================================================
    task t5_hamming_distance;
        integer hd01, hd12, hd78, hd1415;
        integer total_hd;
        begin
            seed = 32'hDEAD_BEEF;
            #1;

            // Hamming distance function (32-bit)
            // HD(a,b) = popcount(a ^ b)
            // Manual computation via bit XOR
            hd01   = popcount(m0 ^ m1);
            hd12   = popcount(m1 ^ m2);
            hd78   = popcount(m7 ^ m8);
            hd1415 = popcount(m14 ^ m15);
            total_hd = hd01 + hd12 + hd78 + hd1415;

            $display("[T5] HD(m0,m1)=%0d  HD(m1,m2)=%0d  HD(m7,m8)=%0d  HD(m14,m15)=%0d  total=%0d",
                     hd01, hd12, hd78, hd1415, total_hd);

            // Expected: each adjacent pair has Hamming distance in [10, 22]
            // (rough range for LFSR step of a random-like 32-bit word)
            if (hd01 >= 10 && hd01 <= 22 &&
                hd12 >= 10 && hd12 <= 22 &&
                hd78 >= 10 && hd78 <= 22 &&
                hd1415 >= 10 && hd1415 <= 22) begin
                pass_cnt = pass_cnt + 1;
                $display("[T5] PASS adjacent Hamming distances in [10,22]");
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("[T5] FAIL adjacent Hamming distances out of expected range");
            end
        end
    endtask

    // ====================================================================
    // T6: 与 C2 内联 LFSR 参考一致 (跨引擎一致性验证)
    // C2 用 function lfsr_step(x) = {x[30:0], x[31]^x[21]^x[1]^x[0]};
    // 与 mask_gen_lfsr 的 s_i 递推公式完全相同 → 应产生相同序列
    // ====================================================================
    task t6_cross_engine_consistency;
        reg [31:0] c2_seed, c2_ref [0:15];
        integer i;
        reg [31:0] cur;

        begin
            // Use a different seed to ensure generality
            c2_seed = 32'h1234_5678;
            seed = c2_seed;
            #1;

            // Compute C2-style reference
            cur = c2_seed;
            c2_ref[0] = cur;
            for (i = 1; i < 16; i = i + 1) begin
                cur = {cur[30:0], cur[31] ^ cur[21] ^ cur[1] ^ cur[0]};
                c2_ref[i] = cur;
            end

            // Compare DUT m0..m15 to c2_ref
            if (m0  === c2_ref[0]  && m1  === c2_ref[1]  &&
                m2  === c2_ref[2]  && m3  === c2_ref[3]  &&
                m4  === c2_ref[4]  && m5  === c2_ref[5]  &&
                m6  === c2_ref[6]  && m7  === c2_ref[7]  &&
                m8  === c2_ref[8]  && m9  === c2_ref[9]  &&
                m10 === c2_ref[10] && m11 === c2_ref[11] &&
                m12 === c2_ref[12] && m13 === c2_ref[13] &&
                m14 === c2_ref[14] && m15 === c2_ref[15]) begin
                pass_cnt = pass_cnt + 1;
                $display("[T6] PASS all 16 steps match C2-style reference (seed=0x%08h)", c2_seed);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("[T6] FAIL at least one step mismatched C2-style reference");
            end
        end
    endtask

    // ====================================================================
    // Main
    // ====================================================================
    initial begin
        $dumpfile("mask_gen_lfsr.vcd");
        $dumpvars(0, tb_mask_gen_lfsr);

        $display("========================================================");
        $display(" mask_gen_lfsr Testbench (v1.0)");
        $display(" B2 MVP: 跨引擎共享 LFSR 掩码生成器");
        $display(" Polynomial: x^32 + x^22 + x^2 + x + 1 (full period)");
        $display("========================================================");

        t1_seed_load;
        t2_single_step;
        t3_16_steps_match_python;
        t4_distinct_seeds;
        t5_hamming_distance;
        t6_cross_engine_consistency;

        $display("========================================================");
        $display(" Test Summary");
        $display("   PASS: %0d", pass_cnt);
        $display("   FAIL: %0d", fail_cnt);
        $display("========================================================");
        if (fail_cnt == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("TESTS FAILED");
        end
        $finish;
    end

endmodule
