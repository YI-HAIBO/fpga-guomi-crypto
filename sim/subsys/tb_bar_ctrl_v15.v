// =============================================================================
// Testbench : tb_bar_ctrl_v15
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.1
// 日期     : 2026-10-09
// 视角     : sim-verifier (魏波形)
// 目标     : 验证 bar_ctrl.v v1.5 PCIe v0 规格对齐 — 零回归 + 新增寄存器全覆盖
// =============================================================================

`timescale 1ns / 1ps

module tb_bar_ctrl_v15;

    localparam CLK_PERIOD = 2.5;   // 400 MHz

    reg         clk;
    reg         rst_n;
    reg  [11:0] mmio_addr;
    reg  [31:0] mmio_wr_data;
    reg         mmio_wr_en;
    wire [31:0] mmio_rd_data;
    wire        mmio_rd_vld;

    wire        cmd_wr_en;
    wire [7:0]  cmd_rid;
    wire [3:0]  cmd_op;
    wire [1:0]  cmd_prio;
    wire [255:0] cmd_ia;
    wire [255:0] cmd_ib;
    wire [255:0] cmd_ic;

    reg  [8:0]  cmd_lvl = 0;
    reg         cmd_full = 0;
    reg  [8:0]  done_lvl = 0;
    reg         done_full = 0;

    reg         err_src_vld;
    reg  [7:0]  err_src_rid;
    reg  [7:0]  err_src_code;

    reg  [6:0]  ht_status;
    reg         trng_running;
    reg  [63:0] entropy_cnt;

    wire        ctrl_trng_start;
    wire        ctrl_trng_stop;
    wire        ctrl_trng_flush;
    wire        ctrl_sm2_start;
    wire        ctrl_sm3_start;
    wire        ctrl_sm4_start;

    wire        ctrl_start;
    wire        ctrl_flush;
    wire        ctrl_reset;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    bar_ctrl u_dut (
        .clk(clk), .rst_n(rst_n),
        .mmio_addr(mmio_addr),
        .mmio_wr_data(mmio_wr_data),
        .mmio_wr_en(mmio_wr_en),
        .mmio_rd_data(mmio_rd_data),
        .mmio_rd_vld(mmio_rd_vld),
        .cmd_wr_en(cmd_wr_en),
        .cmd_rid(cmd_rid),
        .cmd_op(cmd_op),
        .cmd_prio(cmd_prio),
        .cmd_ia(cmd_ia),
        .cmd_ib(cmd_ib),
        .cmd_ic(cmd_ic),
        .cmd_lvl(cmd_lvl),
        .cmd_full(cmd_full),
        .done_lvl(done_lvl),
        .done_full(done_full),
        .err_src_vld(err_src_vld),
        .err_src_rid(err_src_rid),
        .err_src_code(err_src_code),
        .ht_status(ht_status),
        .trng_running(trng_running),
        .entropy_cnt(entropy_cnt),
        .ctrl_trng_start(ctrl_trng_start),
        .ctrl_trng_stop(ctrl_trng_stop),
        .ctrl_trng_flush(ctrl_trng_flush),
        .ctrl_sm2_start(ctrl_sm2_start),
        .ctrl_sm3_start(ctrl_sm3_start),
        .ctrl_sm4_start(ctrl_sm4_start),
        .ctrl_start(ctrl_start),
        .ctrl_flush(ctrl_flush),
        .ctrl_reset(ctrl_reset)
    );

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = !clk;
    end

    // =========================================================================
    // 任务: 复位
    // =========================================================================
    task do_reset;
        begin
            rst_n = 0;
            mmio_addr = 0;
            mmio_wr_data = 0;
            mmio_wr_en = 0;
            err_src_vld = 0;
            err_src_rid = 0;
            err_src_code = 0;
            ht_status = 7'h00;
            trng_running = 0;
            entropy_cnt = 0;
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (2) @(posedge clk);
        end
    endtask

    // =========================================================================
    // 任务: MMIO 写 (单拍)
    // =========================================================================
    task do_write;
        input [11:0] addr;
        input [31:0] data;
        begin
            mmio_addr   = addr;
            mmio_wr_data = data;
            mmio_wr_en  = 1;
            @(posedge clk);
            #1;
            mmio_wr_en  = 0;
        end
    endtask

    // =========================================================================
    // 任务: MMIO 读 (单拍)
    // =========================================================================
    reg [31:0] rd_val;
    task do_read;
        input [11:0] addr;
        begin
            mmio_addr  = addr;
            @(posedge clk);
            #1;
            rd_val = mmio_rd_data;
        end
    endtask

    // =========================================================================
    // 任务: 注入错误
    // =========================================================================
    task do_inject_err;
        input [7:0] rid;
        input [7:0] code;
        begin
            err_src_vld = 1;
            err_src_rid = rid;
            err_src_code = code;
            @(posedge clk);
            #1;
            err_src_vld = 0;
        end
    endtask

    // =========================================================================
    // 检查辅助 (带实际值打印)
    // =========================================================================
    task check;
        input [255:0] desc;
        input         cond;
        begin
            if (cond) begin
                $display("  PASS: %s", desc);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: %s  (rd_val=0x%h)", desc, rd_val);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task check_wire;
        input [255:0] desc;
        input         cond;
        begin
            if (cond) begin
                $display("  PASS: %s", desc);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL: %s", desc);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // =========================================================================
    // 主测试
    // =========================================================================
    initial begin
        $dumpfile("tb_bar_ctrl_v15.vcd");
        $dumpvars(0, tb_bar_ctrl_v15);

        $display("========================================================");
        $display(" bar_ctrl v1.5 Testbench - PCIe v0 Spec Alignment");
        $display("========================================================");

        do_reset;
        $display("[%t] Reset done", $time);

        // =====================================================================
        // T1: 只读寄存器回读
        // =====================================================================
        $display("\n[Test 1] Read-only registers");
        do_read(12'h000);
        // VERSION: {VERSION_REG[31:16], BUILD_DATE} = {16'h0001, 16'd2026} = 32'h000107EA
        check("VERSION (0x000) = {MAJOR=1, MINOR=3, PATCH=0, BUILD=2026}",
              rd_val == 32'h000107EA);
        do_read(12'h010);
        check("FEATURE_FLAGS (0x010) = 0x3FF", rd_val == 32'h000003FF);
        do_read(12'h014);
        check("DEVICE_ID (0x014) = 0x0001", rd_val == 32'h00000001);
        do_read(12'h018);
        check("SUBSYS_VENDOR (0x018) = 0x1234", rd_val == 32'h00001234);
        do_read(12'h01C);
        check("SUBSYS_ID (0x01C) = 0x0001", rd_val == 32'h00000001);

        // =====================================================================
        // T2: 控制寄存器写入 + 脉冲输出
        // =====================================================================
        $display("\n[Test 2] Control registers + pulse outputs");

        // CTRL_GLOBAL: bit0=ENABLE, bit1=RESET_SOFT
        do_write(12'h02C, 32'h3);
        do_read(12'h02C);
        check("CTRL_GLOBAL (0x02C) readback = {rst=1, en=1}", rd_val == 32'h3);

        // CTRL_TRNG: bit0=START, bit1=STOP, bit2=FLUSH
        do_write(12'h030, 32'h7);
        // 脉冲输出是 registered, 在写入的 posedge 时采样, 持续到下一个 posedge
        // do_write 返回时已是 #1 后, NBA 已生效, 脉冲应为高
        check_wire("ctrl_trng_start pulsed", ctrl_trng_start == 1);
        check_wire("ctrl_trng_stop  pulsed", ctrl_trng_stop  == 1);
        check_wire("ctrl_trng_flush pulsed", ctrl_trng_flush == 1);
        // 等待下一个 posedge 脉冲撤除
        @(posedge clk); #1;
        check_wire("ctrl_trng_start deasserted", ctrl_trng_start == 0);

        // CTRL_SM2/SM3/SM4 — 逐个写入, 每次写入后立即检查
        do_write(12'h034, 32'h1);
        check_wire("ctrl_sm2_start pulsed", ctrl_sm2_start == 1);
        @(posedge clk); #1;
        check_wire("ctrl_sm2_start deasserted", ctrl_sm2_start == 0);

        do_write(12'h038, 32'h1);
        check_wire("ctrl_sm3_start pulsed", ctrl_sm3_start == 1);
        @(posedge clk); #1;
        check_wire("ctrl_sm3_start deasserted", ctrl_sm3_start == 0);

        do_write(12'h03C, 32'h1);
        check_wire("ctrl_sm4_start pulsed", ctrl_sm4_start == 1);
        @(posedge clk); #1;
        check_wire("ctrl_sm4_start deasserted", ctrl_sm4_start == 0);

        // =====================================================================
        // T3: 状态寄存器
        // =====================================================================
        $display("\n[Test 3] Status registers");

        // STATUS_GLOBAL
        cmd_full = 1; done_full = 1;
        do_read(12'h040);
        check("STATUS_GLOBAL: cmd_busy=1, done_pending=1",
              rd_val[3:2] == 2'b11);
        cmd_full = 0; done_full = 0;

        // STATUS_TRNG: ht_status = {t7_ok, t6_ok, t5_ok, t1_ok, t2_ok, t3_ok, t4_ok}
        ht_status = 7'h7F; trng_running = 1;
        do_read(12'h044);
        check("STATUS_TRNG: all pass, running=1 → 0x01",
              rd_val == 32'h00000001);

        ht_status = 7'h77;  // t1_ok=0 (bit3=0)
        do_read(12'h044);
        check("STATUS_TRNG: T1_FAIL=1, running=1 → 0x03",
              rd_val == 32'h00000003);

        ht_status = 7'h6F;  // t5_ok=0 (bit4=0)
        do_read(12'h044);
        check("STATUS_TRNG: T5_FAIL=1 → bit5 set", rd_val[5] == 1'b1);

        ht_status = 7'h3F;  // t7_ok=0 (bit6=0)
        do_read(12'h044);
        check("STATUS_TRNG: T7_FAIL=1 → bit7 set", rd_val[7] == 1'b1);

        ht_status = 7'h7F; trng_running = 0;

        // STATUS_ERR
        do_inject_err(8'h22, 8'h02);
        repeat (2) @(posedge clk); #1;
        do_read(12'h054);
        check("STATUS_ERR: err_flag=1 after inject", rd_val[0] == 1'b1);

        // =====================================================================
        // T4: 熵计数
        // =====================================================================
        $display("\n[Test 4] Entropy counters");
        entropy_cnt = 64'hDEADBEEFCAFEBABE;
        do_read(12'h058);
        check("TRNG_ENTROPY_CNT (0x058) = low 32 bits = 0xCAFEBABE", rd_val == 32'hCAFEBABE);
        do_read(12'h05C);
        check("TRNG_ENTROPY_CNT_HI (0x05C) = high 32 bits = 0xDEADBEEF", rd_val == 32'hDEADBEEF);

        // =====================================================================
        // T5: ERR_LOG 16 slot + ERR_LOG_HEAD
        // =====================================================================
        $display("\n[Test 5] ERR_LOG 16 slots + ERR_LOG_HEAD");

        // 先清空 err_log (T3 的注入残留)
        do_write(12'h150, 32'h1);
        repeat (2) @(posedge clk); #1;

        // 注入错误 1: code=0x01 (INFO)
        do_inject_err(8'h01, 8'h01);
        repeat (2) @(posedge clk); #1;
        do_read(12'h100);
        check("ERR_LOG[0]: severity=INFO(0), errcode=0x001",
              rd_val[23:20] == 4'd0 && rd_val[19:0] == 20'h001);

        // 注入错误 2: code=0x010 (WARN)
        do_inject_err(8'h02, 8'h10);
        repeat (2) @(posedge clk); #1;
        do_read(12'h104);
        check("ERR_LOG[1]: severity=WARN(1), errcode=0x010",
              rd_val[23:20] == 4'd1 && rd_val[19:0] == 20'h010);

        // 注入错误 3: code=0x040 (CRIT)
        do_inject_err(8'h03, 8'h40);
        repeat (2) @(posedge clk); #1;
        do_read(12'h108);
        check("ERR_LOG[2]: severity=CRIT(2), errcode=0x040",
              rd_val[23:20] == 4'd2 && rd_val[19:0] == 20'h040);

        // ERR_LOG_HEAD
        do_read(12'h140);
        check("ERR_LOG_HEAD = 3 (after 3 injects)", rd_val[3:0] == 4'd3);

        // =====================================================================
        // T6: ERR_LOG_CLEAR (0x144) 只清 log 不清 flag
        // =====================================================================
        $display("\n[Test 6] ERR_LOG_CLEAR (0x144)");
        do_read(12'h054);
        check("STATUS_ERR flag still set before clear", rd_val[0] == 1'b1);

        do_write(12'h144, 32'h1);
        repeat (2) @(posedge clk); #1;

        do_read(12'h054);
        check("STATUS_ERR flag preserved after ERR_LOG_CLEAR", rd_val[0] == 1'b1);

        do_read(12'h100);
        check("ERR_LOG[0] cleared by ERR_LOG_CLEAR", rd_val == 32'd0);

        do_read(12'h140);
        check("ERR_LOG_HEAD = 0 after ERR_LOG_CLEAR", rd_val[3:0] == 4'd0);

        // =====================================================================
        // T7: SCRATCH_REG
        // =====================================================================
        $display("\n[Test 7] SCRATCH_REG");
        do_write(12'h800, 32'hAAAAAAAA);
        do_write(12'h8FC, 32'hBBBBBBBB);
        do_read(12'h800);
        check("SCRATCH_REG[0] = 0xAAAAAAAA", rd_val == 32'hAAAAAAAA);
        do_read(12'h8FC);
        check("SCRATCH_REG[63] = 0xBBBBBBBB", rd_val == 32'hBBBBBBBB);

        // =====================================================================
        // T8: 零回归 — 旧版 doorbell/flush/reset/clr_err (0x148-0x154)
        // =====================================================================
        $display("\n[Test 8] Zero regression: old control registers (0x148-0x154)");

        cmd_full = 0;
        do_write(12'h148, 32'h1);
        check_wire("old doorbell (0x148) triggers cmd_wr_en", cmd_wr_en == 1);
        check_wire("old doorbell (0x148) triggers ctrl_start", ctrl_start == 1);

        do_write(12'h14C, 32'h1);
        check_wire("old flush (0x14C) triggers ctrl_flush", ctrl_flush == 1);

        // reset (0x150)
        do_write(12'h150, 32'h1);
        repeat (2) @(posedge clk); #1;
        do_read(12'h054);
        check("old reset (0x150) clears err_flag", rd_val[0] == 1'b0);
        do_read(12'h100);
        check("old reset (0x150) clears err_log", rd_val == 32'd0);

        // clr_err (0x154) W1C
        do_inject_err(8'h44, 8'h04);
        repeat (2) @(posedge clk); #1;
        do_write(12'h154, 32'h1);
        repeat (2) @(posedge clk); #1;
        do_read(12'h054);
        check("old clr_err (0x154) W1C clears flag", rd_val[0] == 1'b0);

        // =====================================================================
        // T9: 零回归 — 旧版 STATUS(0x004)/ERR_LOG(0x200-0x21C) 别名
        // =====================================================================
        $display("\n[Test 9] Zero regression: old aliases (0x004, 0x200-0x21C)");

        // 先清空 err_log (T8 的注入残留)
        do_write(12'h150, 32'h1);
        repeat (2) @(posedge clk); #1;

        cmd_full = 1; done_full = 0;
        do_read(12'h004);
        check("old STATUS (0x004): cmd_full=1, ready=0",
              rd_val[6] == 1'b1 && rd_val[0] == 1'b0);
        cmd_full = 0; done_full = 1;
        do_read(12'h004);
        check("old STATUS (0x004): done_full=1, ready=1",
              rd_val[7] == 1'b1 && rd_val[0] == 1'b1);

        // 旧版 ERR_LOG 别名
        do_inject_err(8'h55, 8'h55);
        repeat (2) @(posedge clk); #1;
        do_read(12'h200);
        check("old ERR_LOG alias (0x200) = err_log[0]",
              rd_val[19:0] == 20'h55);

        // =====================================================================
        // T10: 命令 shadow 路径 (零回归)
        // =====================================================================
        $display("\n[Test 10] Command shadow path");
        cmd_full = 0;
        do_write(12'h000, 32'h00000021);  // op=1, rid=0x02
        do_write(12'h004, 32'hDEADBEEF);
        do_write(12'h148, 32'h1);
        check_wire("cmd_rid = 0x02", cmd_rid == 8'h02);
        check_wire("cmd_op  = 0x1",  cmd_op  == 4'h1);
        check_wire("cmd_ia[31:0] = 0xDEADBEEF", cmd_ia[31:0] == 32'hDEADBEEF);

        // =====================================================================
        // 报告
        // =====================================================================
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
        #2_000_000;
        $display("ERROR: Testbench timeout!");
        $finish;
    end

endmodule