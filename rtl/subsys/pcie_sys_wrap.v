// =============================================================================
// 模块名称 : pcie_sys_wrap
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 日期     : 2026-10-11
// 视角     : fpga-fullflow-lead (齐流晶)
//
// 用途     : Vivado 综合/实现签核用顶层 wrapper。
//            pcie_front_subsys 的全部端口 (21 个, 共 813 位) 在此内部化:
//   - input 由内部 PRNG 寄存器驱动 (非常数, 防止综合常数传播优化掉内部逻辑)
//   - output 接内部 wire 并加 keep 属性, 防止综合裁剪
//   - DUT 整体 DONT_TOUCH, 保留完整网表用于面积/时序评估
//            顶层对外只暴露 clk / rst_n, 消除综合阶段 Bonded IOB 285% 的假象
//            (未分配管脚的 813 位端口全部变成内部网络)。
//
// 注意     : 本 wrapper 仅用于面积/时序签核, 不用于功能仿真。
//            功能验证直接用 pcie_front_subsys + 系统级 TB。
// 编译     : iverilog -g2005 / Vivado 2026.1
// =============================================================================

`timescale 1ns / 1ps

module pcie_sys_wrap (
    input  wire         clk,
    input  wire         rst_n
);

    // =========================================================================
    // 内部激励 (模拟 Host MMIO / PCIe IP 侧驱动)
    //   用 PRNG 产生活动信号, 避免综合器常数传播裁剪内部逻辑
    // =========================================================================
    reg [31:0] prng;
    reg [19:0] s_mmio_addr;
    reg [31:0] s_mmio_wr_data;
    reg        s_mmio_wr_en;
    reg        s_dma_wr_rdy;

    always @(posedge clk) begin
        if (!rst_n) begin
            prng          <= 32'hCAFEBABE;
            s_mmio_addr    <= 20'd0;
            s_mmio_wr_data <= 32'd0;
            s_mmio_wr_en   <= 1'b0;
            s_dma_wr_rdy   <= 1'b0;
        end else begin
            // 32-bit LFSR (x^32 + x^22 + x^2 + x + 1, Fibonacci)
            prng          <= {prng[30:0], prng[31] ^ prng[21] ^ prng[1]};
            s_mmio_addr    <= prng[19:0];
            s_mmio_wr_data <= prng;
            s_mmio_wr_en   <= prng[0];
            s_dma_wr_rdy   <= prng[1];
        end
    end

    // =========================================================================
    // 输出读回线 (keep 防优化)
    // =========================================================================
    (* keep = "true" *) wire [31:0]  s_mmio_rd_data;
    (* keep = "true" *) wire         s_mmio_rd_vld;
    (* keep = "true" *) wire         s_dma_wr_vld;
    (* keep = "true" *) wire [63:0]  s_dma_wr_desc;
    (* keep = "true" *) wire [511:0] s_dma_wr_data;
    (* keep = "true" *) wire [7:0]   s_dma_wr_rid;
    (* keep = "true" *) wire [7:0]   s_dma_wr_err;
    (* keep = "true" *) wire         s_dma_wr_ok;
    (* keep = "true" *) wire         s_msix_irq_vld;
    (* keep = "true" *) wire [31:0]  s_msix_irq_addr;
    (* keep = "true" *) wire [31:0]  s_msix_irq_data;
    (* keep = "true" *) wire [3:0]   s_msix_irq_vec;
    (* keep = "true" *) wire [15:0]  s_msix_pending;
    (* keep = "true" *) wire [15:0]  s_msix_masked;
    (* keep = "true" *) wire         s_msix_any_pending;
    (* keep = "true" *) wire [8:0]   s_cmd_ring_lvl;
    (* keep = "true" *) wire [8:0]   s_desc_ring_lvl;
    (* keep = "true" *) wire [4:0]   s_cmd_queue_lvl;
    (* keep = "true" *) wire [4:0]   s_done_queue_lvl;

    // =========================================================================
    // DUT (整体保留, 不允许综合优化内部)
    // =========================================================================
    (* DONT_TOUCH = "true" *)
    pcie_front_subsys u_dut (
        .clk              (clk),
        .rst_n            (rst_n),

        // 主机 MMIO 接口
        .mmio_addr        (s_mmio_addr),
        .mmio_wr_data     (s_mmio_wr_data),
        .mmio_wr_en       (s_mmio_wr_en),
        .mmio_rd_data     (s_mmio_rd_data),
        .mmio_rd_vld      (s_mmio_rd_vld),

        // DMA 写回通道
        .dma_wr_vld       (s_dma_wr_vld),
        .dma_wr_rdy       (s_dma_wr_rdy),
        .dma_wr_desc      (s_dma_wr_desc),
        .dma_wr_data      (s_dma_wr_data),
        .dma_wr_rid       (s_dma_wr_rid),
        .dma_wr_err       (s_dma_wr_err),
        .dma_wr_ok        (s_dma_wr_ok),

        // MSI-X 中断输出
        .msix_irq_vld     (s_msix_irq_vld),
        .msix_irq_addr    (s_msix_irq_addr),
        .msix_irq_data    (s_msix_irq_data),
        .msix_irq_vec     (s_msix_irq_vec),
        .msix_pending     (s_msix_pending),
        .msix_masked      (s_msix_masked),
        .msix_any_pending (s_msix_any_pending),

        // 状态指示
        .cmd_ring_lvl     (s_cmd_ring_lvl),
        .desc_ring_lvl    (s_desc_ring_lvl),
        .cmd_queue_lvl    (s_cmd_queue_lvl),
        .done_queue_lvl   (s_done_queue_lvl)
    );

endmodule
