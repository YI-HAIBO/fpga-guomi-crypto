// =============================================================================
// 模块名称 : msix_ctrl
// 模块编号 : M05 (SS1 - PCIe Front-End, 见 phase1/架构与模块划分说明书_v1.md §2.1)
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.2
// 日期     : 2026-10-09
// 视角     : rtl-designer (葛逻辑)
// 时钟     : clk_l400
//
// 功能     : MSI-X 中断控制器。管理中断向量表 (消息表 + PBA 挂起表),
//            触发 MSI-X 消息 (写主机内存的地址+数据), 支持中断挂起与清除。
//
// 向量表 (16 个向量, 每向量 64-bit):
//   消息表: [31:0] = 中断地址, [63:32] = 中断数据 (payload)
//   PBA:    [0]    = 挂起标志 (1=有中断待发送)
//
// 向量分配:
//   0=CMD_BATCH_DONE  1=DESC_BATCH_DONE  2=TRNG_READY
//   3=ERR_WARN        4=ERR_CRIT         5-15=DESC_RING
//
// 接口:
//   - 主机通过 BAR1 MMIO 写入向量表 (地址/数据/使能)
//   - DMA 完成或错误发生时触发中断 (irq_trigger)
//   - 中断消息经 PCIe 写请求发送到主机 (irq_vld + irq_addr + irq_data)
//
// 编译     : iverilog -g2005
// =============================================================================

`timescale 1ns / 1ps

module msix_ctrl #(
    parameter NVECT      = 16,
    parameter VEC_ADR_W  = 32,
    parameter VEC_DAT_W  = 32
) (
    input  wire                  clk,
    input  wire                  rst_n,

    // ---- 向量表编程 (从 bar_ctrl MMIO) ----
    input  wire                  tbl_wr_en,
    input  wire [3:0]            tbl_wr_vec,     // 向量号 0..15
    input  wire [VEC_ADR_W-1:0]  tbl_wr_addr,    // 消息地址
    input  wire [VEC_DAT_W-1:0]  tbl_wr_data,    // 消息数据
    input  wire                  tbl_wr_mask,    // 使能/屏蔽 (1=屏蔽)

    // ---- 中断触发 (从 dma_desc_engine / bar_ctrl) ----
    input  wire                  irq_trigger,    // 1 拍脉冲
    input  wire [3:0]            irq_vec,        // 中断向量号

    // ---- 中断消息输出 (模拟 PCIe 写请求) ----
    output reg                   irq_vld,        // 中断有效 (1 拍脉冲)
    output reg  [VEC_ADR_W-1:0]  irq_addr,       // 中断地址
    output reg  [VEC_DAT_W-1:0]  irq_data,       // 中断数据
    output reg  [3:0]            irq_vec_out,    // 中断向量号

    // ---- 挂起状态 ----
    output wire [15:0]           pending,        // 各向量挂起状态
    output wire [15:0]           masked,         // 各向量屏蔽状态
    output wire                  any_pending     // 有任一挂起
);

    // =========================================================================
    // 常量
    // =========================================================================
    localparam NVECT_S  = (NVECT < 16) ? 16 : NVECT;

    // =========================================================================
    // 向量表存储
    // =========================================================================
    reg [VEC_ADR_W-1:0] vec_addr  [0:NVECT_S-1];
    reg [VEC_DAT_W-1:0] vec_data  [0:NVECT_S-1];
    reg                 vec_mask  [0:NVECT_S-1];   // 1=屏蔽
    reg                 vec_pend  [0:NVECT_S-1];   // 1=挂起

    // =========================================================================
    // 向量表写入 + 初始复位
    // =========================================================================
    integer i_init;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i_init = 0; i_init < NVECT_S; i_init = i_init + 1) begin
                vec_addr[i_init] = {24'd0, i_init[3:0], 1'b0, 1'b0};
                vec_data[i_init] = 32'd1;
                vec_mask[i_init] = 1;
                vec_pend[i_init] = 0;
            end
        end else begin
            if (tbl_wr_en && (tbl_wr_vec < 16)) begin
                vec_addr[tbl_wr_vec]  <= tbl_wr_addr;
                vec_data[tbl_wr_vec]  <= tbl_wr_data;
                vec_mask[tbl_wr_vec]  <= tbl_wr_mask;
            end
            // 中断触发: 未屏蔽则发送, 屏蔽则挂起
            if (irq_trigger && (irq_vec < 16)) begin
                if (!vec_mask[irq_vec]) begin
                    vec_pend[irq_vec] <= 0;
                end else begin
                    vec_pend[irq_vec] <= 1;
                end
            end
        end
    end

    // =========================================================================
    // 中断消息输出 (1 拍脉冲)
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            irq_vld     <= 0;
            irq_addr    <= 0;
            irq_data    <= 0;
            irq_vec_out <= 0;
        end else begin
            irq_vld <= 0;
            if (irq_trigger && (irq_vec < 16) && !vec_mask[irq_vec]) begin
                irq_vld     <= 1;
                irq_addr    <= vec_addr[irq_vec];
                irq_data    <= vec_data[irq_vec];
                irq_vec_out <= irq_vec;
            end
        end
    end

    // =========================================================================
    // 状态输出
    // =========================================================================
    reg [15:0] pend_bus;
    reg [15:0] mask_bus;
    integer i_bus;
    always @(*) begin
        for (i_bus = 0; i_bus < NVECT_S; i_bus = i_bus + 1) begin
            pend_bus[i_bus] = vec_pend[i_bus];
            mask_bus[i_bus] = vec_mask[i_bus];
        end
    end

    assign pending     = pend_bus;
    assign masked      = mask_bus;
    assign any_pending = |pend_bus;

endmodule
