// =============================================================================
// 模块名称 : pcie_front_subsys_light
// 项目     : GM-CRYPTO-COORD-2026 - v1.5 轻量全系统综合验证
// 版本     : v1.0
// 日期     : 2026-10-10
// 功能     : 仅包装 v1.5 前端模块 (不含真实调度器/引擎), 用于快速综合签核
// =============================================================================
`timescale 1ns / 1ps

module pcie_front_subsys_light (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [19:0]  mmio_addr,
    input  wire [31:0]  mmio_wr_data,
    input  wire         mmio_wr_en,
    output wire [31:0]  mmio_rd_data,
    output wire         mmio_rd_vld,
    output wire         dma_wr_vld,
    input  wire         dma_wr_rdy,
    output wire [63:0]  dma_wr_desc,
    output wire [511:0] dma_wr_data,
    output wire [7:0]   dma_wr_rid,
    output wire [7:0]   dma_wr_err,
    output wire         dma_wr_ok,
    output wire         msix_irq_vld,
    output wire [31:0]  msix_irq_addr,
    output wire [31:0]  msix_irq_data,
    output wire [3:0]   msix_irq_vec,
    output wire [15:0]  msix_pending,
    output wire [15:0]  msix_masked,
    output wire         msix_any_pending
);

    // 内部连线
    wire [8:0]  cmd_ring_lvl;
    wire [8:0]  desc_ring_lvl;
    wire [4:0]  cmd_queue_lvl;
    wire [4:0]  done_queue_lvl;

    pcie_front_subsys u_dut (
        .clk(clk), .rst_n(rst_n),
        .mmio_addr(mmio_addr),
        .mmio_wr_data(mmio_wr_data),
        .mmio_wr_en(mmio_wr_en),
        .mmio_rd_data(mmio_rd_data),
        .mmio_rd_vld(mmio_rd_vld),
        .dma_wr_vld(dma_wr_vld),
        .dma_wr_rdy(dma_wr_rdy),
        .dma_wr_desc(dma_wr_desc),
        .dma_wr_data(dma_wr_data),
        .dma_wr_rid(dma_wr_rid),
        .dma_wr_err(dma_wr_err),
        .dma_wr_ok(dma_wr_ok),
        .msix_irq_vld(msix_irq_vld),
        .msix_irq_addr(msix_irq_addr),
        .msix_irq_data(msix_irq_data),
        .msix_irq_vec(msix_irq_vec),
        .msix_pending(msix_pending),
        .msix_masked(msix_masked),
        .msix_any_pending(msix_any_pending),
        .cmd_ring_lvl(cmd_ring_lvl),
        .desc_ring_lvl(desc_ring_lvl),
        .cmd_queue_lvl(cmd_queue_lvl),
        .done_queue_lvl(done_queue_lvl)
    );

endmodule