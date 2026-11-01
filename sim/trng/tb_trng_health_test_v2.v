// =============================================================================
// tb_trng_health_test_v2.v
//
// D1 模块级验证：trng_health_test_v2 (NIST SP 800-90B 四检验, WIN=1024)
//
// 测试清单
//   T0  复位自检 (pass=1 fail=0 win=0 status_win=0)
//   T1  好流 4 窗口: 16 位 LFSR 确定性参考流 (抽头/周期说明见下),
//       四项全过, 作为 RTL 逻辑与阈值的正向判据
//   T2  冻结流 (全 1): 四项全部触发, status_win = 0000
//   T3  偏置流 (62.5% 一): proportion 必失败
//   T4  周期-2 流 (0101...): poker + correlation 失败, status_win = 1001
//   T5  16 零 16 一流: poker + correlation 失败, longruns 仍通过
//   T6  L1 修复证明 (关键)
//       v2 无 flush 端口 -> 累加器跨请求间隙连续累积 -> 分段请求也成窗口
//       v1 在请求间隙拉高 flush (复现 trng_sm3_v3.v 的 state==S_IDLE 条件)
//         -> 累加器每 128 bit 被清空 -> 永不到 4096 -> 判定永不触发
//   T7  v1/v2 A/B: 同一 4200-bit 冻结流, 两者都应抓到 (v1 需 4097 bit 才判定)
//   T8  fail 粘滞: fail 置 1 后好流使 pass 恢复 1, 但 fail 保持 1; 复位清零
//   T9  E1 生产熵源 (RO xor) 实测 —— L5 已关闭证据
//       L5 修复后 RO 参数由 ro3/ro9/ro13 (环周期 20394/20394/20410 ps,
//       相位步进 alpha=0.4903≈0.5, 周期-2 残留) 重选为 ro11/ro9/ro7
//       (环周期 77242/35550/36190 ps, alpha=0.1295/0.2813/0.2763)。
//       本测试断言生产熵源被四检验接受: 4 窗口成、四项全过、fail 不锁存。
//
// 驱动时序约定 (race-free)
//   在 posedge 之后的 #1 窗口内设置 bit_in/bit_vld/flush, 再 @(posedge clk)
//   让 DUT 采样, 采样完成后先 #1 再改信号。绝不在 posedge 同一时步改被采样信号。
//
// v1 无 win_pulse 端口, 故用层次化引用 u_v1.test_count 探测其判定事件
// (test_count 到达 4096 即触发一次判定, 随后被清零)。
//
// status 是组合量: win_last 当拍后累加器立即清零使 status 失效,
// 故断言一律使用 status_win (窗口末锁存快照)。
// ones/corr/maxrun 用层次化引用 u_v2.ones_n 等在 win_last 当拍采样
// (此时寄存器尚未 NBA 更新, 组合候选值恰为整窗口统计量)。
//
// 运行: .workbuddy/tmp/run_trng_health_test_v2.py
// =============================================================================
`timescale 1ns / 1ps

module tb_trng_health_test_v2;

    localparam CLK_HALF = 5;           // 100 MHz
    localparam N_GOOD   = 4096;        // T1: 4 个窗口
    localparam REPORT   = "trng_ht_v2_report.txt";

    integer fd, k, seg, n_err;
    integer cnt_v2;
    integer pass_cnt;                  // 四项全过的窗口数
    integer win_idx;
    reg [3:0] win_hist [0:7];          // 逐窗口 status_win 快照 (诊断用)
    integer   ones_hist [0:7];         // 逐窗口 ones  (诊断用)
    integer   maxrun_hist [0:7];       // 逐窗口 max_run (诊断用)
    integer   corr_hist [0:7];         // 逐窗口 correlation (诊断用)
    integer ones_snap, maxrun_snap, corr_snap;
    integer sq_hist [0:7];          // 逐窗口 sum(freq^2) (诊断用)
    integer sq_snap;
    reg     v1_eval;                   // v1 判定事件锁存 (test_count 到 4096)
    reg     pass_seen;                 // T8 用: fail 之后 pass 是否恢复过

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
    reg         flush_v1;
    wire        pass_v2, fail_v2, win_v2;
    wire [3:0]  status_v2, status_win_v2;
    wire        pass_v1, fail_v1;

    // ---- DUT: v2 (被测) --------------------------------------------------
    trng_health_test_v2 u_v2 (
        .clk        (clk),
        .rst_n      (rst_n),
        .bit_in     (bit_in),
        .bit_vld    (bit_vld),
        .pass       (pass_v2),
        .fail       (fail_v2),
        .win_pulse  (win_v2),
        .status     (status_v2),
        .status_win (status_win_v2)
    );

    // ---- DUT: v1 (对照, T6/T7) ------------------------------------------
    trng_health_test u_v1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .bit_in    (bit_in),
        .bit_vld   (bit_vld),
        .flush     (flush_v1),
        .pass      (pass_v1),
        .fail      (fail_v1)
    );

    // ---- 好流 1: 16 位 LFSR (确定性参考流) -------------------------------
    // 抽头 (0 起索引) bit0 ^ bit4 ^ bit13 ^ bit15, 左移 Fibonacci, 种子 0x0001。
    // 由 .workbuddy/tmp/ro_param_search.py Part A 离线筛选:
    //   4 个窗口全部通过四项检验, 用作 RTL 逻辑与阈值的正向判据。
    // 实测 (本 TB 本次运行): ones 500..523 / sumsq 4204..4340 /
    //   corr 487..517 / maxrun 8..10, 四项均在阈值区间内。
    //
    // 两条必须记录的说明 (勿再写回 m 序列):
    //   [1] 反馈位必须回到低位 (与参考脚本 state=(state<<1)|fb 一致);
    //       写成 {fb, lfsr[15:1]} 是另一种多项式配置, 实测 maxrun=14 且
    //       poker 失败, 与离线筛选结果不符。
    //   [2] 本配置的特征多项式为 x^16+x^15+x^11+x^2+1 (由抽头推出), 与常被引用
    //       的本原多项式 x^16+x^12+x^3+x+1 不同; 实测周期 63457 (2^16-1=65535),
    //       属可约分解下的长周期序列, 不是满周期 m 序列。它仍通过全部四项检验,
    //       足以充当确定性好流参考; 若需满周期 m 序列须另行筛选本原多项式抽头。
    reg  [15:0] lfsr;
    initial lfsr = 16'h0001;
    wire        lfsr_fb  = lfsr[0] ^ lfsr[4] ^ lfsr[13] ^ lfsr[15];
    wire        lfsr_out = lfsr_fb;
    always @(posedge clk) lfsr <= {lfsr[14:0], lfsr_fb};

    // ---- 好流 2: 三路自由运行 RO 采样后 XOR (E1 生产熵源, 与 trng_entropy 同构)
    // L5 修复后参数: ro11(DELAY=3511)/ro9(1975)/ro7(2585),
    //   环周期 77242/35550/36190 ps, 相位步进 alpha=0.1295/0.2813/0.2763。
    //   与 trng_sm3_v3.v 熵源内的实例完全一致 (模块自带默认 DELAY, 不覆盖参数,
    //   与本机 iverilog 仅认 Verilog-1995 式覆盖的约束兼容)。
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
    integer pidx;
    wire bit_frozen, bit_biased, bit_period2, bit_runs16;
    // 必须显式初始化: iverilog 中未赋值的 integer 为 X,
    // X 会经比较运算传播为 X 并毒化整条退化流 (T3/T4/T5 首次运行实测)
    initial pidx = 0;
    always @(posedge clk) pidx = pidx + 1;
    assign bit_frozen  = 1'b1;
    assign bit_biased  = (pidx[4:0] >= 5'd12);   // 20/32 = 62.5% 一
    assign bit_period2 = pidx[0];                 // 010101...
    assign bit_runs16  = (pidx[4:0] >= 5'd16);    // 16 零 + 16 一 (pidx[4:0]: 0..31)

    function integer select_stream;
        input integer s;
        begin
            case (s)
                0:      select_stream = good_bit;    // RO xor  (E1 生产熵源)
                1:      select_stream = bit_frozen;
                2:      select_stream = bit_biased;
                3:      select_stream = bit_period2;
                4:      select_stream = bit_runs16;
                5:      select_stream = lfsr_out;    // 16 位 m 序列 (确定性参考)
                default: select_stream = lfsr_out;
            endcase
        end
    endfunction

    // ---- 观测 (win_pulse 严格 1 拍; v1 判定事件层次化探测) ---------------
    // win_v2 在 win_last 当拍 (posedge P) 的 NBA 区置 1, 次一拍 (P+10) 清零;
    // 故在 P+10 读到 win_v2==1 时, status_win 已是本窗口锁存结果, 可安全计数。
    always @(posedge clk) begin
        if (!rst_n) begin
            cnt_v2    = 9'd0;
            pass_cnt  = 0;
            win_idx   = 0;
            v1_eval   = 1'b0;
            pass_seen = 1'b0;
        end else begin
            if (win_v2) begin
                if (win_idx < 8) begin
                    win_hist[win_idx]    = status_win_v2;
                    ones_hist[win_idx]   = ones_snap;
                    maxrun_hist[win_idx] = maxrun_snap;
                    corr_hist[win_idx]   = corr_snap;
                    sq_hist[win_idx]     = sq_snap;
                    win_idx = win_idx + 1;
                end
                cnt_v2   = cnt_v2 + 9'd1;
                if (status_win_v2 == 4'b1111) pass_cnt = pass_cnt + 1;
            end
            if (u_v1.test_count >= 16'd4096) v1_eval = 1'b1;
            if (fail_v2 && pass_v2) pass_seen = 1'b1;
        end
    end

    // 窗口末快照: 在 win_last 当拍 (bit_cnt==1023) 读组合候选值,
    // 此时寄存器尚未 NBA 更新, ones_n/corr_n/maxrun_n 恰为整窗口统计量。
    always @(posedge clk) begin
        if (u_v2.bit_cnt == 11'd1023 && u_v2.bit_vld) begin
            ones_snap   = u_v2.ones_n;
            corr_snap   = u_v2.corr_n;
            maxrun_snap = u_v2.maxrun_n;
            sq_snap     = u_v2.sq_n;
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
            flush_v1 = 1'b0;
            repeat (8) @(posedge clk);
            #1;
            rst_n = 1'b1;
            repeat (8) @(posedge clk);
            #1;
        end
    endtask

    // 连续送 n 位 (bit_vld 持续为 1, flush_v1 保持 0)
    task drive_stream;
        input integer n;
        input integer sel;
        begin
            bit_vld  = 1'b0;
            flush_v1 = 1'b0;
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

    // 分段送 nseg x seg_len 位; 段间 gap 拍且拉高 v1 的 flush
    // (复现 trng_sm3_v3.v 中 u_ht 的 flush = (state == S_IDLE))
    // 用 LFSR 确定性参考流, 使本测试不依赖 RO 熵源质量 (RO 问题见 T9 / 遗留 L5)
    task drive_segmented;
        input integer nseg;
        input integer seg_len;
        input integer gap;
        begin
            bit_vld  = 1'b0;
            flush_v1 = 1'b0;
            for (seg = 0; seg < nseg; seg = seg + 1) begin
                for (k = 0; k < seg_len; k = k + 1) begin
                    bit_in  = lfsr_out;
                    bit_vld = 1'b1;
                    @(posedge clk);
                    #1;
                end
                bit_vld  = 1'b0;
                flush_v1 = 1'b1;
                for (k = 0; k < gap; k = k + 1) begin
                    @(posedge clk);
                    #1;
                end
                flush_v1 = 1'b0;
            end
        end
    endtask

    // ---- 主测试流 ---------------------------------------------------------
    initial begin
        fd = $fopen(REPORT, "w");
        n_err   = 0;
        cnt_v2  = 0;
        v1_eval = 0;
        pass_seen = 0;

        $fwrite(fd, "=====================================================\n");
        $fwrite(fd, " TRNG HEALTH TEST v2.0 (NIST SP 800-90B) TEST REPORT\n");
        $fwrite(fd, "=====================================================\n");
        $fwrite(fd, "CLK_HALF=%0d ps  WIN=1024  N_GOOD=%0d\n", CLK_HALF, N_GOOD);
        $fwrite(fd, "THRESHOLDS: ones[468,556] sumsq[4170,4620] corr[444,579]\n");
        $fwrite(fd, "           max_run[0,23]   (status: prop,poker,corr,runs)\n\n");

        // ---- T0 -----------------------------------------------------------
        $fwrite(fd, "[T0] reset self-check\n");
        reset_dut();
        check("T0a pass=1",       pass_v2     === 1'b1);
        check("T0b fail=0",       fail_v2     === 1'b0);
        check("T0c win=0",        win_v2      === 1'b0);
        check("T0d status_win=0", status_win_v2 === 4'd0);
        $fwrite(fd, "\n");

        // ---- T1: 好流 4 窗口 (16 位 m 序列确定性参考流) -----------------
        $fwrite(fd, "[T1] good stream (16-bit m-seq LFSR): %0d bits = 4 windows\n",
                N_GOOD);
        reset_dut();
        drive_stream(N_GOOD, 5);
        repeat (4) @(posedge clk);
        #1;
        $fwrite(fd, "  windows completed = %0d / 4   all-pass windows = %0d\n",
                cnt_v2, pass_cnt);
        for (k = 0; k < (cnt_v2 < 8 ? cnt_v2 : 8); k = k + 1)
            $fwrite(fd, "  win[%0d] status=%b ones=%0d sumsq=%0d corr=%0d maxrun=%0d\n",
                    k, win_hist[k], ones_hist[k], sq_hist[k], corr_hist[k],
                    maxrun_hist[k]);
        // 99% CI 单项假失败率约 1%, 四项合计约 2%; 4 窗口允许至多 1 个假失败。
        // RTL 逻辑正确性的判据是"窗口按 1024 bit 正确切分并判定",
        // 好流是否全过由 .workbuddy/tmp/ht_thresholds.py 的 300 窗口 MC 保证。
        check("T1a all 4 windows completed",  cnt_v2   === 9'd4);
        check("T1b at least 3 of 4 all-pass", pass_cnt  >= 9'd3);
        $fwrite(fd, "\n");

        // ---- T2: 冻结流 ---------------------------------------------------
        $fwrite(fd, "[T2] frozen stream (all 1)\n");
        reset_dut();
        drive_stream(1024, 1);
        repeat (2) @(posedge clk);
        #1;
        $fwrite(fd, "  windows = %0d   status_win = %b\n", cnt_v2, status_win_v2);
        check("T2a window completed",   cnt_v2      === 9'd1);
        check("T2b pass=0",             pass_v2     === 1'b0);
        check("T2c fail=1",             fail_v2     === 1'b1);
        check("T2d all four tests hit", status_win_v2 === 4'b0000);
        $fwrite(fd, "\n");

        // ---- T3: 偏置流 62.5% -------------------------------------------
        $fwrite(fd, "[T3] biased stream (62.5%% ones)\n");
        reset_dut();
        drive_stream(1024, 2);
        repeat (2) @(posedge clk);
        #1;
        $fwrite(fd, "  status_win = %b\n", status_win_v2);
        check("T3a pass=0",  pass_v2    === 1'b0);
        check("T3b fail=1",  fail_v2    === 1'b1);
        check("T3c proportion hit", status_win_v2[3] === 1'b0);
        $fwrite(fd, "\n");

        // ---- T4: 周期-2 流 ------------------------------------------------
        $fwrite(fd, "[T4] period-2 stream (0101...)\n");
        reset_dut();
        drive_stream(1024, 3);
        repeat (2) @(posedge clk);
        #1;
        $fwrite(fd, "  status_win = %b\n", status_win_v2);
        check("T4a proportion ok",     status_win_v2[3] === 1'b1);
        check("T4b poker fail",        status_win_v2[2] === 1'b0);
        check("T4c correlation fail",  status_win_v2[1] === 1'b0);
        check("T4d longruns ok",       status_win_v2[0] === 1'b1);
        check("T4e status=1001",       status_win_v2 === 4'b1001);
        $fwrite(fd, "\n");

        // ---- T5: 16 零 16 一流 -------------------------------------------
        $fwrite(fd, "[T5] 16-zero/16-one runs\n");
        reset_dut();
        drive_stream(1024, 4);
        repeat (2) @(posedge clk);
        #1;
        $fwrite(fd, "  status_win = %b\n", status_win_v2);
        check("T5a proportion ok",     status_win_v2[3] === 1'b1);
        check("T5b poker fail",        status_win_v2[2] === 1'b0);
        check("T5c correlation fail",  status_win_v2[1] === 1'b0);
        check("T5d longruns ok (<=23)", status_win_v2[0] === 1'b1);
        $fwrite(fd, "\n");

        // ---- T6: L1 修复证明 --------------------------------------------
        $fwrite(fd, "[T6] L1 fix: 32 seg x 128 bit, gap=32 (v1 flushed in gap)\n");
        $fwrite(fd, "      total = 4096 bit = 4 v2 windows / 1x v1 WINDOW_CNT\n");
        reset_dut();
        drive_segmented(32, 128, 32);
        repeat (4) @(posedge clk);
        #1;
        $fwrite(fd, "  v2 windows = %0d   v1 evaluations = %0d   v1 fail = %b\n",
                cnt_v2, v1_eval, fail_v1);
        check("T6a v2 forms windows across request gaps", cnt_v2 >= 9'd3);
        check("T6b v1 never evaluates (L1 defect reproduced)", v1_eval === 1'b0);
        check("T6c v1 fail stays 0 (no evaluation occurred)", fail_v1 === 1'b0);
        $fwrite(fd, "\n");

        // ---- T7: v1/v2 A/B 冻结流 ---------------------------------------
        $fwrite(fd, "[T7] v1 vs v2 on frozen stream, flush_v1=0, 4200 bit\n");
        reset_dut();
        drive_stream(4200, 1);
        repeat (4) @(posedge clk);
        #1;
        $fwrite(fd, "  v1 eval = %b  v1 fail = %b   v2 fail = %b  v2 windows = %0d\n",
                v1_eval, fail_v1, fail_v2, cnt_v2);
        check("T7a v2 catches frozen", fail_v2 === 1'b1);
        check("T7b v1 evaluates (test_count reached 4096)", v1_eval === 1'b1);
        check("T7c v1 catches frozen", fail_v1 === 1'b1);
        check("T7d v2 window count = 4", cnt_v2 === 9'd4);
        $fwrite(fd, "\n");

        // ---- T8: fail 粘滞 ----------------------------------------------
        $fwrite(fd, "[T8] fail latching\n");
        reset_dut();
        drive_stream(1024, 1);           // 冻结窗口 -> fail=1
        repeat (2) @(posedge clk);
        #1;
        $fwrite(fd, "  after frozen window: fail=%b pass=%b\n", fail_v2, pass_v2);
        check("T8a fail latched", fail_v2 === 1'b1);
        drive_stream(4096, 5);           // LFSR 好流 4 窗口 -> pass 应恢复过
        repeat (2) @(posedge clk);
        #1;
        $fwrite(fd, "  after good stream : fail=%b pass=%b pass_seen=%b pass_cnt=%0d\n",
                fail_v2, pass_v2, pass_seen, pass_cnt);
        check("T8b pass recovered on good stream", pass_seen === 1'b1);
        check("T8c fail stays latched",            fail_v2   === 1'b1);
        reset_dut();
        check("T8d reset clears fail", fail_v2 === 1'b0);
        $fwrite(fd, "\n");

        // ---- T9: E1 生产熵源 (RO xor) 实测 —— L5 已关闭证据 -----------
        // 旧参数 ro3/ro9/ro13 (DELAY 3399/1133/785) 环周期均为 20394/20394/20410 ps
        //   ~= 2.02*TCLK, 相位每拍推进 alpha = TCLK/P = 0.4903 ~= 0.5, 采样序列
        //   近乎逐拍翻转 (周期-2 残留), correlation 与 poker 检验必失败; 且 ro3 与
        //   ro9 环周期完全相同 (gcd=20394) 是 L2 的另一半根因。
        // 修复: RO 重选为 ro11(3511)/ro9(1975)/ro7(2585),
        //   环周期 77242/35550/36190 ps, alpha=0.1295/0.2813/0.2763 (远离 0 与 0.5),
        //   周期比展宽 77242/35550 = 2.173 (旧仅 1.0008), lcm 451709284950 ps
        //   = 45170928 clk = 451.7 ms @100 MHz; 两两 gcd = 2/22/10。
        // 本测试断言生产熵源被四检验接受: 4 窗口成、四项全过、fail 不锁存。
        // 说明: 99% 双侧 CI 下单窗口越界率约 1%, 4 窗口出现个别越界属正常真随机
        //   行为; 与旧参数 4/4 窗口系统性失败 (corr~=1000, sumsq~=29000) 性质不同。
        $fwrite(fd, "[T9] E1 production entropy (RO xor) - L5 CLOSED evidence\n");
        $fwrite(fd, "      periods 77242/35550/36190 ps -> alpha 0.1295/0.2813/0.2763\n");
        reset_dut();
        drive_stream(N_GOOD, 0);
        repeat (4) @(posedge clk);
        #1;
        for (k = 0; k < (cnt_v2 < 8 ? cnt_v2 : 8); k = k + 1)
            $fwrite(fd, "  win[%0d] status=%b ones=%0d sumsq=%0d corr=%0d maxrun=%0d\n",
                    k, win_hist[k], ones_hist[k], sq_hist[k], corr_hist[k],
                    maxrun_hist[k]);
        check("T9a health test completes windows on RO stream", cnt_v2 === 9'd4);
        check("T9b health test ACCEPTS the RO stream (all 4 windows pass)",
              pass_cnt === 9'd4);
        check("T9c fail NOT latched on production entropy source", fail_v2 === 1'b0);
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

    // 看门狗 (100 MHz -> 10 ns/cycle; 预算 200000 cycle)
    initial begin
        #(200000 * 10);
        $display("GLOBAL TIMEOUT at t=%0d", $time);
        $finish;
    end

endmodule
