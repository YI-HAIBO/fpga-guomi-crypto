// =============================================================================
// Testbench : tb_bar_ctrl_v14
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-03
// 视角     : sim-verifier (魏波形)
// 目标     : 验证 bar_ctrl.v v1.4 新增的 STATUS.err 清零语义
//   T1: err_src_vld 置位 STATUS.err
//   T2: 写 0x10C CTRL_CLR_ERR 清 err_flag (W1C, err_log 保留)
//   T3: err_src_vld 再次置位, 写 0x108 CTRL_RESET 清 err_flag + err_log
//   T4: CTRL_RESET 同时脉冲输出 ctrl_reset
//   T5: W1C 写 0 不清 (只有非零值才清)
// =============================================================================

`timescale 1ns / 1ps

module tb_bar_ctrl_v14;

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

    wire        ctrl_start;
    wire        ctrl_flush;
    wire        ctrl_reset;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // =========================================================================
    // DUT
    // =========================================================================
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
        .ctrl_start(ctrl_start),
        .ctrl_flush(ctrl_flush),
        .ctrl_reset(ctrl_reset)
    );

    // =========================================================================
    // 时钟
    // =========================================================================
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
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (2) @(posedge clk);
        end
    endtask

    // =========================================================================
    // 任务: MMIO 写
    // =========================================================================
    task do_write;
        input [11:0] addr;
        input [31:0] data;
        begin
            mmio_addr  = addr;
            mmio_wr_data = data;
            mmio_wr_en = 1;
            @(posedge clk);
            #1;              // 越过 NBA 区, 确保 DUT always block 已采样到 wr_en=1
            mmio_wr_en = 0;
        end
    endtask

    // =========================================================================
    // 任务: MMIO 读
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
            #1;              // 越过 NBA 区, 确保 DUT always block 已采样到 err_src_vld=1
            err_src_vld = 0;
        end
    endtask

    // =========================================================================
    // 主测试
    // =========================================================================
    initial begin
        $dumpfile("tb_bar_ctrl_v14.vcd");
        $dumpvars(0, tb_bar_ctrl_v14);

        $display("========================================================");
        $display(" bar_ctrl v1.4 Testbench - STATUS.err 清零语义");
        $display("========================================================");

        do_reset;
        $display("[%t] Reset done", $time);

        // ------------------------------------------------------------------
        // T1: err_src_vld 置位 STATUS.err
        // ------------------------------------------------------------------
        $display("\n[Test 1] err_src_vld sets STATUS.err");
        do_read(12'h004);
        if (rd_val[2] == 0) begin
            $display("  [pre] STATUS.err = 0 (clean)");
        end else begin
            $display("  [pre] STATUS.err = %b (unexpected)", rd_val[2]);
        end
        err_src_vld = 1;
        err_src_rid = 8'h22;
        err_src_code = 8'h02;
        @(posedge clk);
        #1;
        err_src_vld = 0;
        @(posedge clk);
        #1;
        do_read(12'h004);
        if (rd_val[2] == 1) begin
            $display("  PASS: STATUS.err set to 1 after err_src_vld");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: STATUS.err = %b (expected 1)", rd_val[2]);
            fail_cnt = fail_cnt + 1;
        end

        // ------------------------------------------------------------------
        // T2: 写 0x10C CTRL_CLR_ERR 清 err_flag (W1C, err_log 保留)
        // ------------------------------------------------------------------
        $display("\n[Test 2] Write 0x10C CTRL_CLR_ERR clears STATUS.err");
        do_write(12'h10C, 32'hDEAD);
        repeat (2) @(posedge clk);
        do_read(12'h004);
        if (rd_val[2] == 0) begin
            $display("  PASS: STATUS.err cleared by 0x10C");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: STATUS.err = %b (expected 0)", rd_val[2]);
            fail_cnt = fail_cnt + 1;
        end

        // 验证 err_log 仍保留 (读 0x200)
        do_read(12'h200);
        if (rd_val[31:24] == 8'h22 && rd_val[23:16] == 8'h02) begin
            $display("  PASS: ERR_LOG[0] preserved ({rid=0x22, code=0x02})");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: ERR_LOG[0] = 0x%h (expected 0x22020000)", rd_val);
            fail_cnt = fail_cnt + 1;
        end

        // ------------------------------------------------------------------
        // T3: err_src_vld 再次置位, 写 0x108 CTRL_RESET 清 err_flag + err_log
        // ------------------------------------------------------------------
        $display("\n[Test 3] Write 0x108 CTRL_RESET clears err_flag + err_log");
        do_inject_err(8'h33, 8'h03);
        repeat (2) @(posedge clk);
        do_read(12'h004);
        if (rd_val[2] == 1) begin
            $display("  [pre] STATUS.err = 1 after re-inject");
        end

        do_write(12'h108, 32'h1);
        repeat (2) @(posedge clk);
        do_read(12'h004);
        if (rd_val[2] == 0) begin
            $display("  PASS: STATUS.err cleared by 0x108");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: STATUS.err = %b (expected 0)", rd_val[2]);
            fail_cnt = fail_cnt + 1;
        end

        // 验证 err_log 被清
        do_read(12'h200);
        if (rd_val == 32'd0) begin
            $display("  PASS: ERR_LOG[0] cleared by CTRL_RESET");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: ERR_LOG[0] = 0x%h (expected 0x0)", rd_val);
            fail_cnt = fail_cnt + 1;
        end

        // ------------------------------------------------------------------
        // T4: CTRL_RESET 同时输出 ctrl_reset 脉冲
        // ------------------------------------------------------------------
        $display("\n[Test 4] CTRL_RESET pulses ctrl_reset output");
        ctrl_reset_pulsed = 0;
        mmio_addr  = 12'h108;
        mmio_wr_data = 32'h1;
        mmio_wr_en = 1;
        @(posedge clk);
        #1;
        if (ctrl_reset == 1) begin
            ctrl_reset_pulsed = 1;
        end
        mmio_wr_en = 0;
        repeat (2) @(posedge clk);
        if (ctrl_reset_pulsed) begin
            $display("  PASS: ctrl_reset pulsed on 0x108 write");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: ctrl_reset not pulsed");
            fail_cnt = fail_cnt + 1;
        end

        // ------------------------------------------------------------------
        // T5: W1C 写 0 不清 (只有非零值才清)
        // ------------------------------------------------------------------
        $display("\n[Test 5] W1C write 0 does NOT clear err_flag");
        do_inject_err(8'h44, 8'h04);
        repeat (2) @(posedge clk);
        do_read(12'h004);
        if (rd_val[2] == 1) begin
            $display("  [pre] STATUS.err = 1 after inject");
        end
        do_write(12'h10C, 32'h0);
        repeat (2) @(posedge clk);
        do_read(12'h004);
        if (rd_val[2] == 1) begin
            $display("  PASS: STATUS.err preserved (W1C write 0 ignored)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: STATUS.err = %b (expected 1, W1C 0 should not clear)", rd_val[2]);
            fail_cnt = fail_cnt + 1;
        end

        // 清理
        do_write(12'h10C, 32'h1);

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

    // ctrl_reset 脉冲检测
    reg ctrl_reset_pulsed = 0;

    // =========================================================================
    // 超时保护
    // =========================================================================
    initial begin
        #2_000_000;
        $display("ERROR: Testbench timeout!");
        $finish;
    end

endmodule
