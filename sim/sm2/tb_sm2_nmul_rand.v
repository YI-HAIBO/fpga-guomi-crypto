// =============================================================================
// 模块名称 : tb_sm2_nmul_rand
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 阶段     : Phase 0.5.3  路线图创新项 A2
// 版本     : v1.0
// 视角     : sim-verifier
// 覆盖     : sm2_nmul_rand (RANDOMIZE=0 基线等价性 / RANDOMIZE=1 硬化 /
//            M1 无分支掩码加 / M2 随机冗余轮次 / M3 空闲期清零)
//
// 对拍基准 (三重):
//   1. nm_vec_exp(i)  —— .vh 中的期望值, 由 Python 参考模型计算
//   2. u_base         —— sm2_nmul_rand #(.RANDOMIZE(0)), 结构等价 sm2_nmul v1.1
//   3. u_rnd          —— sm2_nmul_rand #(.RANDOMIZE(1)), 本次被测模块
// 期望向量来源: .workbuddy/tmp/nmul_rand_ref.py (锚定线 = tb_sm2_sign.v T2 段
//            已签核期望值, Python 复算 5/5 一致)
//
// 测试组
//   T1  u_rnd  vs 期望向量 (14 组)
//   T2  u_base vs 期望向量 (14 组)  —— RANDOMIZE=0 与已签核 v1.1 结果一致
//   T3  u_rnd  vs u_base  (14 组)  —— 随机化不改变数学结果
//   T4  u_base 延迟恒为 258 (14 组) —— 与 v1.1 逐拍等价
//   T5  u_rnd 延迟 - 258 == nop_cnt (14 组) —— 冗余轮次精确可计
//   T6  M3 空闲期清零 + M2 stall 全部落位 (nop_left == 0)
//   T7  随机源有效性: 16 种子 -> nop_cnt / 末次 stall 落点分布
//   T8  同种子确定性复现
//   T9  seed == 0 兜底种子路径
//   T10 NMIN_EXTRA 参数化 (u_rnd2, 下界 8)
// =============================================================================

`timescale 1ns / 1ps

module tb_sm2_nmul_rand;

    // 期望向量: 标量 localparam + 按索引 case 函数 (Verilog-2005 合规)
    `include "nmul_rand_vectors.vh"

    reg clk = 1'b0;
    always #5 clk = ~clk;               // 100 MHz

    reg rst_n = 1'b0;
    initial begin
        #23; rst_n = 1'b1;
    end

    // =========================================================================
    // 种子生成 (函数内可做常量边界 part-select, 规避拼接宽度推断问题)
    //   注意: 必须让全部 32 位都随 s 变化 —— LFSR 只用种子低位抽 stall 计数,
    //   低字节固定会让 nop_cnt 恒等于同一值 (首轮实测已踩此坑)。
    //   且对任意 s 结果非 0 (高字节 0xa5 ^ s[23:16] 在小 s 下恒非零)。
    // =========================================================================
    function [31:0] mk_seed;
        input [31:0] s;
        begin
            // 移位折叠哈希: 低位必须随 s 变化 —— LFSR 抽 stall 计数只用
            //   lfsr_from_seed[3:0] = (seed ^ 0x00400007)[3:0], 种子低 nibble 恒定
            //   会让 nop_cnt 与首次 stall 落点全部坍缩成同一值 (分布退化成 δ 函数)。
            //   首轮实测踩过两回: 先写死 {8'hca,8'hfe,s[7:0],8'h01} 只让高 24 位变,
            //   再改成 {s[23:16],s[15:8],s[7:0],8'h01} 低字节仍是常量 8'h01^0xd9=0xd8,
            //   两次 nop_hist 都是 16 个全同值、distinct=1/16。此处改用纯位折叠,
            //   s 的全部 32 位都进入结果, 且 s 为小整数时低 nibble = s[3:0] ^ 0x9,
            //   对连续 s 互不相同。
            mk_seed = s ^ (s >> 8) ^ (s >> 16) ^ (s >> 24) ^ 32'ha5f3c7d9;
        end
    endfunction

    // =========================================================================
    // DUT-1: RANDOMIZE=0  —— 结构等价 sm2_nmul v1.1 的对照基线
    // =========================================================================
    reg          b_start;
    reg  [255:0] b_a, b_b;
    reg  [31:0]  b_seed;
    wire [255:0] b_res;
    wire         b_done;
    wire [7:0]   b_nop;

    sm2_nmul_rand #(.RANDOMIZE(0), .NMIN_EXTRA(1), .STALL_GAP(15)) u_base (
        .clk(clk), .rst_n(rst_n), .start(b_start),
        .a(b_a), .b(b_b), .rand_seed(b_seed),
        .result(b_res), .done(b_done), .nop_cnt(b_nop)
    );

    // =========================================================================
    // DUT-2: RANDOMIZE=1  —— 被测模块 (M1 + M2 + M3)
    // =========================================================================
    reg          r_start;
    reg  [255:0] r_a, r_b;
    reg  [31:0]  r_seed;
    wire [255:0] r_res;
    wire         r_done;
    wire [7:0]   r_nop;

    sm2_nmul_rand #(.RANDOMIZE(1), .NMIN_EXTRA(1), .STALL_GAP(15)) u_rnd (
        .clk(clk), .rst_n(rst_n), .start(r_start),
        .a(r_a), .b(r_b), .rand_seed(r_seed),
        .result(r_res), .done(r_done), .nop_cnt(r_nop)
    );

    // =========================================================================
    // DUT-3: RANDOMIZE=1 + NMIN_EXTRA=8 —— 参数化下界检查
    // =========================================================================
    reg          r2_start;
    reg  [255:0] r2_a, r2_b;
    reg  [31:0]  r2_seed;
    wire [255:0] r2_res;
    wire         r2_done;
    wire [7:0]   r2_nop;

    sm2_nmul_rand #(.RANDOMIZE(1), .NMIN_EXTRA(8), .STALL_GAP(15)) u_rnd2 (
        .clk(clk), .rst_n(rst_n), .start(r2_start),
        .a(r2_a), .b(r2_b), .rand_seed(r2_seed),
        .result(r2_res), .done(r2_done), .nop_cnt(r2_nop)
    );

    // =========================================================================
    // 观测: 全局周期计数 + u_rnd 首次/末次 stall 落点
    // =========================================================================
    reg [31:0] gcyc = 32'd0;
    always @(posedge clk) gcyc <= gcyc + 32'd1;

    reg [31:0] start_at  = 32'd0;
    reg [31:0] stall_at  = 32'd0;
    reg        stall_cap = 1'b0;
    always @(posedge clk) begin
        if (r_start) begin
            start_at  <= gcyc;
            stall_cap <= 1'b0;
        end else if (!stall_cap && r_nop === 8'd1) begin
            stall_at  <= gcyc;
            stall_cap <= 1'b1;
        end
    end

    // 末次 stall 落点: 仅在 nop_cnt 递增时刷新 (复位/新一轮会使其减小, 故用 ">"
    //   而非 "!=" 判定, 避免把 12 -> 0 的归零误记为一次 stall)
    reg [31:0] lstat_at  = 32'd0;
    reg [7:0]  lprev_nop = 8'd0;
    always @(posedge clk) begin
        if (r_start) begin
            lstat_at  <= gcyc;
            lprev_nop <= 8'd0;
        end else if (r_nop > lprev_nop) begin
            lstat_at  <= gcyc;
            lprev_nop <= r_nop;
        end
    end

    // =========================================================================
    // 工作变量 (全部模块级: -g2005 不支持 begin 块内声明)
    // =========================================================================
    integer          i, k;
    integer          ntest = 0, npass = 0, nfail = 0;
    integer          dn, ds, j, t;
    reg  [255:0]     va, vb, vres, vexp;
    reg  [255:0]     vacc, varg, vbgr;
    reg  [255:0]     s_res;
    reg  [31:0]      vseed;
    reg  [15:0]      vtime, base_time, s_time;
    reg  [15:0]      tcyc, tbase;
    reg  [7:0]       vnop, base_nop, vnleft, s_nop, r2_nop_v;
    reg  [255:0]     base_res;
    reg  [31:0]      vstall;    // 首次 stall 偏移 (逐向量打印用)
    reg  [31:0]      vlast;     // 末次 stall 偏移 (T7 分布度量用)
    reg  [7:0]       nop_hist [0:15];
    reg  [31:0]      stall_hist [0:15];

    // =========================================================================
    // 任务: 驱动 u_base 一次
    // =========================================================================
    task run_base;
        begin
            @(negedge clk);
            b_start = 1'b1;
            b_a = va;
            b_b = vb;
            b_seed = 32'h00000001;
            @(posedge clk); #1;
            b_start = 1'b0;
            tbase = 16'd0;
            while (b_done !== 1'b1 && tbase < 16'd4000) begin
                @(posedge clk); #1;
                tbase = tbase + 16'd1;
            end
            base_time = tbase;
            @(posedge clk); #1;
            base_res  = b_res;
            base_nop  = b_nop;
        end
    endtask

    // =========================================================================
    // 任务: 驱动 u_rnd 一次
    // =========================================================================
    task run_rnd;
        begin
            @(negedge clk);
            r_start = 1'b1;
            r_a = va;
            r_b = vb;
            r_seed = vseed;
            @(posedge clk); #1;
            r_start = 1'b0;
            tcyc = 16'd0;
            while (r_done !== 1'b1 && tcyc < 16'd4000) begin
                @(posedge clk); #1;
                tcyc = tcyc + 16'd1;
            end
            vtime = tcyc;
            @(posedge clk); #1;
            vres   = r_res;
            vnop   = r_nop;
            vnleft = u_rnd.nop_left;
            vacc   = u_rnd.acc;
            varg   = u_rnd.Areg;
            vbgr   = u_rnd.Breg;
            vstall = stall_at - start_at;
            vlast  = lstat_at - start_at;
        end
    endtask

    // =========================================================================
    // 任务: 驱动 u_rnd2 一次 (NMIN_EXTRA=8)
    // =========================================================================
    task run_rnd2;
        begin
            @(negedge clk);
            r2_start = 1'b1;
            r2_a = va;
            r2_b = vb;
            r2_seed = vseed;
            @(posedge clk); #1;
            r2_start = 1'b0;
            tcyc = 16'd0;
            while (r2_done !== 1'b1 && tcyc < 16'd4000) begin
                @(posedge clk); #1;
                tcyc = tcyc + 16'd1;
            end
            @(posedge clk); #1;
            r2_nop_v = r2_nop;
        end
    endtask

    // =========================================================================
    // 单一 initial 块: 全部测试串行
    // =========================================================================
    initial begin
        b_start = 1'b0; r_start = 1'b0; r2_start = 1'b0;
        b_a = 256'd0; b_b = 256'd0; b_seed = 32'd0;
        r_a = 256'd0; r_b = 256'd0; r_seed = 32'd0;
        r2_a = 256'd0; r2_b = 256'd0; r2_seed = 32'd0;

        // 必须等复位释放后再驱动: rst_n 在 t=23 拉高, 而首个 negedge clk 在 t=10,
        // 若不等, 第一次 start 会被复位吃掉, DUT 永远不起算 (实测 4000 拍超时)。
        @(posedge rst_n);
        @(negedge clk);

        $display("=======================================================================");
        $display("[T0] sm2_nmul_rand  A2 抗时序硬化  14 向量 x 3 基准");
        $display("     NM_NUM=%d  N=0x%064x", NM_NUM, NM_N);
        $display("=======================================================================");

        // -----------------------------------------------------------------
        // T1..T6: 14 组向量全量对拍 (每轮 base 与 rnd 各跑一次)
        // -----------------------------------------------------------------
        for (i = 0; i < NM_NUM; i = i + 1) begin
            va    = nm_vec_a(i);
            vb    = nm_vec_b(i);
            vexp  = nm_vec_exp(i);
            vseed = mk_seed(i + 200);

            run_base;
            run_rnd;

            // T1: u_rnd vs 期望向量
            ntest = ntest + 1;
            if (vres === vexp) begin
                npass = npass + 1;
            end else begin
                nfail = nfail + 1;
                $display("  [FAIL] T1[%0d] rnd=%064x exp=%064x", i, vres, vexp);
            end

            // T2: u_base vs 期望向量 (RANDOMIZE=0 == 已签核 v1.1)
            ntest = ntest + 1;
            if (base_res === vexp) begin
                npass = npass + 1;
            end else begin
                nfail = nfail + 1;
                $display("  [FAIL] T2[%0d] base=%064x exp=%064x", i, base_res, vexp);
            end

            // T3: u_rnd vs u_base (随机化不改变结果)
            ntest = ntest + 1;
            if (vres === base_res) begin
                npass = npass + 1;
            end else begin
                nfail = nfail + 1;
                $display("  [FAIL] T3[%0d] rnd=%064x base=%064x", i, vres, base_res);
            end

            // T4: u_base 延迟恒为 258 (256 步 + S_RUN 收尾 + S_OUT)
            ntest = ntest + 1;
            if (base_time == 16'd258) begin
                npass = npass + 1;
            end else begin
                nfail = nfail + 1;
                $display("  [FAIL] T4[%0d] base_time=%d exp=258", i, base_time);
            end

            // T5: 额外延迟精确等于 nop_cnt
            ntest = ntest + 1;
            if (vtime - base_time == vnop) begin
                npass = npass + 1;
            end else begin
                nfail = nfail + 1;
                $display("  [FAIL] T5[%0d] vtime=%d base=%d nop=%d", i, vtime, base_time, vnop);
            end

            // T6: M2 stall 全部落位 + M3 空闲期清零
            ntest = ntest + 1;
            if (vnleft === 8'd0 && vacc === 256'd0 && varg === 256'd0 && vbgr === 256'd0) begin
                npass = npass + 1;
            end else begin
                nfail = nfail + 1;
                $display("  [FAIL] T6[%0d] nop_left=%d acc=%016x Areg=%016x Breg=%016x",
                         i, vnleft, vacc[63:0], varg[63:0], vbgr[63:0]);
            end

            $display("  v%0d: nop=%2d  t_rand=%4d  t_base=%4d  first_stall=%4d  res=%016x..%016x"
                     , i, vnop, vtime, base_time, vstall, vres[255:192], vres[63:0]);
        end

        $display("");
        $display("[T1-T6] 小计: %d/%d", npass, ntest);

        // -----------------------------------------------------------------
        // T7: 随机源有效性 —— 16 个种子, 记录 nop_cnt 与末次 stall 落点
        //   度量选「末次」而非「首次」: 最大阶 LFSR 的 LSB 首位 1 几乎必然落在前
        //   2~3 步 (几何分布), 首次落点近乎常数、无法区分种子 (实测仅 {2,3} 两值);
        //   末次落点在 256 步窗口内展开, 才是 stall 模式随种子漂移的可观测量。
        // -----------------------------------------------------------------
        va   = nm_vec_a(0);
        vb   = nm_vec_b(0);
        vexp = nm_vec_exp(0);
        for (k = 0; k < 16; k = k + 1) begin
            vseed = mk_seed(k);
            run_rnd;
            nop_hist[k]   = vnop;
            stall_hist[k] = vlast;

            ntest = ntest + 1;
            if (vres === vexp) begin
                npass = npass + 1;
            end else begin
                nfail = nfail + 1;
                $display("  [FAIL] T7.res seed=%h res=%016x", vseed, vres[255:192]);
            end

            ntest = ntest + 1;
            if (vnop >= 8'd1 && vnop <= 8'd16) begin
                npass = npass + 1;
            end else begin
                nfail = nfail + 1;
                $display("  [FAIL] T7.range seed=%h nop=%d", vseed, vnop);
            end
        end

        // 分布检查: nop_cnt 至少 5 个不同值, 末次 stall 落点至少 3 个不同值
        // (t=1 表示"与所有更早元素都不同", 即首次出现)
        dn = 0;
        ds = 0;
        for (i = 0; i < 16; i = i + 1) begin
            t = 1;
            for (j = 0; j < i; j = j + 1) begin
                if (nop_hist[j] === nop_hist[i]) t = 0;
            end
            if (t === 1) dn = dn + 1;
            t = 1;
            for (j = 0; j < i; j = j + 1) begin
                if (stall_hist[j] === stall_hist[i]) t = 0;
            end
            if (t === 1) ds = ds + 1;
        end

        ntest = ntest + 1;
        if (dn >= 5) begin
            npass = npass + 1;
        end else begin
            nfail = nfail + 1;
            $display("  [FAIL] T7.dist_nop distinct=%d", dn);
        end
        ntest = ntest + 1;
        if (ds >= 3) begin
            npass = npass + 1;
        end else begin
            nfail = nfail + 1;
            $display("  [FAIL] T7.dist_stall distinct=%d", ds);
        end
        $display("  [T7] nop_cnt distinct=%d/16   last_stall distinct=%d/16", dn, ds);
        $display("  [T7] stall_hist = %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d"
                 , stall_hist[0], stall_hist[1], stall_hist[2], stall_hist[3],
                   stall_hist[4], stall_hist[5], stall_hist[6], stall_hist[7],
                   stall_hist[8], stall_hist[9], stall_hist[10], stall_hist[11],
                   stall_hist[12], stall_hist[13], stall_hist[14], stall_hist[15]);
        $display("  [T7] nop_hist = %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d"
                 , nop_hist[0], nop_hist[1], nop_hist[2], nop_hist[3],
                   nop_hist[4], nop_hist[5], nop_hist[6], nop_hist[7],
                   nop_hist[8], nop_hist[9], nop_hist[10], nop_hist[11],
                   nop_hist[12], nop_hist[13], nop_hist[14], nop_hist[15]);

        // -----------------------------------------------------------------
        // T8: 同种子确定性复现
        // -----------------------------------------------------------------
        va   = nm_vec_a(3);
        vb   = nm_vec_b(3);
        vseed = 32'hcafebabe;
        run_rnd;
        s_res  = vres;
        s_nop  = vnop;
        s_time = vtime;
        run_rnd;
        ntest = ntest + 1;
        if (vres === s_res && vnop === s_nop && vtime === s_time) begin
            npass = npass + 1;
        end else begin
            nfail = nfail + 1;
            $display("  [FAIL] T8 res2=%016x nop2=%d t2=%d (1st %016x %d %d)"
                     , vres[255:192], vnop, vtime, s_res[255:192], s_nop, s_time);
        end
        $display("  [T8] seed=0xcafebabe 复现: res=%016x.. nop=%d time=%d",
                 vres[255:192], vnop, vtime);

        // -----------------------------------------------------------------
        // T9: rand_seed == 0 兜底种子
        // -----------------------------------------------------------------
        va   = nm_vec_a(6);
        vb   = nm_vec_b(6);
        vseed = 32'd0;
        run_rnd;
        ntest = ntest + 1;
        if (vres === nm_vec_exp(6) && vnop >= 8'd1 && vnop <= 8'd16) begin
            npass = npass + 1;
        end else begin
            nfail = nfail + 1;
            $display("  [FAIL] T9 seed=0 res=%016x nop=%d", vres[255:192], vnop);
        end
        $display("  [T9] seed=0x00000000 (兜底) res=%016x.. nop=%d", vres[255:192], vnop);

        // -----------------------------------------------------------------
        // T10: NMIN_EXTRA=8 参数化下界
        // -----------------------------------------------------------------
        va = nm_vec_a(9);
        vb = nm_vec_b(9);
        for (k = 0; k < 6; k = k + 1) begin
            vseed = mk_seed(k + 400);
            run_rnd2;
            ntest = ntest + 1;
            if (r2_nop_v >= 8'd8 && r2_nop_v <= 8'd23) begin
                npass = npass + 1;
            end else begin
                nfail = nfail + 1;
                $display("  [FAIL] T10[%0d] nop=%d (exp 8..23)", k, r2_nop_v);
            end
        end
        $display("  [T10] u_rnd2 (NMIN_EXTRA=8) 6 种子 nop_cnt 全落在 8..23");

        // -----------------------------------------------------------------
        // 汇总
        // -----------------------------------------------------------------
        $display("");
        $display("=======================================================================");
        $display("Test Summary : ntest=%d  npass=%d  nfail=%d  RESULT=%s"
                 , ntest, npass, nfail, (nfail == 0) ? "PASS" : "FAIL");
        $display("=======================================================================");
        $finish;
    end

    // 全局超时保护
    initial begin
        #2_000_000;
        $display("[FAIL] GLOBAL TIMEOUT");
        $finish;
    end

endmodule
