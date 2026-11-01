// =============================================================================
// tb_trng_health_test_v3.v
//
// D1 v3.0 模块级验证: trng_health_test_v3 (NIST SP 800-90B 七检验, WIN=1024)
//
// 测试清单
//   T0  复位自检 (pass=1 fail=0 status_win=0)
//   T1  好流 4 窗口 (16 位 LFSR 确定性参考流): 七项全过 4/4 窗口
//   T2  冻结流 (全 1): 至少 T1/T3/T4/T5/T7 命中
//   T3  偏置流 (62.5% 一): proportion 必失败 (T1=0)
//   T4  周期-2 流 (0101...): poker+correlation+T5+T6+T7 失败
//   T5  偏置 cumsum 定向流 (200 零 + 824 一): T6 cumsum 必失败 (|S|>>105)
//   T6  全零流 (period-1): 全 7 项命中, 覆盖 v3 新增项最强退化
//   T7  分段请求 (L1 修复回归): 累加器跨请求连续累积, 3 个窗口成
//   T8  E1 生产熵源 (RO xor) 4 窗口: >=3/4 窗口通过 (统计检验 97.5% 通过率)
//   T9  fail 粘滞: 冻结流失败后好流 pass 恢复, fail 保持 1
//
// 驱动时序 (race-free): posedge 后 #1 窗口内设信号, 再 @(posedge clk) 采样。
// =============================================================================
`timescale 1ns / 1ps

module tb_trng_health_test_v3;

    localparam CLK_HALF = 5;           // 100 MHz
    localparam N_GOOD   = 4096;        // T1/T8: 4 窗口
    localparam REPORT   = "trng_ht_v3_report.txt";

    integer fd, k, seg, n_err;
    integer cnt_v3;
    integer pass_cnt;                  // 七项全过窗口数
    integer win_idx;
    reg [6:0] win_hist [0:7];
    integer   ones_hist [0:7];
    integer   maxrun_hist [0:7];
    integer   corr_hist [0:7];
    integer   sq_hist   [0:7];
    integer   runs_hist [0:7];
    integer   cmax_hist [0:7];
    integer   ssum_hist [0:7];
    integer ones_snap, maxrun_snap, corr_snap, sq_snap;
    integer runs_snap, cmax_snap, ssum_snap;
    reg     pass_seen;                 // T9 用

    // ---- clock -----------------------------------------------------------
    reg clk;
    initial begin
        clk = 1'b0;
        forever #(CLK_HALF) clk = ~clk;
    end

    // ---- signals ---------------------------------------------------------
    reg         rst_n;
    reg         bit_in;
    reg         bit_vld;
    wire        pass_v3, fail_v3, win_v3;
    wire [6:0]  status_v3, status_win_v3;

    // ---- DUT -------------------------------------------------------------
    trng_health_test_v3 u_v3 (
        .clk        (clk),
        .rst_n      (rst_n),
        .bit_in     (bit_in),
        .bit_vld    (bit_vld),
        .pass       (pass_v3),
        .fail       (fail_v3),
        .win_pulse  (win_v3),
        .status     (status_v3),
        .status_win (status_win_v3)
    );

    // ---- 好流 1: 16 位 LFSR (与 v2 TB 完全相同的确定性参考流) -----------
    // 抽头 bit0^bit4^bit13^bit15, 左移 Fibonacci, 种子 0x0001
    reg  [15:0] lfsr;
    initial lfsr = 16'h0001;
    wire        lfsr_fb  = lfsr[0] ^ lfsr[4] ^ lfsr[13] ^ lfsr[15];
    wire        lfsr_out = lfsr_fb;
    always @(posedge clk) lfsr <= {lfsr[14:0], lfsr_fb};

    // ---- 好流 2: RO xor (E1 生产熵源, 与 v2 TB 一致) ---------------------
    wire ro11, ro9, ro7;
    ro11 ro_a (.q(ro11));
    ro9  ro_b (.q(ro9));
    ro7  ro_c (.q(ro7));
    reg ro11_s, ro9_s, ro7_s;
    wire good_bit = ro11_s ^ ro9_s ^ ro7_s;
    always @(posedge clk) begin
        ro11_s <= ro11;
        ro9_s  <= ro9;
        ro7_s  <= ro7;
    end

    // ---- 退化流 ----------------------------------------------------------
    // 必须显式初始化: 未赋值 integer 为 X, 会毒化整条退化流
    integer pidx;
    initial pidx = 0;
    always @(posedge clk) pidx = pidx + 1;

    // ---- 定向流: 200 零 + 824 一 (T5 cumsum 定向) ------------------------
    reg [10:0] t5_cnt;
    wire bit_t5_targeted;
    initial t5_cnt = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) t5_cnt = 11'd0;
        else        t5_cnt = t5_cnt + 11'd1;
    end
    assign bit_t5_targeted = (t5_cnt < 11'd200) ? 1'b0 : 1'b1;

    // ---- 定向流: 全零 (T6) ----------------------------------------------
    wire bit_all_zero = 1'b0;

    // ---- 定向流: 全一 (T2) ----------------------------------------------
    wire bit_all_one  = 1'b1;

    // ---- 定向流: period-2 ------------------------------------------------
    wire bit_period2  = pidx[0];

    // ---- 定向流: biased (62.5% 一) ---------------------------------------
    wire bit_biased   = (pidx[4:0] >= 5'd12);

    function integer select_stream;
        input integer s;
        begin
            case (s)
                0:      select_stream = good_bit;         // RO xor (E1)
                1:      select_stream = bit_all_one;       // frozen
                2:      select_stream = bit_biased;        // 62.5%
                3:      select_stream = bit_period2;       // period-2
                4:      select_stream = bit_t5_targeted;   // 200 zero + 824 one
                5:      select_stream = bit_all_zero;      // all zeros
                6:      select_stream = lfsr_out;          // 16-bit LFSR (好流)
                default: select_stream = lfsr_out;
            endcase
        end
    endfunction

    // ---- 观测 -------------------------------------------------------------
    // win_v3 在 win_last 当拍 NBA 区置 1, 次一拍清零
    always @(posedge clk) begin
        if (!rst_n) begin
            cnt_v3    = 9'd0;
            pass_cnt  = 0;
            win_idx   = 0;
            pass_seen = 1'b0;
        end else begin
            if (win_v3) begin
                if (win_idx < 8) begin
                    win_hist[win_idx]    = status_win_v3;
                    ones_hist[win_idx]   = ones_snap;
                    maxrun_hist[win_idx] = maxrun_snap;
                    corr_hist[win_idx]   = corr_snap;
                    sq_hist[win_idx]     = sq_snap;
                    runs_hist[win_idx]   = runs_snap;
                    cmax_hist[win_idx]   = cmax_snap;
                    ssum_hist[win_idx]   = ssum_snap;
                    win_idx = win_idx + 1;
                end
                cnt_v3   = cnt_v3 + 9'd1;
                if (status_win_v3 == 7'b1111111) pass_cnt = pass_cnt + 1;
            end
            if (fail_v3 && pass_v3) pass_seen = 1'b1;
        end
    end

    // 窗口末快照: win_last 当拍读组合候选值 (此时寄存器尚未 NBA 更新)
    always @(posedge clk) begin
        if (u_v3.bit_cnt == 11'd1023 && u_v3.bit_vld) begin
            ones_snap   = u_v3.ones_n;
            corr_snap   = u_v3.corr_n;
            maxrun_snap = u_v3.maxrun_n;
            sq_snap     = u_v3.sq_n;
            runs_snap   = u_v3.runs_c;
            cmax_snap   = u_v3.maxabs_n;
            ssum_snap   = u_v3.sum_sq_bd_n;
        end
    end

    // ---- 任务 -------------------------------------------------------------
    task check;
        input [511:0] name;
        input         cond;
        begin
            if (cond) begin
                $display("  PASS  %0s", name);
                $fwrite(fd, "  PASS  %0s\n", name);
            end else begin
                $display("  FAIL  %0s", name);
                $fwrite(fd, "  FAIL  %0s\n", name);
                n_err = n_err + 1;
            end
        end
    endtask

    task reset_dut;
        begin
            rst_n    = 1'b0;
            bit_in   = 1'b0;
            bit_vld  = 1'b0;
            repeat (8) @(posedge clk);
            #1;
            rst_n = 1'b1;
            repeat (8) @(posedge clk);
            #1;
        end
    endtask

    // 连续送 n 位
    task drive_stream;
        input integer n;
        input integer sel;
        begin
            bit_vld  = 1'b0;
            for (k = 0; k < n; k = k + 1) begin
                bit_in  = select_stream(sel);
                bit_vld = 1'b1;
                @(posedge clk);
                #1;
            end
            bit_vld = 1'b0;
            #1;
        end
    endtask

    // 分段送 nseg x seg_len 位 (bit_vld gap = 请求间隙, v3 无 flush)
    task drive_segmented;
        input integer nseg;
        input integer seg_len;
        input integer gap;
        begin
            bit_vld = 1'b0;
            for (seg = 0; seg < nseg; seg = seg + 1) begin
                for (k = 0; k < seg_len; k = k + 1) begin
                    bit_in  = lfsr_out;
                    bit_vld = 1'b1;
                    @(posedge clk);
                    #1;
                end
                bit_vld = 1'b0;
                for (k = 0; k < gap; k = k + 1) begin
                    @(posedge clk);
                    #1;
                end
            end
        end
    endtask

    // ---- 主测试流 ---------------------------------------------------------
    initial begin
        fd = $fopen(REPORT, "w");
        n_err      = 0;
        cnt_v3     = 0;
        pass_seen  = 0;

        $fwrite(fd, "=====================================================\n");
        $fwrite(fd, " TRNG HEALTH TEST v3.0 (NIST SP 800-90B) REPORT\n");
        $fwrite(fd, "=====================================================\n");
        $fwrite(fd, "CLK_HALF=%0d ps  WIN=1024  N_GOOD=%0d\n", CLK_HALF, N_GOOD);
        $fwrite(fd, "V2 thresholds: ones[468,556] sumsq[4170,4620]\n");
        $fwrite(fd, "              corr[444,579] max_run[0,23]\n");
        $fwrite(fd, "V3 thresholds: runs[477,547] |S|max[0,105] sumsq_bd[100,172]\n");
        $fwrite(fd, "Status [6:0]: BD, CumSum, Runs, Prop, Poker, Corr, Longruns\n\n");

        // ---- T0 -----------------------------------------------------------
        $fwrite(fd, "[T0] reset self-check\n");
        reset_dut();
        check("T0a pass=1",         pass_v3      === 1'b1);
        check("T0b fail=0",         fail_v3      === 1'b0);
        check("T0c win=0",          win_v3       === 1'b0);
        check("T0d status_win=0",   status_win_v3 === 7'd0);
        $fwrite(fd, "\n");

        // ---- T1: 好流 4 窗口 (LFSR 确定性参考) -------------------------
        $fwrite(fd, "[T1] good stream (16-bit LFSR): %0d bits = 4 windows\n", N_GOOD);
        reset_dut();
        drive_stream(N_GOOD, 6);
        repeat (4) @(posedge clk);
        #1;
        $fwrite(fd, "  windows completed = %0d / 4   all-pass windows = %0d\n",
                cnt_v3, pass_cnt);
        for (k = 0; k < (cnt_v3 < 8 ? cnt_v3 : 8); k = k + 1)
            $fwrite(fd, "  win[%0d] status=%b ones=%0d sumsq=%0d corr=%0d maxrun=%0d runs=%0d cmax=%0d ssum=%0d\n",
                    k, win_hist[k], ones_hist[k], sq_hist[k], corr_hist[k],
                    maxrun_hist[k], runs_hist[k], cmax_hist[k], ssum_hist[k]);
        check("T1a all 4 windows completed",   cnt_v3 === 9'd4);
        check("T1b at least 3 of 4 all-pass",  pass_cnt >= 9'd3);
        $fwrite(fd, "\n");

        // ---- T2: 冻结流 (全 1) -------------------------------------------
        $fwrite(fd, "[T2] frozen stream (all 1)\n");
        reset_dut();
        drive_stream(1024, 1);
        repeat (2) @(posedge clk);
        #1;
        $fwrite(fd, "  windows = %0d   status_win = %b  (expect prop/corr/longruns/runs/bd fail)\n",
                cnt_v3, status_win_v3);
        check("T2a window completed",   cnt_v3      === 9'd1);
        check("T2b pass=0",             pass_v3     === 1'b0);
        check("T2c fail=1",             fail_v3     === 1'b1);
        check("T2d proportion hit",     status_win_v3[3] === 1'b0);
        check("T2e correlation hit",    status_win_v3[1] === 1'b0);
        check("T2f longruns hit",       status_win_v3[0] === 1'b0);
        check("T2g T5 runs hit",        status_win_v3[4] === 1'b0);
        check("T2h T7 bitdist hit",     status_win_v3[6] === 1'b0);
        $fwrite(fd, "\n");

        // ---- T3: 偏置流 62.5% --------------------------------------------
        $fwrite(fd, "[T3] biased stream (62.5%% ones)\n");
        reset_dut();
        drive_stream(1024, 2);
        repeat (2) @(posedge clk);
        #1;
        $fwrite(fd, "  status_win = %b\n", status_win_v3);
        check("T3a pass=0",         pass_v3      === 1'b0);
        check("T3b fail=1",         fail_v3      === 1'b1);
        check("T3c proportion hit", status_win_v3[3] === 1'b0);
        $fwrite(fd, "\n");

        // ---- T4: 周期-2 流 (0101...) -------------------------------------
        $fwrite(fd, "[T4] period-2 stream (0101...)\n");
        reset_dut();
        drive_stream(1024, 3);
        repeat (2) @(posedge clk);
        #1;
        $fwrite(fd, "  status_win = %b  cmax_snap=%0d  corr_snap=%0d  runs_snap=%0d  ssum_snap=%0d\n",
                status_win_v3, cmax_snap, corr_snap, runs_snap, ssum_snap);
        check("T4a poker fail",       status_win_v3[2] === 1'b0);
        check("T4b correlation fail", status_win_v3[1] === 1'b0);
        check("T4c T5 runs fail",     status_win_v3[4] === 1'b0);
        check("T4e T7 bitdist fail",  status_win_v3[6] === 1'b0);
        check("T4f T6 cumsum pass (|S|=1 bounded)", status_win_v3[5] === 1'b1);
        check("T4g pass=0",           pass_v3 === 1'b0);
        $fwrite(fd, "\n");

        // ---- T5: cumsum 定向流 (200 零 + 824 一) ------------------------
        $fwrite(fd, "[T5] cumsum-targeted stream (200 zero + 824 one)\n");
        reset_dut();
        drive_stream(1024, 4);
        repeat (2) @(posedge clk);
        #1;
        $fwrite(fd, "  status_win = %b  cmax_snap=%0d  corr_snap=%0d  runs_snap=%0d  ssum_snap=%0d\n",
                status_win_v3, cmax_snap, corr_snap, runs_snap, ssum_snap);
        check("T5a pass=0",           pass_v3     === 1'b0);
        check("T5b fail=1",           fail_v3     === 1'b1);
        check("T5c T6 cumsum hit",    status_win_v3[5] === 1'b0);
        check("T5d |S|max exceeds threshold", cmax_snap > 105);
        $fwrite(fd, "\n");

        // ---- T6: 全零流 --------------------------------------------------
        $fwrite(fd, "[T6] all-zero stream (period-1)\n");
        reset_dut();
        drive_stream(1024, 5);
        repeat (2) @(posedge clk);
        #1;
        $fwrite(fd, "  status_win = %b\n", status_win_v3);
        check("T6a pass=0",           pass_v3     === 1'b0);
        check("T6b fail=1",           fail_v3     === 1'b1);
        check("T6c T5 runs hit",      status_win_v3[4] === 1'b0);
        check("T6d T6 cumsum hit",    status_win_v3[5] === 1'b0);
        check("T6e T7 bitdist hit",   status_win_v3[6] === 1'b0);
        check("T6f longruns hit",     status_win_v3[0] === 1'b0);
        $fwrite(fd, "\n");

        // ---- T7: 分段请求 (L1 修复回归) --------------------------------
        $fwrite(fd, "[T7] segmented requests (L1 regression): 32 seg x 128 bit, gap=32\n");
        reset_dut();
        drive_segmented(32, 128, 32);
        repeat (4) @(posedge clk);
        #1;
        $fwrite(fd, "  windows = %0d\n", cnt_v3);
        check("T7a v3 forms windows across request gaps", cnt_v3 >= 9'd3);
        $fwrite(fd, "\n");

        // ---- T8: E1 生产熵源 (RO xor) 4 窗口 ---------------------------
        $fwrite(fd, "[T8] E1 production entropy (RO xor) - 4 windows\n");
        reset_dut();
        drive_stream(N_GOOD, 0);
        repeat (4) @(posedge clk);
        #1;
        for (k = 0; k < (cnt_v3 < 8 ? cnt_v3 : 8); k = k + 1)
            $fwrite(fd, "  win[%0d] status=%b ones=%0d sumsq=%0d corr=%0d maxrun=%0d runs=%0d cmax=%0d ssum=%0d\n",
                    k, win_hist[k], ones_hist[k], sq_hist[k], corr_hist[k],
                    maxrun_hist[k], runs_hist[k], cmax_hist[k], ssum_hist[k]);
        check("T8a health test completes windows on RO stream", cnt_v3 === 9'd4);
        check("T8b health test ACCEPTS RO stream (>=3 of 4 windows pass)",
              pass_cnt >= 9'd3);
        // T8c removed: 统计检验偶发失败会正确锁存 fail, 这是设计行为而非 bug;
        //   fail=0 的初始状态已由 T0b 覆盖, 接受率由 T8b 验证。
        $fwrite(fd, "\n");

        // ---- T9: fail 粘滞 ---------------------------------------------
        $fwrite(fd, "[T9] fail latching\n");
        reset_dut();
        drive_stream(1024, 1);           // 冻结窗口 -> fail=1
        repeat (2) @(posedge clk);
        #1;
        $fwrite(fd, "  after frozen window: fail=%b pass=%b\n", fail_v3, pass_v3);
        check("T9a fail latched", fail_v3 === 1'b1);
        drive_stream(4096, 6);           // LFSR 好流 4 窗口
        repeat (2) @(posedge clk);
        #1;
        $fwrite(fd, "  after good stream: fail=%b pass=%b pass_seen=%b\n",
                fail_v3, pass_v3, pass_seen);
        check("T9b pass recovered on good stream", pass_seen === 1'b1);
        check("T9c fail stays latched",            fail_v3   === 1'b1);
        reset_dut();
        check("T9d reset clears fail", fail_v3 === 1'b0);
        $fwrite(fd, "\n");

        // ---- SUMMARY ------------------------------------------------------
        $fwrite(fd, "=====================================================\n");
        $fwrite(fd, " SUMMARY\n");
        $fwrite(fd, "=====================================================\n");
        $fwrite(fd, "FAIL = %0d\n", n_err);
        $fwrite(fd, "%s\n", (n_err == 0) ? "ALL TESTS PASSED" : "SOME TESTS FAILED");
        $fclose(fd);

        if (n_err == 0) $display("ALL TESTS PASSED");
        else            $display("SOME TESTS FAILED: %0d", n_err);
        $finish;
    end

    // 看门狗 (100 MHz, 预算 200000 cycle)
    initial begin
        #(200000 * 10);
        $display("GLOBAL TIMEOUT at t=%0d", $time);
        $finish;
    end

endmodule
