// =============================================================================
// Testbench : tb_sm2_pmul_windowed
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.1
// 日期     : 2026-10-04
// 目标     : 验证 sm2_pmul_windowed v1.1 (w=4, 预计算 1P..15P)
//
// v1.0 的 TB 只断言 "非无穷远且 x!=0" —— 模块恒返回基点 P 也能全绿,
// 属于项目 §5.3 记录的 "捕获寄存器残留造成假通过" 同类缺陷。
// v1.1 改为**逐位对拍已验证的 Python 参考模型期望向量**。
//
// 期望向量来源: .workbuddy/tmp/pmul_window_ref.py -> sim/sm2/pmul_window_vectors.vh
//   该参考模型已通过:
//     [B] 仿射解码链校准 (x = X*Z^-2*R, y = Y*Z^-3*R^2)
//     [C] Python DAA 与已签核 sm2_pmul v2.0 RTL 输出逐位一致 (k=1,2,3,7,255)
//     [D] 预计算表 1P..15P 全部与独立仿射基准一致
//     [E] 窗口化结果与 DAA 在 20 个 k 上仿射等价
//
// 测试项:
//   T1 : 11 组期望向量逐位对拍 (X, Y, Z, inf_flag)
//        覆盖: 低位 / window=15 / 单 MSB 位 / 高位随机 / n-1
//   T2 : k=0 边界 (结果为无穷远)
//   T3 : 背靠背 3 次 (无跨事务状态残留)
//   T4 : 与已签核 sm2_pmul v2.0 基线对拍 (k=1,2,3, 运算路径必逐位相同)
//   T5 : 吞吐/延迟统计 (与基线 256 轮对比)
// =============================================================================

`timescale 1ns / 1ps

module tb_sm2_pmul_windowed;

    // =========================================================================
    // 参数
    // =========================================================================
    localparam integer CLK_PERIOD = 10;   // 100 MHz
    localparam integer TIMEOUT    = 400000;

    // 期望向量 (由 pmul_window_ref.py 生成)。
    // 必须 include 在 module 体内: 本机的 iverilog -g2005 拒绝文件作用域声明。
    `include "pmul_window_vectors.vh"

    // =========================================================================
    // 信号
    // =========================================================================
    reg         clk;
    reg         rst_n;

    // --- 被测: 窗口化 ---
    reg          w_start;
    reg  [255:0] w_scalar;
    reg  [255:0] w_px, w_py;
    wire [255:0] w_x, w_y, w_z;
    wire         w_inf, w_done;

    // --- 对照: 已签核 DAA 基线 ---
    reg          d_start;
    reg  [255:0] d_scalar;
    reg  [255:0] d_px, d_py;
    wire [255:0] d_x, d_y, d_z;
    wire         d_inf, d_done;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // 测试过程变量 (iverilog 不允许在 begin 块内声明, 统一提到模块级)
    integer i;
    integer ok;
    integer cyc;
    integer cyc_daa;
    integer cyc_total_win = 0;
    integer cyc_total_daa = 0;
    integer cmp_fail;
    reg       running_win;
    reg       running_daa;
    integer   tc_win;
    integer   tc_daa;

    // =========================================================================
    // DUT
    // =========================================================================
    // -- Phase 8: 共享 Montgomery 乘法响应器 (sm2_mm_arb N=1, 与 RTL 同构) --
    wire          win_mm_req;
    wire [255:0]  win_mm_a, win_mm_b;
    wire [255:0]  win_mm_result;
    wire          win_mm_done;

    sm2_mm_arb #(.N(1)) u_win_mm_arb (
        .clk(clk), .rst_n(rst_n),
        .req({win_mm_req}), .a_flat({win_mm_a}), .b_flat({win_mm_b}),
        .mm_done({win_mm_done}), .result_flat({win_mm_result}), .busy()
    );

    sm2_pmul_windowed u_win (
        .clk(clk), .rst_n(rst_n),
        .start(w_start), .scalar(w_scalar), .px(w_px), .py(w_py),
        .x_out(w_x), .y_out(w_y), .z_out(w_z),
        .inf_flag(w_inf), .done(w_done),
        .pa_mm_req(win_mm_req), .pa_mm_a(win_mm_a), .pa_mm_b(win_mm_b),
        .pa_mm_result(win_mm_result), .pa_mm_done(win_mm_done)
    );

    // -- Phase 8: 共享 Montgomery 乘法响应器 (sm2_mm_arb N=1, 与 RTL 同构) --
    wire          daa_mm_req;
    wire [255:0]  daa_mm_a, daa_mm_b;
    wire [255:0]  daa_mm_result;
    wire          daa_mm_done;

    sm2_mm_arb #(.N(1)) u_daa_mm_arb (
        .clk(clk), .rst_n(rst_n),
        .req({daa_mm_req}), .a_flat({daa_mm_a}), .b_flat({daa_mm_b}),
        .mm_done({daa_mm_done}), .result_flat({daa_mm_result}), .busy()
    );

    sm2_pmul u_daa (
        .clk(clk), .rst_n(rst_n),
        .start(d_start), .scalar(d_scalar), .px(d_px), .py(d_py),
        .x_out(d_x), .y_out(d_y), .z_out(d_z),
        .inf_flag(d_inf), .done(d_done),
        .pa_mm_req(daa_mm_req), .pa_mm_a(daa_mm_a), .pa_mm_b(daa_mm_b),
        .pa_mm_result(daa_mm_result), .pa_mm_done(daa_mm_done)
    );

    // =========================================================================
    // 时钟 / 复位
    // =========================================================================
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = !clk;
    end

    task do_reset;
        begin
            rst_n   = 1'b0;
            w_start = 1'b0;  d_start = 1'b0;
            repeat (10) @(posedge clk);
            rst_n = 1'b1;
            repeat (3)  @(posedge clk);
        end
    endtask

    // =========================================================================
    // 单次窗口化点乘: 返回 ok(1=完成) 与 cycles(耗时拍数)
    // done 是 1 拍脉冲, 必须在 #(1) 越过 NBA 区后采样, 否则读到陈旧值。
    // =========================================================================
    task do_pmul_win(input [255:0] k, input [255:0] pxx, input [255:0] pyy,
                     output integer ok, output integer cycles);
        begin
            ok = 1;
            cycles = 0;
            tc_win = 0;
            running_win = 1'b1;
            w_scalar = k;
            w_px     = pxx;
            w_py     = pyy;
            w_start  = 1'b1;
            @(posedge clk);
            #1;
            w_start = 1'b0;
            while (running_win) begin
                @(posedge clk);
                #1;
                tc_win = tc_win + 1;
                if (w_done) begin
                    running_win = 1'b0;
                end else if (tc_win > TIMEOUT) begin
                    $display("    ERROR: timeout after %0d cycles", tc_win);
                    ok = 0;
                    running_win = 1'b0;
                end
            end
            cycles = tc_win;
        end
    endtask

    // =========================================================================
    // 单次 DAA 基线点乘
    // =========================================================================
    task do_pmul_daa(input [255:0] k, input [255:0] pxx, input [255:0] pyy,
                     output integer ok, output integer cycles);
        begin
            ok = 1;
            cycles = 0;
            tc_daa = 0;
            running_daa = 1'b1;
            d_scalar = k;
            d_px     = pxx;
            d_py     = pyy;
            d_start  = 1'b1;
            @(posedge clk);
            #1;
            d_start = 1'b0;
            while (running_daa) begin
                @(posedge clk);
                #1;
                tc_daa = tc_daa + 1;
                if (d_done) begin
                    running_daa = 1'b0;
                end else if (tc_daa > TIMEOUT) begin
                    $display("    ERROR: daa timeout after %0d cycles", tc_daa);
                    ok = 0;
                    running_daa = 1'b0;
                end
            end
            cycles = tc_daa;
        end
    endtask

    // =========================================================================
    // Main test sequence (全部串行进同一个 initial, 避免多 initial 并发竞态)
    // =========================================================================
    initial begin

        $dumpfile("tb_sm2_pmul_windowed.vcd");
        $dumpvars(1, tb_sm2_pmul_windowed);   // 仅顶层, 避免长仿真 VCD 爆炸

        $display("============================================================");
        $display(" SM2 PMul Windowed Testbench (v1.1, w=4, prec 1P..15P)");
        $display("============================================================");

        do_reset;

        // ====================================================================
        // T1: 11 组期望向量逐位对拍
        // ====================================================================
        $display("\n[T1] 期望向量逐位对拍 (%0d 组, 来自 pmul_window_ref.py)", VEC_NUM);
        for (i = 0; i < VEC_NUM; i = i + 1) begin
            cmp_fail = 0;
            do_pmul_win(vec_k(i), PM_PX, PM_PY, ok, cyc);
            cyc_total_win = cyc_total_win + cyc;
            if (!ok) begin
                $display("  [FAIL] vec[%0d] k=%064x  timeout", i, vec_k(i));
                fail_cnt = fail_cnt + 1;
            end else begin
                if (w_inf !== 1'b0) cmp_fail = cmp_fail + 1;
                if (w_x !== vec_ex(i)) cmp_fail = cmp_fail + 1;
                if (w_y !== vec_ey(i)) cmp_fail = cmp_fail + 1;
                if (w_z !== vec_ez(i)) cmp_fail = cmp_fail + 1;
                if (cmp_fail == 0) begin
                    $display("  [PASS] vec[%0d] k=%064x  X=%08x.. Y=%08x.. Z=%08x..  (%0d cyc)",
                             i, vec_k(i), w_x[255:248], w_y[255:248],
                             w_z[255:248], cyc);
                    pass_cnt = pass_cnt + 1;
                end else begin
                    $display("  [FAIL] vec[%0d] k=%064x  mismatch_cnt=%0d  (%0d cyc)",
                             i, vec_k(i), cmp_fail, cyc);
                    $display("        exp X=%h", vec_ex(i));
                    $display("        got X=%h", w_x);
                    $display("        exp Y=%h", vec_ey(i));
                    $display("        got Y=%h", w_y);
                    $display("        exp Z=%h", vec_ez(i));
                    $display("        got Z=%h", w_z);
                    fail_cnt = fail_cnt + 1;
                end
            end
        end

        // ====================================================================
        // T2: k = 0 -> 无穷远
        // ====================================================================
        $display("\n[T2] k=0 边界 (期望无穷远)");
        do_pmul_win(256'd0, PM_PX, PM_PY, ok, cyc);
        if (ok && w_inf === 1'b1 && w_x === 256'd0 && w_y === 256'd0 && w_z === 256'd0) begin
            $display("  [PASS] k=0 -> inf_flag=1, X=Y=Z=0  (%0d cyc)", cyc);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  [FAIL] k=0: ok=%0b inf=%b X=%h Y=%h Z=%h",
                     ok, w_inf, w_x, w_y, w_z);
            fail_cnt = fail_cnt + 1;
        end

        // ====================================================================
        // T3: 背靠背 3 次 (无跨事务状态残留)
        // ====================================================================
        $display("\n[T3] 背靠背 3 次 (k=5,6,7), 检查第 3 次与期望一致");
        do_pmul_win(256'd5, PM_PX, PM_PY, ok, cyc);
        do_pmul_win(256'd6, PM_PX, PM_PY, ok, cyc);
        do_pmul_win(256'd7, PM_PX, PM_PY, ok, cyc);
        // k=7 的期望向量在 T1 的 vec[3]
        if (ok && w_inf === 1'b0
            && w_x === vec_ex(3) && w_y === vec_ey(3) && w_z === vec_ez(3)) begin
            $display("  [PASS] 背靠背后 k=7 结果与期望逐位一致");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  [FAIL] 背靠背后状态残留: X=%h", w_x);
            fail_cnt = fail_cnt + 1;
        end

        // ====================================================================
        // T4: 与已签核 sm2_pmul v2.0 基线对拍
        //     k=1,2,3 时窗口化与 DAA 的运算路径完全相同 (无点加合并差异),
        //     Jacobian 输出应逐位相等, 提供独立第二基准。
        //     k>=7 起路径分叉 (Z 缩放依赖路径), 不做逐位比较。
        // ====================================================================
        $display("\n[T4] 与 sm2_pmul v2.0 基线逐位对拍 (k=1,2,3)");
        for (i = 0; i < 3; i = i + 1) begin
            cmp_fail = 0;
            do_pmul_win(vec_k(i), PM_PX, PM_PY, ok, cyc);
            cyc_total_win = cyc_total_win + cyc;
            do_pmul_daa(vec_k(i), PM_PX, PM_PY, ok, cyc_daa);
            cyc_total_daa = cyc_total_daa + cyc_daa;
            if (w_x !== d_x) cmp_fail = cmp_fail + 1;
            if (w_y !== d_y) cmp_fail = cmp_fail + 1;
            if (w_z !== d_z) cmp_fail = cmp_fail + 1;
            if (w_inf !== d_inf) cmp_fail = cmp_fail + 1;
            if (cmp_fail == 0) begin
                $display("  [PASS] k=%064x  win==daa 逐位一致 (win %0d cyc / daa %0d cyc)",
                         vec_k(i), cyc, cyc_daa);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [FAIL] k=%064x  与基线不一致 (cmp_fail=%0d)", vec_k(i), cmp_fail);
                $display("        win X=%h", w_x);
                $display("        daa X=%h", d_x);
                $display("        win Z=%h", w_z);
                $display("        daa Z=%h", d_z);
                fail_cnt = fail_cnt + 1;
            end
        end

        // ====================================================================
        // T6: 满标量延迟对比 (k = n-1, 255 位有效)
        //     只做延迟对拍, 不做逐位比较: 路径分叉后 Jacobian 的 Z 缩放不同,
        //     逐位比较在此类 k 上必然 FAIL, 但两者仍是同一仿射点
        //     (已由 pmul_window_ref.py [E] 段的 same_affine 校验覆盖)。
        //     微规格书声称 "2x 加速", 本测试给出实测证据。
        // ====================================================================
        $display("\n[T6] 满标量延迟对比 (k = n-1, 255 位有效)");
        do_pmul_win(vec_k(10), PM_PX, PM_PY, ok, cyc);
        do_pmul_daa(vec_k(10), PM_PX, PM_PY, ok, cyc_daa);
        if (ok && w_inf === 1'b0) begin
            $display("  [PASS] 窗口化 %0d cyc  vs  DAA %0d cyc  (加速比 %.2fx)",
                     cyc, cyc_daa, 1.0 * cyc_daa / cyc);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  [FAIL] 满标量窗口化未完成 (ok=%0b inf=%b)", ok, w_inf);
            fail_cnt = fail_cnt + 1;
        end

        // ====================================================================
        // T5: 延迟统计
        // ====================================================================
        $display("\n[T5] 延迟统计");
        $display("  窗口化: 均 %0d cyc/次 (T1 %0d 次 + T4 %0d 次)",
                 cyc_total_win / (VEC_NUM + 3), cyc_total_win, VEC_NUM + 3);
        $display("  DAA   : 均 %0d cyc/次 (T4 3 次, 均为小标量)", cyc_total_daa / 3);
        $display("  说明: 窗口化有固定 14 次预计算开销, 小标量反而更慢;");
        $display("        加速比只在满标量上体现 (见 T6)。");

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n============================================================");
        $display(" Test Summary");
        $display("   PASS : %0d", pass_cnt);
        $display("   FAIL : %0d", fail_cnt);
        $display("============================================================");

        if (fail_cnt == 0 && pass_cnt > 0) begin
            $display(" ALL TESTS PASSED");
        end else begin
            $display(" SOME TESTS FAILED");
        end

        $finish;
    end

endmodule
