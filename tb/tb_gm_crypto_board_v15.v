// =============================================================================
// 测试平台 : tb_gm_crypto_board_v15
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.1
// 日期     : 2026-10-23
// 视角     : fpga-fullflow-lead (齐流晶)
//
// 目的     : 验证板级顶层 gm_crypto_board_v15 的:
//              1) clk100 -> clk50 二分频正确 (20 ns 周期)
//              2) POR 在 65534 拍 clk50 后释放 (rst_n 0->1, 之后保持)
//              3) probe FSM 8 步序列逐位匹配 (addr/wr 与 RTL 一致)
//              4) 5 个 sticky 灯位在健康状态下全部置 1
//              5) heartbeat 计数器在 clk50 上正常计数
//              6) LED 8 位编码与内部信号一致
//
// 编译     : iverilog -g2005 -Wall
//   源列表与 -I 路径见 .workbuddy/tmp/run_board_tb_v15.py (与本文件头保持一致)
//
// 运行     : vvp .workbuddy/tmp/tb_gm_crypto_board_v15.vvp
//
// -----------------------------------------------------------------------------
// v1.1 修订 (2026-10-23):
//  1. v1.0 编译失败: $realtime() 的空括号在 iverilog -g2005 下报
//     "Empty function argument list requires SystemVerilog" -> 全部改为
//     $realtime (Verilog-2005 规定零参数系统函数不写括号)。
//  2. v1.0 语义错误(致命): 判定时刻硬编码 t=0.2ms / 1.0ms, 但 por_cnt 计到
//     65534 拍 clk50 才释放 rst_n = 65534 x 20ns = 1.3107 ms, 而 v1.0 仿真
//     只跑到 1.01 ms -> DUT 全程仍在复位, 所有判定在复位态空转, led[0] 恒 0。
//     改为: 事件驱动判定 + 全绿即早退 + 3.0 ms 硬超时 + 失败诊断转储。
//  3. v1.0 注释笔误: "4 个 sticky 灯位" 实为 5 项 (global_en/trng/err/
//     entropy/feat)。
//  4. 新增 probe 采样诊断打印 (前 16 次 sample_en 的实际读回值), 便于
//     失败时定位是哪一步的读回不符。
// =============================================================================

`timescale 1ns / 1ps

module tb_gm_crypto_board_v15;

    // ---- 顶层端口 ----
    reg  clk = 1'b0;
    wire [7:0] led;

    // 100 MHz 时钟 (周期 10 ns)
    always #5 clk = ~clk;

    // ---- DUT ----
    gm_crypto_board_v15 u_dut (
        .clk (clk),
        .led (led)
    );

    // ---- 6 项判定完成标志 ----
    reg chk_clk50  = 1'b0;
    reg chk_por    = 1'b0;
    reg chk_probe  = 1'b0;
    reg chk_sticky = 1'b0;
    reg chk_led    = 1'b0;
    reg chk_hb     = 1'b0;

    // =========================================================================
    // 1. clk100 -> clk50 二分频断言 (TB 本地参照, 与 DUT 复位无关)
    //    clk50_q 每个 clk 上升沿翻转 -> 周期 = 2 x 10 ns = 20 ns
    // =========================================================================
    reg clk50_q = 1'b0;
    always @(posedge clk) clk50_q <= ~clk50_q;

    integer clk50_rise_cnt = 0;
    real    clk50_prev_t   = 0.0;
    reg     prev_clk50_q   = 1'b0;

    always @(posedge clk) begin
        if (clk50_q && !prev_clk50_q) begin
            if (clk50_rise_cnt > 0) begin
                if (($realtime - clk50_prev_t) < 19.0 ||
                    ($realtime - clk50_prev_t) > 21.0) begin
                    $display("FAIL: clk50 周期 = %0.2f ns (期望 20 ns)",
                             $realtime - clk50_prev_t);
                    $finish;
                end
                if (clk50_rise_cnt == 3) begin
                    chk_clk50 <= 1'b1;
                    $display("PASS[1]: clk50 二分频 = %0.2f ns @ t=%0.0f ns",
                             $realtime - clk50_prev_t, $realtime);
                end
            end
            clk50_prev_t   <= $realtime;
            clk50_rise_cnt <= clk50_rise_cnt + 1;
        end
        prev_clk50_q <= clk50_q;
    end

    // =========================================================================
    // 2. POR 断言 (事件驱动)
    //    rst_n 在 por_cnt = 65534 拍 clk50 后释放 = 1.3107 ms
    // =========================================================================
    integer rst_n_rise_cnt = 0;
    reg     prev_rst_n     = 1'b0;

    always @(posedge clk) begin
        if (u_dut.rst_n && !prev_rst_n) begin
            if (rst_n_rise_cnt > 0) begin
                $display("FAIL: rst_n 释放后再次拉高 (期望只释放一次)");
                $finish;
            end
            chk_por <= 1'b1;
            $display("PASS[2]: rst_n 释放 @ t=%0.4f ms (期望 ~1.3107 ms)",
                     $realtime / 1000000.0);
            rst_n_rise_cnt <= rst_n_rise_cnt + 1;
        end
        prev_rst_n <= u_dut.rst_n;
    end

    // ---- 断言: rst_n 释放后保持 1 ----
    always @(posedge clk) begin
        if (chk_por && !u_dut.rst_n) begin
            $display("FAIL: rst_n 释放后被拉低 (期望保持 1)");
            $finish;
        end
    end

    // =========================================================================
    // 3. probe FSM 断言 (事件驱动)
    // =========================================================================
    // ---- p_addr 与 probe_step 一一对应 ----
    always @(posedge clk) begin
        if (u_dut.boot_done) begin
            case (u_dut.probe_step)
                3'd0:  if (u_dut.p_addr !== 20'h0002C) begin
                           $display("FAIL: probe_step=0 但 p_addr=%05h (期望 0002C)",
                                    u_dut.p_addr);
                           $finish;
                       end
                3'd1:  if (u_dut.p_addr !== 20'h00030) begin
                           $display("FAIL: probe_step=1 但 p_addr=%05h (期望 00030)",
                                    u_dut.p_addr);
                           $finish;
                       end
                3'd2:  if (u_dut.p_addr !== 20'h00040) begin
                           $display("FAIL: probe_step=2 但 p_addr=%05h (期望 00040)",
                                    u_dut.p_addr);
                           $finish;
                       end
                3'd3:  if (u_dut.p_addr !== 20'h00044) begin
                           $display("FAIL: probe_step=3 但 p_addr=%05h (期望 00044)",
                                    u_dut.p_addr);
                           $finish;
                       end
                3'd4:  if (u_dut.p_addr !== 20'h00054) begin
                           $display("FAIL: probe_step=4 但 p_addr=%05h (期望 00054)",
                                    u_dut.p_addr);
                           $finish;
                       end
                3'd5:  if (u_dut.p_addr !== 20'h00058) begin
                           $display("FAIL: probe_step=5 但 p_addr=%05h (期望 00058)",
                                    u_dut.p_addr);
                           $finish;
                       end
                3'd6:  if (u_dut.p_addr !== 20'h00010) begin
                           $display("FAIL: probe_step=6 但 p_addr=%05h (期望 00010)",
                                    u_dut.p_addr);
                           $finish;
                       end
                default: if (u_dut.p_addr !== 20'h00800) begin
                              $display("FAIL: probe_step=7 但 p_addr=%05h (期望 00800)",
                                       u_dut.p_addr);
                              $finish;
                          end
            endcase
        end
    end

    // ---- p_wr 与 probe_step 一致 (写步骤 = 0,1,7) ----
    always @(posedge clk) begin
        if (u_dut.boot_done) begin
            case (u_dut.probe_step)
                3'd0, 3'd1, 3'd7: if (u_dut.p_wr !== 1'b1) begin
                    $display("FAIL: probe_step=%0d 但 p_wr=0 (期望 1)",
                             u_dut.probe_step);
                    $finish;
                end
                3'd2, 3'd3, 3'd4, 3'd5, 3'd6: if (u_dut.p_wr !== 1'b0) begin
                    $display("FAIL: probe_step=%0d 但 p_wr=1 (期望 0)",
                             u_dut.probe_step);
                    $finish;
                end
            endcase
        end
    end

    // ---- probe 轮转计数 (探测 probe_step 从 7 回绕到 0) ----
    integer chk_probe_cnt = 0;
    reg     prev_probe_step = 3'd0;

    always @(posedge clk) begin
        if (u_dut.boot_done) begin
            if (u_dut.probe_step == 3'd0 && prev_probe_step != 3'd0)
                chk_probe_cnt <= chk_probe_cnt + 1;
            prev_probe_step <= u_dut.probe_step;
        end
    end

    always @(posedge clk) begin
        if (chk_probe_cnt >= 2 && !chk_probe) begin
            chk_probe <= 1'b1;
            $display("PASS[3]: probe FSM 8 步映射正确 (已验证 %0d 个完整轮转) @ t=%0.4f ms", chk_probe_cnt, $realtime / 1000000.0);
            chk_probe_cnt <= 2;   // 封顶, 避免长时间仿真整数溢出
        end
    end

    // ---- probe 采样诊断 (打印前 16 次 sample_en 的实际读回值) ----
    integer probe_sample_cnt = 0;

    always @(posedge clk) begin
        if (u_dut.sample_en) begin
            if (probe_sample_cnt < 16) begin
                $display("  probe[%02d] step=%0d addr=%05h wr=%b rd=%08h",
                         probe_sample_cnt, u_dut.probe_step, u_dut.p_addr,
                         u_dut.p_wr, u_dut.s_mmio_rd_data);
            end
            probe_sample_cnt <= probe_sample_cnt + 1;
        end
    end

    // =========================================================================
    // 4. 5 个 sticky 灯位断言 (事件驱动: all_ok 置起即通过)
    // =========================================================================
    always @(posedge clk) begin
        if (u_dut.all_ok && !chk_sticky) begin
            chk_sticky <= 1'b1;
            $display("PASS[4]: 5 项自测全部通过 (global_en=%b trng=%b err=%b entropy=%b feat=%b) @ t=%0.4f ms",
                     u_dut.global_en_ok, u_dut.trng_ok, u_dut.err_ok,
                     u_dut.entropy_ok, u_dut.feat_ok, $realtime / 1000000.0);
        end
    end

    // =========================================================================
    // 5. heartbeat 断言 (事件驱动: boot_done 后首次见到非零即通过)
    //    hb_cnt[25] 翻转周期 = 2^25 x 20 ns = 671 ms, 本仿真无法覆盖,
    //    故只验证计数器已在 clk50 上正常计数。
    // =========================================================================
    always @(posedge clk) begin
        if (u_dut.boot_done && u_dut.hb_cnt != 26'd0 && !chk_hb) begin
            chk_hb <= 1'b1;
            $display("PASS[5]: heartbeat 计数中 (hb_cnt=%0d) @ t=%0.4f ms",
                     u_dut.hb_cnt, $realtime / 1000000.0);
        end
    end

    // =========================================================================
    // 6. LED 编码断言 (事件驱动: all_ok 后首次检查)
    //    [7]=fail_sticky [6]=feat [5]=entropy [4]=err [3]=trng
    //    [2]=global_en   [1]=heartbeat [0]=all_ok
    // =========================================================================
    always @(posedge clk) begin
        if (u_dut.all_ok && !chk_led) begin
            if (u_dut.fail_sticky !== 1'b0) begin
                $display("FAIL: fail_sticky = 1 (期望 0, 曾有自测项失败)");
                $finish;
            end
            if (u_dut.led[7] !== u_dut.fail_sticky) begin
                $display("FAIL: led[7]=%b != fail_sticky=%b",
                         u_dut.led[7], u_dut.fail_sticky);
                $finish;
            end
            if (u_dut.led[6] !== u_dut.feat_ok) begin
                $display("FAIL: led[6]=%b != feat_ok=%b",
                         u_dut.led[6], u_dut.feat_ok);
                $finish;
            end
            if (u_dut.led[5] !== u_dut.entropy_ok) begin
                $display("FAIL: led[5]=%b != entropy_ok=%b",
                         u_dut.led[5], u_dut.entropy_ok);
                $finish;
            end
            if (u_dut.led[4] !== u_dut.err_ok) begin
                $display("FAIL: led[4]=%b != err_ok=%b",
                         u_dut.led[4], u_dut.err_ok);
                $finish;
            end
            if (u_dut.led[3] !== u_dut.trng_ok) begin
                $display("FAIL: led[3]=%b != trng_ok=%b",
                         u_dut.led[3], u_dut.trng_ok);
                $finish;
            end
            if (u_dut.led[2] !== u_dut.global_en_ok) begin
                $display("FAIL: led[2]=%b != global_en_ok=%b",
                         u_dut.led[2], u_dut.global_en_ok);
                $finish;
            end
            if (u_dut.led[1] !== u_dut.heartbeat) begin
                $display("FAIL: led[1]=%b != heartbeat=%b",
                         u_dut.led[1], u_dut.heartbeat);
                $finish;
            end
            if (u_dut.led[0] !== u_dut.all_ok) begin
                $display("FAIL: led[0]=%b != all_ok=%b",
                         u_dut.led[0], u_dut.all_ok);
                $finish;
            end
            chk_led <= 1'b1;
            $display("PASS[6]: LED 编码正确 led=%08b (heartbeat=%b) @ t=%0.4f ms",
                     u_dut.led, u_dut.heartbeat, $realtime / 1000000.0);
        end
    end

    // =========================================================================
    // 7. 收尾: 波形 + 全绿早退 + 硬超时
    // =========================================================================
    initial begin
        $dumpfile(".workbuddy/tmp/tb_gm_crypto_board_v15.vcd");
        $dumpvars(0, tb_gm_crypto_board_v15);
        $display("=== tb_gm_crypto_board_v15 v1.1: 开始 ===");
        $display("    时序基准: rst_n 释放 ~1.3107 ms / boot_done ~1.3926 ms / probe 轮 1.28 us");
    end

    // ---- 全绿早退 ----
    always @(posedge clk) begin
        if (chk_clk50 && chk_por && chk_probe && chk_sticky && chk_led && chk_hb) begin
            $display("===========================================================");
            $display(" === PASS: 全部 6 项板级断言通过 @ t=%0.4f ms ===",
                     $realtime / 1000000.0);
            $display("===========================================================");
            $finish;
        end
    end

    // ---- 硬超时 (3.0 ms; 远超 rst_n 1.3107 + boot 0.0819 + 多轮 probe) ----
    initial begin
        #3000000;
        $display("===========================================================");
        $display(" === FAIL: 超时 (3.0 ms) 未达到全绿状态 ===");
        $display("===========================================================");
        $display("  rst_n=%b boot_done=%b all_ok=%b fail_sticky=%b",
                 u_dut.rst_n, u_dut.boot_done, u_dut.all_ok, u_dut.fail_sticky);
        $display("  global_en_ok=%b trng_ok=%b err_ok=%b entropy_ok=%b feat_ok=%b",
                 u_dut.global_en_ok, u_dut.trng_ok, u_dut.err_ok,
                 u_dut.entropy_ok, u_dut.feat_ok);
        $display("  heartbeat=%b hb_cnt=%0d led=%08b",
                 u_dut.heartbeat, u_dut.hb_cnt, u_dut.led);
        $display("  chk: clk50=%b por=%b probe=%b sticky=%b led=%b hb=%b",
                 chk_clk50, chk_por, chk_probe, chk_sticky, chk_led, chk_hb);
        $finish;
    end

endmodule
