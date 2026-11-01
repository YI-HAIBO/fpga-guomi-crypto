// =============================================================================
// 模块名称 : ring_ctrl
// 模块编号 : M22 (SS1 - PCIe Front-End)
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-09
// 视角     : rtl-designer (葛逻辑)
// 时钟     : clk (100 MHz)
//
// 功能     : 环管理与 MSI-X 触发协调模块。
//            替代 bar_ctrl 的 doorbell 逻辑，协调 CMD_RING / DESC_RING /
//            DMA / MSI-X 四个子系统。
//
// 数据流:
//   Host MMIO → bar_ctrl (译码) → ring_ctrl → cmd_ring_buf / desc_ring_buf
//   ring_ctrl → dma_start → dma_desc_engine → dma_done → msix_ctrl
//
// 状态机:
//   S_IDLE     : 等待命令环可用
//   S_DMA_RUN  : DMA 搬运中
//   S_DMA_DONE : DMA 完成, 触发 MSI-X
//
// 接口:
//   - MMIO 写入 (从 bar_ctrl): cmd/desc 环条目 + HEAD 更新
//   - 环状态 (从 cmd_ring_buf/desc_ring_buf): avail/tail/head_cur
//   - DMA 控制: dma_start, dma_done
//   - MSI-X: msix_trigger, msix_vec
//
// 编译     : iverilog -g2005
// =============================================================================

`timescale 1ns / 1ps

module ring_ctrl #(
    parameter PTR_W = 8          // 环指针宽度 (256 条目)
) (
    input  wire                  clk,
    input  wire                  rst_n,

    // ---- MMIO 写入 (从 bar_ctrl v2.0) ----
    input  wire                  mmio_cmd_wr_en,
    input  wire [PTR_W-1:0]      mmio_cmd_wr_idx,
    input  wire [127:0]          mmio_cmd_wr_entry,
    input  wire                  mmio_cmd_head_wr_en,
    input  wire [PTR_W-1:0]      mmio_cmd_head_ptr,

    input  wire                  mmio_desc_wr_en,
    input  wire [PTR_W-1:0]      mmio_desc_wr_idx,
    input  wire [127:0]          mmio_desc_wr_entry,
    input  wire                  mmio_desc_head_wr_en,
    input  wire [PTR_W-1:0]      mmio_desc_head_ptr,

    // ---- 环状态 (从 cmd_ring_buf / desc_ring_buf) ----
    input  wire                  cmd_avail,
    input  wire [PTR_W-1:0]      cmd_head_cur,
    input  wire [PTR_W-1:0]      cmd_tail,
    input  wire                  desc_avail,
    input  wire [PTR_W-1:0]      desc_head_cur,
    input  wire [PTR_W-1:0]      desc_tail,

    // ---- DMA 控制 ----
    output wire                  dma_start,        // 1 拍脉冲
    output wire [PTR_W-1:0]      dma_cmd_id,       // 当前 DMA 的 cmd_id
    output wire [31:0]           dma_payload_addr,
    output wire [31:0]           dma_result_addr,
    input  wire                  dma_done,         // DMA 完成 (1 拍脉冲)
    input  wire                  dma_error,        // DMA 错误

    // ---- MSI-X 触发 ----
    output wire                  msix_trigger,
    output wire [3:0]            msix_vec,

    // ---- 环写入转发 (到 cmd_ring_buf / desc_ring_buf) ----
    output wire                  cmd_ring_wr_en,
    output wire [PTR_W-1:0]      cmd_ring_wr_idx,
    output wire [127:0]          cmd_ring_wr_entry,
    output wire                  cmd_ring_head_wr_en,
    output wire [PTR_W-1:0]      cmd_ring_head_ptr,

    output wire                  desc_ring_wr_en,
    output wire [PTR_W-1:0]      desc_ring_wr_idx,
    output wire [127:0]          desc_ring_wr_entry,
    output wire                  desc_ring_head_wr_en,
    output wire [PTR_W-1:0]      desc_ring_head_ptr,

    // ---- 控制 ----
    input  wire                  ctrl_start,       // Host 启动批次
    output wire                  ctrl_done,        // 批次完成
    output wire                  ctrl_busy         // DMA 忙
);

    // =========================================================================
    // 状态机
    // =========================================================================
    localparam S_IDLE     = 2'd0;
    localparam S_DMA_RUN  = 2'd1;

    reg [1:0] state, state_nxt;

    // =========================================================================
    // 环写入转发 (pass-through from bar_ctrl to ring buffers)
    // =========================================================================
    // 直接转发 MMIO 写入脉冲，不修改
    // (ring_buf 内部管理 HEAD/TAIL)

    // =========================================================================
    // DMA 触发逻辑
    // =========================================================================
    // 当 cmd_avail 且空闲时触发 DMA
    reg  dma_start_r;
    reg  [PTR_W-1:0] dma_cmd_id_r;
    reg  [31:0]      dma_payload_addr_r;
    reg  [31:0]      dma_result_addr_r;

    // =========================================================================
    // MSI-X 触发
    // =========================================================================
    reg  msix_trigger_r;
    reg  [3:0] msix_vec_r;

    // =========================================================================
    // 控制输出
    // =========================================================================
    reg  ctrl_done_r;
    reg  ctrl_busy_r;

    // 消费标志: DMA 完成后置 1, 主机更新 HEAD 后清 0
    // 防止 cmd_avail 仍为 1 时连续重触发 DMA
    reg  consumed;

    // =========================================================================
    // 状态机 + DMA + MSI-X 主逻辑
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            consumed        <= 0;
            dma_start_r     <= 0;
            dma_cmd_id_r    <= 0;
            dma_payload_addr_r <= 0;
            dma_result_addr_r  <= 0;
            msix_trigger_r  <= 0;
            msix_vec_r      <= 0;
            ctrl_done_r     <= 0;
            ctrl_busy_r     <= 0;
        end else begin
            // 默认清零脉冲
            dma_start_r     <= 0;
            msix_trigger_r  <= 0;
            ctrl_done_r     <= 0;

            // 主机更新 HEAD → 清除消费标志 (允许下一次 DMA 触发)
            if (mmio_cmd_head_wr_en) begin
                consumed <= 0;
            end

            case (state)
                // --------------------------------------------------------
                S_IDLE: begin
                    ctrl_busy_r <= 0;
                    if (cmd_avail && !consumed) begin
                        // 检测到命令环可用且未消费 → 启动 DMA
                        dma_start_r     <= 1;
                        dma_cmd_id_r    <= cmd_head_cur;
                        ctrl_busy_r     <= 1;
                        state           <= S_DMA_RUN;
                    end
                end

                // --------------------------------------------------------
                S_DMA_RUN: begin
                    ctrl_busy_r <= 1;
                    if (dma_done) begin
                        consumed <= 1;
                        if (dma_error) begin
                            // DMA 错误 → MSI-X ERR_CRIT (向量 4)
                            msix_trigger_r <= 1;
                            msix_vec_r     <= 4'd4;
                            ctrl_done_r    <= 1;
                        end else begin
                            // DMA 正常完成 → MSI-X CMD_BATCH_DONE (向量 0)
                            msix_trigger_r <= 1;
                            msix_vec_r     <= 4'd0;
                            ctrl_done_r    <= 1;
                        end
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // 输出
    // =========================================================================
    // 环写入转发 (直通)
    assign cmd_ring_wr_en      = mmio_cmd_wr_en;
    assign cmd_ring_wr_idx     = mmio_cmd_wr_idx;
    assign cmd_ring_wr_entry   = mmio_cmd_wr_entry;
    assign cmd_ring_head_wr_en = mmio_cmd_head_wr_en;
    assign cmd_ring_head_ptr   = mmio_cmd_head_ptr;

    assign desc_ring_wr_en      = mmio_desc_wr_en;
    assign desc_ring_wr_idx     = mmio_desc_wr_idx;
    assign desc_ring_wr_entry   = mmio_desc_wr_entry;
    assign desc_ring_head_wr_en = mmio_desc_head_wr_en;
    assign desc_ring_head_ptr   = mmio_desc_head_ptr;

    // DMA 控制
    assign dma_start       = dma_start_r;
    assign dma_cmd_id      = dma_cmd_id_r;
    assign dma_payload_addr = dma_payload_addr_r;
    assign dma_result_addr  = dma_result_addr_r;

    // MSI-X
    assign msix_trigger = msix_trigger_r;
    assign msix_vec     = msix_vec_r;

    // 控制
    assign ctrl_done  = ctrl_done_r;
    assign ctrl_busy  = ctrl_busy_r;

endmodule