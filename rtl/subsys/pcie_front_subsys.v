// =============================================================================
// 模块名称 : pcie_front_subsys
// 模块编号 : SS1 (Phase 2.8 - PCIe Front-End 顶层)
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.2 (已废弃 / DEPRECATED)
// 日期     : 2026-10-03
// =============================================================================
// 【废弃说明 2026-10-11】
//   本文件为 Phase 2.8 时期的队列接口版本。bar_ctrl 升级到 v2.0 环缓冲
//   接口 (cmd_ring_*/desc_ring_*) 后, 本文件第 178 行的 u_bar_ctrl 例化仍
//   使用已删除的 cmd_wr_en/cmd_rid/cmd_op/cmd_prio/cmd_ia/cmd_ib/cmd_ic
//   端口, iverilog elaboration 报 7 个 "port is not a port of u_bar_ctrl",
//   无法编译。该缺陷自 bar_ctrl v2.0 起即存在, 与 Phase 8 (共享 montmul)
//   无关。
//   现行交付路径为 pcie_front_subsys_v15.v (环缓冲 + ring_ctrl 架构),
//   由 pcie_sys_wrap 顶层例化, 全链路 E2E 由 sim/subsys/tb_v15_e2e.v
//   覆盖 (run_v15_extra.py / run_fix_regress.py)。本文件仅作历史留档,
//   不参与任何仿真与综合, 请勿在其上继续修改。
// =============================================================================
// 变更记录 :
//   v1.0 2026-10-03 首版
//   v1.1 2026-10-03 MSI-X 向量表 BAR1 解码由 mmio_addr[2:0] 改为 [3:0]:
//                  0x300/0x304/0x308 是字节地址, 旧解码把 0x308 落到 addr
//                  分支, 屏蔽位永远写不进 -> vec_mask[0] 恒为 1, 中断永久屏蔽
//                  (Phase 2.8c E2E 首跑 6 次 wait_msix 全超时的根因)
//   v1.2 2026-10-03 CTRL_RESET (0x108) 对外脉冲回接上游内核:
//                  新增 soft_rst_n 生成器, bc_ctrl_reset 脉冲触发
//                  soft_rst_n 低电平 1 拍, OR 进主 rst_n 后传给
//                  crypto_sched_subsys / cmd_queue_buf / dma_desc_engine

// 视角     : fpga-fullflow-lead (齐流晶)
//
// 功能     : SS1 PCIe 前端子系统顶层, 集成:
//   - M03  bar_ctrl        : BAR0/BAR1 寄存器与命令 shadow 捕获
//   - M21  cmd_queue_buf   : 命令队列 (16 深度 FIFO, 256/256/256)
//   - SS2  crypto_sched_subsys : 命令调度器 + 2 引擎
//   - M04  dma_desc_engine : 结果收集 + DMA 描述符打包
//   - M05  msix_ctrl       : MSI-X 中断控制器
//
// 数据通路:
//   [Host MMIO] --BAR0--> bar_ctrl (shadow 捕获)
//                       --CTRL_START-- cmd_wr_en --> cmd_queue_buf (入队)
//                          cmd_queue_buf (o_vld/rdy) --> crypto_sched_subsys
//                          crypto_sched_subsys (res_vld) --> dma_desc_engine
//                          dma_desc_engine (dma_wr_vld) --> [Host DMA 写回]
//                          dma_desc_engine (irq_trigger) --> msix_ctrl
//                          msix_ctrl (irq_vld) --> [PCIe MSI-X 消息]
//
// 编译     : iverilog -g2005
// =============================================================================

`timescale 1ns / 1ps

module pcie_front_subsys (
    input  wire         clk,
    input  wire         rst_n,

    // ---- 主机 MMIO 接口 (AXI4-Lite) ----
    input  wire [11:0]  mmio_addr,
    input  wire [31:0]  mmio_wr_data,
    input  wire         mmio_wr_en,
    output wire [31:0]  mmio_rd_data,
    output wire         mmio_rd_vld,

    // ---- BAR0 shadow 回读 (供主机校验) ----
    output wire [31:0]  bar0_head_shadow,
    output wire [255:0] bar0_ia_shadow,
    output wire [255:0] bar0_ib_shadow,
    output wire [255:0] bar0_ic_shadow,

    // ---- DMA 写回通道 (模拟 PCIe 写请求) ----
    output wire         dma_wr_vld,
    input  wire         dma_wr_rdy,
    output wire [63:0]  dma_wr_desc,
    output wire [511:0] dma_wr_data,
    output wire [7:0]   dma_wr_rid,
    output wire [7:0]   dma_wr_err,
    output wire         dma_wr_ok,

    // ---- MSI-X 中断输出 ----
    output wire         msix_irq_vld,
    output wire [31:0]  msix_irq_addr,
    output wire [31:0]  msix_irq_data,
    output wire [3:0]   msix_irq_vec,
    output wire [7:0]   msix_pending,
    output wire [7:0]   msix_masked,
    output wire         msix_any_pending,

    // ---- 状态指示 ----
    output wire [4:0]   cmd_queue_lvl,
    output wire [4:0]   done_queue_lvl
);

    // =========================================================================
    // 内部连线: bar_ctrl <-> cmd_queue_buf
    // =========================================================================
    wire        bc_cmd_wr_en;
    wire [7:0]  bc_cmd_rid;
    wire [3:0]  bc_cmd_op;
    wire [1:0]  bc_cmd_prio;
    wire [255:0] bc_cmd_ia;
    wire [255:0] bc_cmd_ib;
    wire [255:0] bc_cmd_ic;
    wire        bc_ctrl_start;
    wire        bc_ctrl_flush;
    wire        bc_ctrl_reset;

    // =========================================================================
    // CTRL_RESET 脉冲回接: bc_ctrl_reset -> soft_rst_n -> 下游内核
    // =========================================================================
    reg  soft_rst_n = 1'b1;
    always @(posedge clk) begin
        if (!rst_n)
            soft_rst_n <= 1'b1;
        else if (bc_ctrl_reset)
            soft_rst_n <= 1'b0;   // 拉低 1 拍
        else
            soft_rst_n <= 1'b1;
    end
    wire core_rst_n = rst_n & soft_rst_n;

    wire [8:0]  cq_lvl;
    wire        cq_empty;
    wire        cq_full;
    wire        cq_vld;
    wire        cq_rdy;
    wire [7:0]  cq_rid;
    wire [3:0]  cq_op;
    wire [1:0]  cq_prio;
    wire [255:0] cq_ia;
    wire [255:0] cq_ib;
    wire [255:0] cq_ic;

    // =========================================================================
    // 内部连线: cmd_queue_buf <-> crypto_sched_subsys
    // =========================================================================
    wire        sched_cmd_vld;
    wire        sched_cmd_rdy;
    wire [7:0]  sched_cmd_rid;
    wire [3:0]  sched_cmd_op;
    wire [1:0]  sched_cmd_prio;
    wire [511:0] sched_cmd_ia;
    wire [511:0] sched_cmd_ib;
    wire [255:0] sched_cmd_ic;

    wire        sched_res_vld;
    wire        sched_res_rdy;
    wire [7:0]  sched_res_rid;
    wire [7:0]  sched_res_err;
    wire        sched_res_ok;
    wire [255:0] sched_res_ra;
    wire [255:0] sched_res_rb;

    // =========================================================================
    // 内部连线: crypto_sched_subsys <-> dma_desc_engine
    // =========================================================================
    wire        de_res_vld;
    wire        de_res_rdy;
    wire [7:0]  de_res_rid;
    wire [7:0]  de_res_err;
    wire        de_res_ok;
    wire [255:0] de_res_ra;
    wire [255:0] de_res_rb;

    wire        de_dma_wr_vld;
    wire        de_dma_wr_rdy;
    wire [63:0] de_dma_wr_desc;
    wire [511:0] de_dma_wr_data;
    wire [7:0]  de_dma_wr_rid;
    wire [7:0]  de_dma_wr_err;
    wire        de_dma_wr_ok;
    wire [8:0]  de_cq_lvl;
    wire        de_cq_empty;
    wire        de_cq_full;

    // =========================================================================
    // 内部连线: dma_desc_engine <-> msix_ctrl
    // =========================================================================
    wire        msix_tbl_wr_en;
    wire [3:0]  msix_tbl_wr_vec;
    wire [31:0] msix_tbl_wr_addr;
    wire [31:0] msix_tbl_wr_data;
    wire        msix_tbl_wr_mask;

    wire        msix_irq_trigger;
    wire [3:0]  msix_irq_vec_in;

    // =========================================================================
    // bar_ctrl (M03)
    // =========================================================================
    bar_ctrl u_bar_ctrl (
        .clk(clk), .rst_n(rst_n),
        .mmio_addr(mmio_addr),
        .mmio_wr_data(mmio_wr_data),
        .mmio_wr_en(mmio_wr_en),
        .mmio_rd_data(mmio_rd_data),
        .mmio_rd_vld(mmio_rd_vld),
        .cmd_wr_en(bc_cmd_wr_en),
        .cmd_rid(bc_cmd_rid),
        .cmd_op(bc_cmd_op),
        .cmd_prio(bc_cmd_prio),
        .cmd_ia(bc_cmd_ia),
        .cmd_ib(bc_cmd_ib),
        .cmd_ic(bc_cmd_ic),
        .cmd_lvl(cq_lvl),
        .cmd_full(cq_full),
        .done_lvl(de_cq_lvl),
        .done_full(de_cq_full),
        .err_src_vld(sched_res_vld && !sched_res_ok),
        .err_src_rid(sched_res_rid),
        .err_src_code(sched_res_err),
        .ctrl_start(bc_ctrl_start),
        .ctrl_flush(bc_ctrl_flush),
        .ctrl_reset(bc_ctrl_reset)
    );

    // BAR0 shadow 回读
    assign bar0_head_shadow = bc_cmd_rid;  // 简化: 只回读部分字段
    assign bar0_ia_shadow = bc_cmd_ia;
    assign bar0_ib_shadow = bc_cmd_ib;
    assign bar0_ic_shadow = bc_cmd_ic;

    // =========================================================================
    // cmd_queue_buf (M21) - 16 深度
    // =========================================================================
    cmd_queue_buf #(
        .DEPTH(16),
        .IA_W(256),
        .IB_W(256),
        .IC_W(256)
    ) u_cmd_queue (
        .clk(clk), .rst_n(core_rst_n),
        .i_wr_en(bc_cmd_wr_en),
        .i_rid(bc_cmd_rid),
        .i_op(bc_cmd_op),
        .i_prio(bc_cmd_prio),
        .i_ia(bc_cmd_ia),
        .i_ib(bc_cmd_ib),
        .i_ic(bc_cmd_ic),
        .o_vld(cq_vld),
        .i_rdy(cq_rdy),
        .o_rid(cq_rid),
        .o_op(cq_op),
        .o_prio(cq_prio),
        .o_ia(cq_ia),
        .o_ib(cq_ib),
        .o_ic(cq_ic),
        .o_lvl(cq_lvl),
        .o_empty(cq_empty),
        .o_full(cq_full),
        .o_head_ptr(),
        .o_tail_ptr(),
        .i_flush(bc_ctrl_flush)
    );

    // =========================================================================
    // 命令队列 -> 调度器 (replicate 256->512)
    // =========================================================================
    assign sched_cmd_vld   = cq_vld;
    assign cq_rdy          = sched_cmd_rdy;
    assign sched_cmd_rid   = cq_rid;
    assign sched_cmd_op    = cq_op;
    assign sched_cmd_prio  = cq_prio;
    assign sched_cmd_ia    = {cq_ia, cq_ia};  // replicate 256->512
    assign sched_cmd_ib    = {cq_ib, cq_ib};
    assign sched_cmd_ic    = cq_ic;

    // =========================================================================
    // crypto_sched_subsys (SS2)
    // =========================================================================
    crypto_sched_subsys u_sched (
        .clk(clk), .rst_n(core_rst_n),
        .cmd_vld(sched_cmd_vld),
        .cmd_rdy(sched_cmd_rdy),
        .cmd_rid(sched_cmd_rid),
        .cmd_op(sched_cmd_op),
        .cmd_prio(sched_cmd_prio),
        .cmd_ia(sched_cmd_ia),
        .cmd_ib(sched_cmd_ib),
        .cmd_ic(sched_cmd_ic),
        .res_vld(sched_res_vld),
        .res_rdy(sched_res_rdy),
        .res_rid(sched_res_rid),
        .res_err(sched_res_err),
        .res_ok(sched_res_ok),
        .res_ra(sched_res_ra),
        .res_rb(sched_res_rb)
    );

    // =========================================================================
    // dma_desc_engine (M04)
    // =========================================================================
    dma_desc_engine u_dma (
        .clk(clk), .rst_n(core_rst_n),
        .res_vld(sched_res_vld),
        .res_rdy(sched_res_rdy),
        .res_rid(sched_res_rid),
        .res_err(sched_res_err),
        .res_ok(sched_res_ok),
        .res_ra(sched_res_ra),
        .res_rb(sched_res_rb),
        .dma_wr_vld(de_dma_wr_vld),
        .dma_wr_rdy(de_dma_wr_rdy),
        .dma_wr_desc(de_dma_wr_desc),
        .dma_wr_data(de_dma_wr_data),
        .dma_wr_rid(de_dma_wr_rid),
        .dma_wr_err(de_dma_wr_err),
        .dma_wr_ok(de_dma_wr_ok),
        .cq_lvl(de_cq_lvl),
        .cq_empty(de_cq_empty),
        .cq_full(de_cq_full)
    );

    // DMA 端口直通顶层
    assign dma_wr_vld   = de_dma_wr_vld;
    assign de_dma_wr_rdy = dma_wr_rdy;
    assign dma_wr_desc  = de_dma_wr_desc;
    assign dma_wr_data  = de_dma_wr_data;
    assign dma_wr_rid   = de_dma_wr_rid;
    assign dma_wr_err   = de_dma_wr_err;
    assign dma_wr_ok    = de_dma_wr_ok;

    // 队列水位
    assign cmd_queue_lvl = cq_lvl[4:0];
    assign done_queue_lvl = de_cq_lvl[4:0];

    // =========================================================================
    // MSI-X 中断: dma_done 触发向量 0
    // =========================================================================
    assign msix_irq_trigger = de_dma_wr_vld & de_dma_wr_rdy;
    assign msix_irq_vec_in  = 3'd0;

    // =========================================================================
    // MSI-X 配置解码 (BAR1 扩展区 0x300-0x30F, 只支持向量 0)
    // =========================================================================
    reg [31:0] mx_shadow_addr = 32'h0000_0000;
    reg [31:0] mx_shadow_data = 32'd1;
    reg        mx_shadow_mask = 1'b1;   // 1=屏蔽

    always @(posedge clk) begin
        if (!rst_n) begin
            mx_shadow_addr <= 32'h0000_0000;
            mx_shadow_data <= 32'd1;
            mx_shadow_mask <= 1'b1;
        end else if (mmio_wr_en && (mmio_addr[11:8] == 4'h3)) begin
            // BAR1 是字节寻址 (0x300/0x304/0x308), 必须解码 [3:0]。
            // 旧码取 [2:0] 使 0x308 落到 3'd0 (addr 分支), 屏蔽位永远写不进,
            // vec_mask[0] 停在复位值 1 -> 中断被永久屏蔽 (Phase 2.8c 首跑根因).
            case (mmio_addr[3:0])
                4'h0: mx_shadow_addr <= mmio_wr_data;
                4'h4: mx_shadow_data <= mmio_wr_data;
                4'h8: mx_shadow_mask <= (mmio_wr_data != 32'd0);
                default: ;
            endcase
        end
    end

    assign msix_tbl_wr_en   = 1'b1;      // 每拍同步 shadow 到 msix_ctrl
    assign msix_tbl_wr_vec  = 4'd0;
    assign msix_tbl_wr_addr = mx_shadow_addr;
    assign msix_tbl_wr_data = mx_shadow_data;
    assign msix_tbl_wr_mask = mx_shadow_mask;

    // =========================================================================
    // msix_ctrl (M05)
    // =========================================================================
    msix_ctrl u_msix (
        .clk(clk), .rst_n(rst_n),
        .tbl_wr_en(msix_tbl_wr_en),
        .tbl_wr_vec(msix_tbl_wr_vec),
        .tbl_wr_addr(msix_tbl_wr_addr),
        .tbl_wr_data(msix_tbl_wr_data),
        .tbl_wr_mask(msix_tbl_wr_mask),
        .irq_trigger(msix_irq_trigger),
        .irq_vec(msix_irq_vec_in),
        .irq_vld(msix_irq_vld),
        .irq_addr(msix_irq_addr),
        .irq_data(msix_irq_data),
        .irq_vec_out(msix_irq_vec),
        .pending(msix_pending),
        .masked(msix_masked),
        .any_pending(msix_any_pending)
    );

endmodule
