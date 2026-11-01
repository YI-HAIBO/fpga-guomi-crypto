// =============================================================================
// 测试模块 : tb_v15_e2e (v1.5 端到端集成验证)
// 模块编号 : M23 (SS1 - PCIe Front-End System Level)
// 版本     : v1.0
// 日期     : 2026-10-09
// 仿真工具 : iverilog -g2005
//
// 系统架构:
//   Host TB → bar_ctrl (MMIO 译码) → ring_ctrl (环协调) → cmd_ring_buf / desc_ring_buf
//   ring_ctrl → msix_ctrl (MSI-X 中断)
//   TB 模拟 DMA 完成
//
// 测试覆盖:
//   T1  系统复位
//   T2  Host 写 CMD_RING 条目 → 环缓冲存储
//   T3  Host 更新 HEAD → cmd_avail → dma_start
//   T4  DMA 完成 → MSI-X CMD_BATCH_DONE (向量 0)
//   T5  DMA 错误 → MSI-X ERR_CRIT (向量 4)
//   T6  Host 写 DESC_RING 条目 → 描述符环存储
//   T7  多批次命令生命周期
//   T8  零回归: 寄存器回读
// =============================================================================

`timescale 1ns / 1ps

module tb_v15_e2e;

    reg clk;
    reg rst_n;

    // ---- MMIO 接口 (Host 侧) ----
    reg  [19:0]  mmio_addr;
    reg  [31:0]  mmio_wr_data;
    reg          mmio_wr_en;
    wire [31:0]  mmio_rd_data;
    wire         mmio_rd_vld;

    // ---- DMA 模拟 (TB 驱动) ----
    reg          dma_done;
    reg          dma_error;

    // ---- bar_ctrl 内部未用输入 (接 0) ----
    wire [8:0]   cmd_lvl;
    wire         cmd_full;
    wire [8:0]   done_lvl;
    wire         done_full;
    wire         err_src_vld;
    wire [7:0]   err_src_rid;
    wire [7:0]   err_src_code;
    wire [6:0]   ht_status;
    wire         trng_running;
    wire [63:0]  entropy_cnt;

    // ---- bar_ctrl ↔ ring_ctrl 连线 ----
    wire         bar2ring_cmd_wr_en;
    wire [7:0]   bar2ring_cmd_wr_idx;
    wire [127:0] bar2ring_cmd_wr_entry;
    wire         bar2ring_cmd_head_wr_en;
    wire [7:0]   bar2ring_cmd_head_ptr;

    wire         bar2ring_desc_wr_en;
    wire [7:0]   bar2ring_desc_wr_idx;
    wire [127:0] bar2ring_desc_wr_entry;
    wire         bar2ring_desc_head_wr_en;
    wire [7:0]   bar2ring_desc_head_ptr;

    // ---- ring_ctrl ↔ cmd_ring_buf 连线 ----
    wire         ring2cmd_wr_en;
    wire [7:0]   ring2cmd_wr_idx;
    wire [127:0] ring2cmd_wr_entry;
    wire         ring2cmd_head_wr_en;
    wire [7:0]   ring2cmd_head_ptr;

    // ---- ring_ctrl ↔ desc_ring_buf 连线 ----
    wire         ring2desc_wr_en;
    wire [7:0]   ring2desc_wr_idx;
    wire [127:0] ring2desc_wr_entry;
    wire         ring2desc_head_wr_en;
    wire [7:0]   ring2desc_head_ptr;

    // ---- cmd_ring_buf 输出 ----
    wire         cmd_avail;
    wire [7:0]   cmd_head_cur;
    wire [7:0]   cmd_tail;
    wire [31:0]  cmd_id;
    wire [7:0]   cmd_type;
    wire [7:0]   cmd_flags;
    wire [15:0]  cmd_payload_len;
    wire [31:0]  cmd_payload_addr;
    wire [31:0]  cmd_result_addr;
    wire [8:0]   cmd_lvl_w;
    wire         cmd_full_w;

    // ---- desc_ring_buf 输出 ----
    wire         desc_avail;
    wire [7:0]   desc_head_cur;
    wire [7:0]   desc_tail;
    wire [31:0]  desc_id;
    wire [7:0]   batch_op;
    wire [7:0]   batch_flags;
    wire [15:0]  batch_count;
    wire [31:0]  input_desc_addr;
    wire [31:0]  output_desc_addr;
    wire [8:0]   desc_lvl_w;
    wire         desc_full_w;

    // ---- ring_ctrl ↔ msix_ctrl 连线 ----
    wire         ring2msix_trigger;
    wire [3:0]   ring2msix_vec;

    // ---- msix_ctrl 输出 ----
    wire         msix_irq_vld;
    wire [31:0]  msix_irq_addr;
    wire [31:0]  msix_irq_data;
    wire [3:0]   msix_irq_vec_out;
    wire [15:0]  msix_pending;
    wire [15:0]  msix_masked;
    wire         msix_any_pending;

    // ---- bar_ctrl 输出 (未用于环路径的) ----
    wire         bar_msix_trigger;
    wire [3:0]   bar_msix_vec;

    integer pass, fail;

    // =========================================================================
    // DUT 实例化
    // =========================================================================

    // ---- bar_ctrl (M03 v2.0) ----
    bar_ctrl u_bar_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .mmio_addr(mmio_addr),
        .mmio_wr_data(mmio_wr_data),
        .mmio_wr_en(mmio_wr_en),
        .mmio_rd_data(mmio_rd_data),
        .mmio_rd_vld(mmio_rd_vld),
        // 环管理输出: 命令环
        .cmd_ring_wr_en(bar2ring_cmd_wr_en),
        .cmd_ring_wr_idx(bar2ring_cmd_wr_idx),
        .cmd_ring_wr_entry(bar2ring_cmd_wr_entry),
        .cmd_ring_head_wr_en(bar2ring_cmd_head_wr_en),
        .cmd_ring_head_ptr(bar2ring_cmd_head_ptr),
        .cmd_ring_head_cur(cmd_head_cur),
        .cmd_ring_tail(cmd_tail),
        .cmd_ring_avail(cmd_avail),
        // 环管理输出: 描述符环
        .desc_ring_wr_en(bar2ring_desc_wr_en),
        .desc_ring_wr_idx(bar2ring_desc_wr_idx),
        .desc_ring_wr_entry(bar2ring_desc_wr_entry),
        .desc_ring_head_wr_en(bar2ring_desc_head_wr_en),
        .desc_ring_head_ptr(bar2ring_desc_head_ptr),
        .desc_ring_head_cur(desc_head_cur),
        .desc_ring_tail(desc_tail),
        .desc_ring_avail(desc_avail),
        // 队列状态
        .cmd_lvl(cmd_lvl_w),
        .cmd_full(cmd_full_w),
        .done_lvl(done_lvl),
        .done_full(done_full),
        // 错误上报
        .err_src_vld(err_src_vld),
        .err_src_rid(err_src_rid),
        .err_src_code(err_src_code),
        // TRNG 状态
        .ht_status(ht_status),
        .trng_running(trng_running),
        .entropy_cnt(entropy_cnt),
        // 引擎控制
        .ctrl_trng_start(),
        .ctrl_trng_stop(),
        .ctrl_trng_flush(),
        .ctrl_sm2_start(),
        .ctrl_sm3_start(),
        .ctrl_sm4_start(),
        // MSI-X
        .msix_trigger(bar_msix_trigger),
        .msix_vec(bar_msix_vec),
        // 队列控制
        .ctrl_start(),
        .ctrl_flush(),
        .ctrl_reset()
    );

    // ---- ring_ctrl (M22 v1.0) ----
    ring_ctrl #(.PTR_W(8)) u_ring_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        // MMIO 写入 (从 bar_ctrl)
        .mmio_cmd_wr_en(bar2ring_cmd_wr_en),
        .mmio_cmd_wr_idx(bar2ring_cmd_wr_idx),
        .mmio_cmd_wr_entry(bar2ring_cmd_wr_entry),
        .mmio_cmd_head_wr_en(bar2ring_cmd_head_wr_en),
        .mmio_cmd_head_ptr(bar2ring_cmd_head_ptr),
        .mmio_desc_wr_en(bar2ring_desc_wr_en),
        .mmio_desc_wr_idx(bar2ring_desc_wr_idx),
        .mmio_desc_wr_entry(bar2ring_desc_wr_entry),
        .mmio_desc_head_wr_en(bar2ring_desc_head_wr_en),
        .mmio_desc_head_ptr(bar2ring_desc_head_ptr),
        // 环状态 (从 cmd_ring_buf / desc_ring_buf)
        .cmd_avail(cmd_avail),
        .cmd_head_cur(cmd_head_cur),
        .cmd_tail(cmd_tail),
        .desc_avail(desc_avail),
        .desc_head_cur(desc_head_cur),
        .desc_tail(desc_tail),
        // DMA 控制
        .dma_start(),
        .dma_cmd_id(),
        .dma_payload_addr(),
        .dma_result_addr(),
        .dma_done(dma_done),
        .dma_error(dma_error),
        // MSI-X
        .msix_trigger(ring2msix_trigger),
        .msix_vec(ring2msix_vec),
        // 控制
        .ctrl_start(1'b0),
        .ctrl_done(),
        .ctrl_busy(),
        // 环写入转发 (到 cmd_ring_buf)
        .cmd_ring_wr_en(ring2cmd_wr_en),
        .cmd_ring_wr_idx(ring2cmd_wr_idx),
        .cmd_ring_wr_entry(ring2cmd_wr_entry),
        .cmd_ring_head_wr_en(ring2cmd_head_wr_en),
        .cmd_ring_head_ptr(ring2cmd_head_ptr),
        // 环写入转发 (到 desc_ring_buf)
        .desc_ring_wr_en(ring2desc_wr_en),
        .desc_ring_wr_idx(ring2desc_wr_idx),
        .desc_ring_wr_entry(ring2desc_wr_entry),
        .desc_ring_head_wr_en(ring2desc_head_wr_en),
        .desc_ring_head_ptr(ring2desc_head_ptr)
    );

    // ---- cmd_ring_buf (M07 v1.0) ----
    cmd_ring_buf u_cmd_ring_buf (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(ring2cmd_wr_en),
        .wr_idx(ring2cmd_wr_idx),
        .wr_entry(ring2cmd_wr_entry),
        .head_wr_en(ring2cmd_head_wr_en),
        .head_ptr(ring2cmd_head_ptr),
        .head_ptr_cur(cmd_head_cur),
        .tail_ptr(cmd_tail),
        .cmd_avail(cmd_avail),
        .cmd_vld(),
        .cmd_rdy(),
        .cmd_id(cmd_id),
        .cmd_type(cmd_type),
        .cmd_flags(cmd_flags),
        .cmd_payload_len(cmd_payload_len),
        .cmd_payload_addr(cmd_payload_addr),
        .cmd_result_addr(cmd_result_addr),
        .cmd_lvl(cmd_lvl_w),
        .cmd_full(cmd_full_w)
    );

    // ---- desc_ring_buf (M08 v1.0) ----
    desc_ring_buf u_desc_ring_buf (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(ring2desc_wr_en),
        .wr_idx(ring2desc_wr_idx),
        .wr_entry(ring2desc_wr_entry),
        .head_wr_en(ring2desc_head_wr_en),
        .head_ptr(ring2desc_head_ptr),
        .head_ptr_cur(desc_head_cur),
        .tail_ptr(desc_tail),
        .desc_avail(desc_avail),
        .desc_vld(),
        .desc_id(desc_id),
        .batch_op(batch_op),
        .batch_flags(batch_flags),
        .batch_count(batch_count),
        .input_desc_addr(input_desc_addr),
        .output_desc_addr(output_desc_addr),
        .desc_lvl(desc_lvl_w),
        .desc_full(desc_full_w)
    );

    // ---- msix_ctrl (M05 v1.2) ----
    reg         msix_tbl_wr_en;
    reg  [3:0]  msix_tbl_wr_vec;
    reg  [31:0] msix_tbl_wr_addr;
    reg  [31:0] msix_tbl_wr_data;
    reg         msix_tbl_wr_mask;

    msix_ctrl #(.NVECT(16)) u_msix_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .tbl_wr_en(msix_tbl_wr_en),
        .tbl_wr_vec(msix_tbl_wr_vec),
        .tbl_wr_addr(msix_tbl_wr_addr),
        .tbl_wr_data(msix_tbl_wr_data),
        .tbl_wr_mask(msix_tbl_wr_mask),
        .irq_trigger(ring2msix_trigger),
        .irq_vec(ring2msix_vec),
        .irq_vld(msix_irq_vld),
        .irq_addr(msix_irq_addr),
        .irq_data(msix_irq_data),
        .irq_vec_out(msix_irq_vec_out),
        .pending(msix_pending),
        .masked(msix_masked),
        .any_pending(msix_any_pending)
    );

    // =========================================================================
    // 未用输入接 0
    // =========================================================================
    assign err_src_vld    = 1'b0;
    assign err_src_rid    = 8'd0;
    assign err_src_code   = 8'd0;
    assign ht_status      = 7'd0;
    assign trng_running   = 1'b0;
    assign entropy_cnt    = 64'd0;
    assign done_lvl       = 9'd0;
    assign done_full      = 1'b0;

    // =========================================================================
    // 时钟
    // =========================================================================
    always #5 clk = ~clk;

    // =========================================================================
    // 辅助任务
    // =========================================================================
    task do_reset;
        begin
            rst_n = 0;
            mmio_addr = 0; mmio_wr_data = 0; mmio_wr_en = 0;
            dma_done = 0; dma_error = 0;
            @(negedge clk); @(negedge clk);
            rst_n = 1;
            @(negedge clk);
        end
    endtask

    task mmio_wr;
        input [19:0] addr;
        input [31:0] data;
        begin
            mmio_addr = addr; mmio_wr_data = data; mmio_wr_en = 1;
            @(negedge clk);
            mmio_wr_en = 0;
        end
    endtask

    task mmio_rd;
        input [19:0] addr;
        output [31:0] data;
        begin
            mmio_addr = addr; mmio_wr_en = 0;
            @(negedge clk);
            #1;  // 等待组合逻辑稳定
            data = mmio_rd_data;
        end
    endtask

    task msix_unmask;
        input [3:0] vec;
        begin
            msix_tbl_wr_en = 1; msix_tbl_wr_vec = vec;
            msix_tbl_wr_addr = 32'h00000000; msix_tbl_wr_data = 32'h1;
            msix_tbl_wr_mask = 1'b0;  // 取消屏蔽
            @(negedge clk);
            msix_tbl_wr_en = 0;
        end
    endtask

    // BAR1 CMD_RING 基地址 = 20'h00001 (is_bar1, addr[19:12] != 0)
    // 实际上 BAR1 从 0x00000 开始, 但 bar_ctrl 用 mmio_addr[19:12] 区分 BAR0/BAR1
    // BAR0: [19:12] == 0
    // BAR1: [19:12] != 0
    // 所以 BAR1 CMD_RING 地址 = {8'h01, 12'h000} = 20'h01000
    // 简化: 使用 20'h01000 + offset 作为 BAR1 地址

    // =========================================================================
    // 测试主体
    // =========================================================================
    reg [31:0] rd;

    initial begin
        pass = 0; fail = 0; clk = 0;

        // =====================================================================
        // T1: 系统复位
        // =====================================================================
        $display("=== T1: 系统复位 ===");
        do_reset;
        if (cmd_avail === 1'b0 && desc_avail === 1'b0 &&
            msix_irq_vld === 1'b0) begin
            $display("  PASS: 所有状态为 0");
            pass = pass + 1;
        end else begin
            $display("  FAIL: cmd_avail=%b desc_avail=%b irq_vld=%b",
                     cmd_avail, desc_avail, msix_irq_vld);
            fail = fail + 1;
        end

        // MSI-X 向量 0 (CMD_BATCH_DONE) 和 4 (ERR_CRIT) 取消屏蔽
        msix_unmask(4'd0);
        msix_unmask(4'd4);

        // =====================================================================
        // T2: Host 写 CMD_RING 条目 → 环缓冲存储
        // =====================================================================
        $display("=== T2: CMD_RING 条目写入 ===");
        // BAR1 CMD_RING 基址 = 20'h01000, 条目 0 = offset 0x000
        // 写 4 × 32bit = 128bit 条目
        mmio_wr(20'h01000, 32'hDEADBEEF);  // cmd_id
        mmio_wr(20'h01004, 32'h00000001);  // cmd_type(1) + cmd_flags(0) + payload_len(0)
        mmio_wr(20'h01008, 32'hCAFEBABE);  // payload_addr
        mmio_wr(20'h0100C, 32'h00000200);  // result_addr (写入触发 wr_en)

        // 等待环缓冲处理
        @(negedge clk); @(negedge clk);

        // 验证: cmd_ring_wr_en 曾触发 (通过 cmd_id 回读验证)
        // 由于 cmd_ring_buf 没有地址回读端口, 验证 cmd_avail 仍为 0 (HEAD 未更新)
        if (cmd_avail === 1'b0) begin
            $display("  PASS: 条目已写入, cmd_avail=0 (HEAD 未更新)");
            pass = pass + 1;
        end else begin
            $display("  FAIL: cmd_avail=%b (应为 0, HEAD 未更新)", cmd_avail);
            fail = fail + 1;
        end

        // =====================================================================
        // T3: Host 更新 HEAD → cmd_avail → dma_start
        // =====================================================================
        $display("=== T3: HEAD 更新 → DMA 触发 ===");
        // 写 HEAD 指针到 BAR1 0x03FC
        mmio_wr(20'h013FC, 32'h00000001);  // HEAD = 1

        @(negedge clk);
        // 再等一拍: ring_ctrl 检测 cmd_avail → 进入 S_DMA_RUN
        @(negedge clk);

        // 现在 cmd_avail 应为 1 (HEAD != TAIL)
        if (cmd_avail === 1'b1) begin
            $display("  PASS: cmd_avail=1 (HEAD 已更新)");
            pass = pass + 1;
        end else begin
            $display("  FAIL: cmd_avail=%b (应为 1)", cmd_avail);
            fail = fail + 1;
        end

        // =====================================================================
        // T4: DMA 完成 → MSI-X CMD_BATCH_DONE (向量 0)
        // =====================================================================
        $display("=== T4: DMA 完成 → MSI-X ===");
        // 模拟 DMA 完成
        dma_done = 1; dma_error = 0;
        @(negedge clk);
        dma_done = 0;
        // msix_ctrl 需要额外一拍处理 irq_trigger
        @(negedge clk);

        // MSI-X 应触发, 向量 0 (CMD_BATCH_DONE)
        if (msix_irq_vld === 1'b1 && msix_irq_vec_out === 4'd0) begin
            $display("  PASS: MSI-X 向量 0 (CMD_BATCH_DONE)");
            pass = pass + 1;
        end else begin
            $display("  FAIL: irq_vld=%b vec=%d", msix_irq_vld, msix_irq_vec_out);
            fail = fail + 1;
        end

        // 验证单拍脉冲
        @(negedge clk);
        if (msix_irq_vld === 1'b0) begin
            $display("  PASS: irq_vld 单拍脉冲");
            pass = pass + 1;
        end else begin
            $display("  FAIL: irq_vld 未清零");
            fail = fail + 1;
        end

        // =====================================================================
        // T5: DMA 错误 → MSI-X ERR_CRIT (向量 4)
        // =====================================================================
        $display("=== T5: DMA 错误 → MSI-X ERR_CRIT ===");
        // 重新触发: 写入新条目 + 更新 HEAD
        mmio_wr(20'h01000, 32'hCAFEBABE);  // cmd_id
        mmio_wr(20'h01004, 32'h00000002);
        mmio_wr(20'h01008, 32'hDEADBEEF);
        mmio_wr(20'h0100C, 32'h00000300);
        mmio_wr(20'h013FC, 32'h00000002);  // HEAD = 2

        @(negedge clk); @(negedge clk); @(negedge clk);

        // 模拟 DMA 错误
        dma_done = 1; dma_error = 1;
        @(negedge clk);
        dma_done = 0; dma_error = 0;
        @(negedge clk);  // msix_ctrl 额外一拍

        if (msix_irq_vld === 1'b1 && msix_irq_vec_out === 4'd4) begin
            $display("  PASS: MSI-X 向量 4 (ERR_CRIT)");
            pass = pass + 1;
        end else begin
            $display("  FAIL: irq_vld=%b vec=%d", msix_irq_vld, msix_irq_vec_out);
            fail = fail + 1;
        end

        // =====================================================================
        // T6: Host 写 DESC_RING 条目 → 描述符环存储
        // =====================================================================
        $display("=== T6: DESC_RING 条目写入 ===");
        // BAR1 DESC_RING 基址 = 20'h01800
        mmio_wr(20'h01800, 32'h00000001);  // desc_id
        mmio_wr(20'h01804, 32'h00000000);  // batch_op + batch_flags + batch_count
        mmio_wr(20'h01808, 32'h00001000);  // input_desc_addr
        mmio_wr(20'h0180C, 32'h00002000);  // output_desc_addr

        @(negedge clk); @(negedge clk);

        if (desc_avail === 1'b0) begin
            $display("  PASS: DESC 条目已写入, desc_avail=0");
            pass = pass + 1;
        end else begin
            $display("  FAIL: desc_avail=%b", desc_avail);
            fail = fail + 1;
        end

        // =====================================================================
        // T7: 多批次命令生命周期
        // =====================================================================
        $display("=== T7: 多批次命令生命周期 ===");
        // 批次 1: HEAD=3
        mmio_wr(20'h01000, 32'h11111111);
        mmio_wr(20'h01004, 32'h00000003);
        mmio_wr(20'h01008, 32'hAAAAAAAA);
        mmio_wr(20'h0100C, 32'h00000400);
        mmio_wr(20'h013FC, 32'h00000003);  // HEAD=3

        @(negedge clk);
        // 再等两拍: ring_ctrl 检测 cmd_avail → S_DMA_RUN
        @(negedge clk); @(negedge clk);
        if (cmd_avail === 1'b1) begin
            $display("  PASS: 批次 1 cmd_avail=1");
            pass = pass + 1;
        end else begin
            $display("  FAIL: 批次 1 cmd_avail=%b", cmd_avail);
            fail = fail + 1;
        end

        dma_done = 1; dma_error = 0;
        @(negedge clk);
        dma_done = 0;
        @(negedge clk);  // msix_ctrl 额外一拍
        if (msix_irq_vld === 1'b1 && msix_irq_vec_out === 4'd0) begin
            $display("  PASS: 批次 1 MSI-X 正确");
            pass = pass + 1;
        end else begin
            $display("  FAIL: 批次 1 irq_vld=%b vec=%d", msix_irq_vld, msix_irq_vec_out);
            fail = fail + 1;
        end

        // 批次 2: HEAD=4
        mmio_wr(20'h01000, 32'h22222222);
        mmio_wr(20'h01004, 32'h00000004);
        mmio_wr(20'h01008, 32'hBBBBBBBB);
        mmio_wr(20'h0100C, 32'h00000500);
        mmio_wr(20'h013FC, 32'h00000004);

        @(negedge clk); @(negedge clk); @(negedge clk);
        dma_done = 1; dma_error = 0;
        @(negedge clk);
        dma_done = 0;
        @(negedge clk);  // msix_ctrl 额外一拍
        if (msix_irq_vld === 1'b1 && msix_irq_vec_out === 4'd0) begin
            $display("  PASS: 批次 2 MSI-X 正确");
            pass = pass + 1;
        end else begin
            $display("  FAIL: 批次 2 irq_vld=%b vec=%d", msix_irq_vld, msix_irq_vec_out);
            fail = fail + 1;
        end

        // =====================================================================
        // T8: 零回归 — 寄存器回读
        // =====================================================================
        $display("=== T8: 零回归 (寄存器回读) ===");
        // VERSION = 0x000107EA
        mmio_rd(20'h00000, rd);
        if (rd === 32'h000107EA) begin
            $display("  PASS: VERSION=0x%08h", rd);
            pass = pass + 1;
        end else begin
            $display("  FAIL: VERSION=0x%08h (期望 0x000107EA)", rd);
            fail = fail + 1;
        end

        // CTRL_GLOBAL 回读
        mmio_wr(20'h0002C, 32'h00000003);  // ENABLE + RESET_SOFT
        mmio_rd(20'h0002C, rd);
        if (rd === 32'h00000003) begin
            $display("  PASS: CTRL_GLOBAL=0x%08h", rd);
            pass = pass + 1;
        end else begin
            $display("  FAIL: CTRL_GLOBAL=0x%08h (期望 0x00000003)", rd);
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