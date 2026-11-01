// =============================================================================
// 测试模块 : tb_ring_ctrl
// 模块编号 : M22 (环管理与 MSI-X 触发协调)
// 版本     : v1.0
// 日期     : 2026-10-09
// 仿真工具 : iverilog -g2005
//
// 测试覆盖:
//   T1  复位
//   T2  MMIO 写入转发 (CMD_RING 条目)
//   T3  MMIO 写入转发 (DESC_RING 条目)
//   T4  HEAD 更新转发
//   T5  cmd_avail → dma_start
//   T6  dma_done → MSI-X CMD_BATCH_DONE (向量 0)
//   T7  dma_error → MSI-X ERR_CRIT (向量 4)
//   T8  ctrl_busy 标志
//   T9  ctrl_done 脉冲
//   T10 零回归 (多批次 DMA)
// =============================================================================

`timescale 1ns / 1ps

module tb_ring_ctrl;

    reg clk;
    reg rst_n;

    // MMIO 写入
    reg                  mmio_cmd_wr_en;
    reg  [7:0]           mmio_cmd_wr_idx;
    reg  [127:0]         mmio_cmd_wr_entry;
    reg                  mmio_cmd_head_wr_en;
    reg  [7:0]           mmio_cmd_head_ptr;

    reg                  mmio_desc_wr_en;
    reg  [7:0]           mmio_desc_wr_idx;
    reg  [127:0]         mmio_desc_wr_entry;
    reg                  mmio_desc_head_wr_en;
    reg  [7:0]           mmio_desc_head_ptr;

    // 环状态
    reg                  cmd_avail;
    reg  [7:0]           cmd_head_cur;
    reg  [7:0]           cmd_tail;
    reg                  desc_avail;
    reg  [7:0]           desc_head_cur;
    reg  [7:0]           desc_tail;

    // DMA
    reg                  dma_done;
    reg                  dma_error;

    // 控制
    reg                  ctrl_start;

    // 输出
    wire                 cmd_ring_wr_en;
    wire [7:0]           cmd_ring_wr_idx;
    wire [127:0]         cmd_ring_wr_entry;
    wire                 cmd_ring_head_wr_en;
    wire [7:0]           cmd_ring_head_ptr;

    wire                 desc_ring_wr_en;
    wire [7:0]           desc_ring_wr_idx;
    wire [127:0]         desc_ring_wr_entry;
    wire                 desc_ring_head_wr_en;
    wire [7:0]           desc_ring_head_ptr;

    wire                 dma_start;
    wire [7:0]           dma_cmd_id;
    wire [31:0]          dma_payload_addr;
    wire [31:0]          dma_result_addr;

    wire                 msix_trigger;
    wire [3:0]           msix_vec;

    wire                 ctrl_done;
    wire                 ctrl_busy;

    integer pass, fail;

    // =========================================================================
    // DUT
    // =========================================================================
    ring_ctrl #(
        .PTR_W(8)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .mmio_cmd_wr_en(mmio_cmd_wr_en),
        .mmio_cmd_wr_idx(mmio_cmd_wr_idx),
        .mmio_cmd_wr_entry(mmio_cmd_wr_entry),
        .mmio_cmd_head_wr_en(mmio_cmd_head_wr_en),
        .mmio_cmd_head_ptr(mmio_cmd_head_ptr),
        .mmio_desc_wr_en(mmio_desc_wr_en),
        .mmio_desc_wr_idx(mmio_desc_wr_idx),
        .mmio_desc_wr_entry(mmio_desc_wr_entry),
        .mmio_desc_head_wr_en(mmio_desc_head_wr_en),
        .mmio_desc_head_ptr(mmio_desc_head_ptr),
        .cmd_avail(cmd_avail),
        .cmd_head_cur(cmd_head_cur),
        .cmd_tail(cmd_tail),
        .desc_avail(desc_avail),
        .desc_head_cur(desc_head_cur),
        .desc_tail(desc_tail),
        .dma_done(dma_done),
        .dma_error(dma_error),
        .ctrl_start(ctrl_start),
        .dma_start(dma_start),
        .dma_cmd_id(dma_cmd_id),
        .dma_payload_addr(dma_payload_addr),
        .dma_result_addr(dma_result_addr),
        .msix_trigger(msix_trigger),
        .msix_vec(msix_vec),
        .ctrl_done(ctrl_done),
        .ctrl_busy(ctrl_busy),
        .cmd_ring_wr_en(cmd_ring_wr_en),
        .cmd_ring_wr_idx(cmd_ring_wr_idx),
        .cmd_ring_wr_entry(cmd_ring_wr_entry),
        .cmd_ring_head_wr_en(cmd_ring_head_wr_en),
        .cmd_ring_head_ptr(cmd_ring_head_ptr),
        .desc_ring_wr_en(desc_ring_wr_en),
        .desc_ring_wr_idx(desc_ring_wr_idx),
        .desc_ring_wr_entry(desc_ring_wr_entry),
        .desc_ring_head_wr_en(desc_ring_head_wr_en),
        .desc_ring_head_ptr(desc_ring_head_ptr)
    );

    // =========================================================================
    // 时钟
    // =========================================================================
    always #5 clk = ~clk;

    // =========================================================================
    // 测试主体
    // =========================================================================
    initial begin
        pass = 0; fail = 0; clk = 0;

        // =====================================================================
        // T1: 复位
        // =====================================================================
        $display("=== T1: 复位 ===");
        rst_n = 0;
        mmio_cmd_wr_en = 0; mmio_cmd_wr_idx = 0; mmio_cmd_wr_entry = 0;
        mmio_cmd_head_wr_en = 0; mmio_cmd_head_ptr = 0;
        mmio_desc_wr_en = 0; mmio_desc_wr_idx = 0; mmio_desc_wr_entry = 0;
        mmio_desc_head_wr_en = 0; mmio_desc_head_ptr = 0;
        cmd_avail = 0; cmd_head_cur = 0; cmd_tail = 0;
        desc_avail = 0; desc_head_cur = 0; desc_tail = 0;
        dma_done = 0; dma_error = 0; ctrl_start = 0;
        @(negedge clk); @(negedge clk);
        rst_n = 1;
        @(negedge clk);
        if (dma_start === 1'b0 && msix_trigger === 1'b0 && ctrl_done === 1'b0 && ctrl_busy === 1'b0) begin
            $display("  PASS: 所有输出为 0");
            pass = pass + 1;
        end else begin
            $display("  FAIL: dma_start=%b msix_trigger=%b ctrl_done=%b ctrl_busy=%b",
                     dma_start, msix_trigger, ctrl_done, ctrl_busy);
            fail = fail + 1;
        end

        // =====================================================================
        // T2: MMIO 写入转发 (CMD_RING 条目)
        // =====================================================================
        $display("=== T2: CMD_RING 条目转发 ===");
        mmio_cmd_wr_en = 1; mmio_cmd_wr_idx = 8'd5;
        mmio_cmd_wr_entry = 128'hDEADBEEFCAFEBABE12345678ABCDEF01;
        @(negedge clk);
        // 在清零前检查 (组合逻辑输出)
        if (cmd_ring_wr_en === 1'b1 && cmd_ring_wr_idx === 8'd5 &&
            cmd_ring_wr_entry === 128'hDEADBEEFCAFEBABE12345678ABCDEF01) begin
            $display("  PASS: CMD_RING 条目转发正确");
            pass = pass + 1;
        end else begin
            $display("  FAIL: en=%b idx=%h entry=%h", cmd_ring_wr_en, cmd_ring_wr_idx, cmd_ring_wr_entry);
            fail = fail + 1;
        end
        mmio_cmd_wr_en = 0;

        // =====================================================================
        // T3: MMIO 写入转发 (DESC_RING 条目)
        // =====================================================================
        $display("=== T3: DESC_RING 条目转发 ===");
        mmio_desc_wr_en = 1; mmio_desc_wr_idx = 8'd10;
        mmio_desc_wr_entry = 128'hFFEEDDCCBBAA99887766554433221100;
        @(negedge clk);
        if (desc_ring_wr_en === 1'b1 && desc_ring_wr_idx === 8'd10 &&
            desc_ring_wr_entry === 128'hFFEEDDCCBBAA99887766554433221100) begin
            $display("  PASS: DESC_RING 条目转发正确");
            pass = pass + 1;
        end else begin
            $display("  FAIL: en=%b idx=%h entry=%h", desc_ring_wr_en, desc_ring_wr_idx, desc_ring_wr_entry);
            fail = fail + 1;
        end
        mmio_desc_wr_en = 0;

        // =====================================================================
        // T4: HEAD 更新转发
        // =====================================================================
        $display("=== T4: HEAD 更新转发 ===");
        mmio_cmd_head_wr_en = 1; mmio_cmd_head_ptr = 8'd7;
        @(negedge clk);
        if (cmd_ring_head_wr_en === 1'b1 && cmd_ring_head_ptr === 8'd7) begin
            $display("  PASS: CMD HEAD 更新转发正确");
            pass = pass + 1;
        end else begin
            $display("  FAIL: en=%b ptr=%h", cmd_ring_head_wr_en, cmd_ring_head_ptr);
            fail = fail + 1;
        end
        mmio_cmd_head_wr_en = 0;

        mmio_desc_head_wr_en = 1; mmio_desc_head_ptr = 8'd12;
        @(negedge clk);
        if (desc_ring_head_wr_en === 1'b1 && desc_ring_head_ptr === 8'd12) begin
            $display("  PASS: DESC HEAD 更新转发正确");
            pass = pass + 1;
        end else begin
            $display("  FAIL: en=%b ptr=%h", desc_ring_head_wr_en, desc_ring_head_ptr);
            fail = fail + 1;
        end
        mmio_desc_head_wr_en = 0;

        // =====================================================================
        // T5: cmd_avail → dma_start
        // =====================================================================
        $display("=== T5: cmd_avail → dma_start ===");
        cmd_avail = 1; cmd_head_cur = 8'd7; cmd_tail = 8'd0;
        @(negedge clk);
        // dma_start 是寄存器输出，在 posedge 更新后 negedge 可见
        if (dma_start === 1'b1 && ctrl_busy === 1'b1) begin
            $display("  PASS: dma_start 触发, ctrl_busy=1");
            pass = pass + 1;
        end else begin
            $display("  FAIL: dma_start=%b ctrl_busy=%b", dma_start, ctrl_busy);
            fail = fail + 1;
        end

        // =====================================================================
        // T6: dma_done → MSI-X CMD_BATCH_DONE (向量 0)
        // =====================================================================
        $display("=== T6: dma_done → MSI-X CMD_BATCH_DONE ===");
        dma_done = 1; dma_error = 0;
        @(negedge clk);
        dma_done = 0;
        if (msix_trigger === 1'b1 && msix_vec === 4'd0 && ctrl_done === 1'b1) begin
            $display("  PASS: MSI-X 向量 0 (CMD_BATCH_DONE), ctrl_done=1");
            pass = pass + 1;
        end else begin
            $display("  FAIL: trigger=%b vec=%d ctrl_done=%b", msix_trigger, msix_vec, ctrl_done);
            fail = fail + 1;
        end
        // 下一拍脉冲应清零
        @(negedge clk);
        if (msix_trigger === 1'b0 && ctrl_done === 1'b0) begin
            $display("  PASS: MSI-X / ctrl_done 单拍脉冲");
            pass = pass + 1;
        end else begin
            $display("  FAIL: trigger=%b ctrl_done=%b (应为 0)", msix_trigger, ctrl_done);
            fail = fail + 1;
        end

        // =====================================================================
        // T7: dma_error → MSI-X ERR_CRIT (向量 4)
        // =====================================================================
        $display("=== T7: dma_error → MSI-X ERR_CRIT ===");
        // 重新触发 DMA (先清除 consumed 标志)
        mmio_cmd_head_wr_en = 1; mmio_cmd_head_ptr = 8'd1;
        @(negedge clk);
        mmio_cmd_head_wr_en = 0;
        cmd_avail = 1;
        @(negedge clk);  // dma_start
        @(negedge clk);  // 进入 S_DMA_RUN
        cmd_avail = 0;
        dma_done = 1; dma_error = 1;
        @(negedge clk);
        dma_done = 0; dma_error = 0;
        if (msix_trigger === 1'b1 && msix_vec === 4'd4 && ctrl_done === 1'b1) begin
            $display("  PASS: MSI-X 向量 4 (ERR_CRIT)");
            pass = pass + 1;
        end else begin
            $display("  FAIL: trigger=%b vec=%d ctrl_done=%b", msix_trigger, msix_vec, ctrl_done);
            fail = fail + 1;
        end

        // =====================================================================
        // T8: ctrl_busy 标志
        // =====================================================================
        $display("=== T8: ctrl_busy ===");
        @(negedge clk);  // 确保状态稳定
        if (ctrl_busy === 1'b0) begin
            $display("  PASS: IDLE 状态 ctrl_busy=0");
            pass = pass + 1;
        end else begin
            $display("  FAIL: ctrl_busy=%b (应为 0)", ctrl_busy);
            fail = fail + 1;
        end

        // =====================================================================
        // T9: ctrl_done 脉冲
        // =====================================================================
        $display("=== T9: ctrl_done 脉冲 ===");
        if (ctrl_done === 1'b0) begin
            $display("  PASS: IDLE 状态 ctrl_done=0");
            pass = pass + 1;
        end else begin
            $display("  FAIL: ctrl_done=%b (应为 0)", ctrl_done);
            fail = fail + 1;
        end

        // =====================================================================
        // T10: 零回归 (多批次 DMA)
        // =====================================================================
        $display("=== T10: 零回归 ===");
        // 批次 1 (先清除 consumed)
        mmio_cmd_head_wr_en = 1; mmio_cmd_head_ptr = 8'd3;
        @(negedge clk);
        mmio_cmd_head_wr_en = 0;
        cmd_avail = 1;
        @(negedge clk);  // dma_start
        @(negedge clk);  // S_DMA_RUN
        cmd_avail = 0;
        dma_done = 1;
        @(negedge clk);
        dma_done = 0;
        if (msix_trigger === 1'b1 && msix_vec === 4'd0) begin
            $display("  PASS: 批次 1 MSI-X 正确");
            pass = pass + 1;
        end else begin
            $display("  FAIL: 批次 1 trigger=%b vec=%d", msix_trigger, msix_vec);
            fail = fail + 1;
        end

        // 批次 2 (先清除 consumed)
        mmio_cmd_head_wr_en = 1; mmio_cmd_head_ptr = 8'd2;
        @(negedge clk);
        mmio_cmd_head_wr_en = 0;
        cmd_avail = 1;
        @(negedge clk);
        @(negedge clk);
        cmd_avail = 0;
        dma_done = 1;
        @(negedge clk);
        dma_done = 0;
        if (msix_trigger === 1'b1 && msix_vec === 4'd0) begin
            $display("  PASS: 批次 2 MSI-X 正确");
            pass = pass + 1;
        end else begin
            $display("  FAIL: 批次 2 trigger=%b vec=%d", msix_trigger, msix_vec);
            fail = fail + 1;
        end

        // =====================================================================
        // 汇总
        // =====================================================================
        $display("==============================================");
        $display("结果: %0d PASS, %0d FAIL", pass, fail);
        if (fail == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** %0d TEST(S) FAILED ***", fail);
        $finish;
    end

endmodule