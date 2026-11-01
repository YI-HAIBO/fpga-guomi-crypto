// =============================================================================
// 模块名称 : pcie_front_subsys_v15_light
// 项目     : GM-CRYPTO-COORD-2026 - v1.5 轻量全系统综合验证
// 版本     : v1.0
// 日期     : 2026-10-10
// 功能     : 与 pcie_front_subsys_v15 同构, 但用 stub 调度器替换真实调度器+引擎
//            用于快速综合签核 v1.5 前端模块集成
// =============================================================================
`timescale 1ns / 1ps

module pcie_front_subsys_v15_light (
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

    // =========================================================================
    // 内部连线 (与 pcie_front_subsys_v15 完全相同, 仅调度器换为 stub)
    // =========================================================================
    wire        cmd_ring_wr_en;
    wire [7:0]  cmd_ring_wr_idx;
    wire [127:0] cmd_ring_wr_entry;
    wire        cmd_ring_head_wr_en;
    wire [7:0]  cmd_ring_head_ptr;
    wire [7:0]  cmd_ring_head_cur;
    wire [7:0]  cmd_ring_tail;
    wire        cmd_ring_avail;

    wire        desc_ring_wr_en;
    wire [7:0]  desc_ring_wr_idx;
    wire [127:0] desc_ring_wr_entry;
    wire        desc_ring_head_wr_en;
    wire [7:0]  desc_ring_head_ptr;
    wire [7:0]  desc_ring_head_cur;
    wire [7:0]  desc_ring_tail;
    wire        desc_ring_avail;

    wire        rc_dma_start;
    wire [7:0]  rc_dma_cmd_id;
    wire [31:0] rc_dma_payload_addr;
    wire [31:0] rc_dma_result_addr;
    wire        rc_dma_done;
    wire        rc_dma_error;
    wire        rc_msix_trigger;

    wire        cr_cmd_vld;
    wire        cr_cmd_rdy;
    wire [31:0] cr_cmd_id;
    wire [7:0]  cr_cmd_type;
    wire [7:0]  cr_cmd_flags;
    wire [15:0] cr_cmd_payload_len;
    wire [31:0] cr_cmd_payload_addr;
    wire [31:0] cr_cmd_result_addr;
    wire [8:0]  cr_cmd_lvl;

    wire        cp_i_vld;
    wire        cp_i_rdy;
    wire [3:0]  cp_i_op;
    wire [7:0]  cp_i_rid;
    wire [1:0]  cp_i_prio;
    wire [511:0] cp_i_ia;
    wire [511:0] cp_i_ib;
    wire [255:0] cp_i_ic;
    wire        cp_o_legal;
    wire        cp_o_illegal;
    wire [7:0]  cp_o_err;

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

    wire [3:0]  cmd_op_map;
    wire [1:0]  cmd_prio_map;

    assign cmd_op_map = (cr_cmd_type == 8'h01) ? 4'h0 :
                        (cr_cmd_type == 8'h10) ? 4'h5 :
                        (cr_cmd_type == 8'h20) ? 4'h3 :
                        (cr_cmd_type == 8'h30) ? 4'h0 :
                        (cr_cmd_type == 8'h31) ? 4'h1 :
                        (cr_cmd_type == 8'h40) ? 4'h2 : 4'h7;
    assign cmd_prio_map = cr_cmd_flags[1:0];

    reg  soft_rst_n = 1'b1;
    wire bc_ctrl_reset;
    always @(posedge clk) begin
        if (!rst_n) soft_rst_n <= 1'b1;
        else if (bc_ctrl_reset) soft_rst_n <= 1'b0;
        else soft_rst_n <= 1'b1;
    end
    wire core_rst_n = rst_n & soft_rst_n;

    wire [8:0]  desc_ring_lvl;

    // =========================================================================
    // bar_ctrl v2.0
    // =========================================================================
    bar_ctrl u_bar_ctrl (
        .clk(clk), .rst_n(rst_n),
        .mmio_addr(mmio_addr), .mmio_wr_data(mmio_wr_data), .mmio_wr_en(mmio_wr_en),
        .mmio_rd_data(mmio_rd_data), .mmio_rd_vld(mmio_rd_vld),
        .cmd_ring_wr_en(cmd_ring_wr_en), .cmd_ring_wr_idx(cmd_ring_wr_idx),
        .cmd_ring_wr_entry(cmd_ring_wr_entry),
        .cmd_ring_head_wr_en(cmd_ring_head_wr_en), .cmd_ring_head_ptr(cmd_ring_head_ptr),
        .cmd_ring_head_cur(cmd_ring_head_cur), .cmd_ring_tail(cmd_ring_tail),
        .cmd_ring_avail(cmd_ring_avail),
        .desc_ring_wr_en(desc_ring_wr_en), .desc_ring_wr_idx(desc_ring_wr_idx),
        .desc_ring_wr_entry(desc_ring_wr_entry),
        .desc_ring_head_wr_en(desc_ring_head_wr_en), .desc_ring_head_ptr(desc_ring_head_ptr),
        .desc_ring_head_cur(desc_ring_head_cur), .desc_ring_tail(desc_ring_tail),
        .desc_ring_avail(desc_ring_avail),
        .cmd_lvl(cr_cmd_lvl), .cmd_full(), .done_lvl(de_cq_lvl), .done_full(de_cq_full),
        .err_src_vld(sched_res_vld && !sched_res_ok),
        .err_src_rid(sched_res_rid), .err_src_code(sched_res_err),
        .ht_status(7'd0), .trng_running(1'b0), .entropy_cnt(64'd0),
        .ctrl_trng_start(), .ctrl_trng_stop(), .ctrl_trng_flush(),
        .ctrl_sm2_start(), .ctrl_sm3_start(), .ctrl_sm4_start(),
        .msix_trigger(), .msix_vec(),
        .ctrl_start(), .ctrl_flush(), .ctrl_reset(bc_ctrl_reset)
    );

    // =========================================================================
    // cmd_ring_buf
    // =========================================================================
    cmd_ring_buf #(256, 8, 9) u_cmd_ring_buf (
        .clk(clk), .rst_n(core_rst_n),
        .wr_en(cmd_ring_wr_en), .wr_idx(cmd_ring_wr_idx), .wr_entry(cmd_ring_wr_entry),
        .head_wr_en(cmd_ring_head_wr_en), .head_ptr(cmd_ring_head_ptr),
        .head_ptr_cur(cmd_ring_head_cur), .tail_ptr(cmd_ring_tail),
        .cmd_avail(cmd_ring_avail),
        .cmd_vld(cr_cmd_vld), .cmd_rdy(cr_cmd_rdy),
        .cmd_id(cr_cmd_id), .cmd_type(cr_cmd_type), .cmd_flags(cr_cmd_flags),
        .cmd_payload_len(cr_cmd_payload_len), .cmd_payload_addr(cr_cmd_payload_addr),
        .cmd_result_addr(cr_cmd_result_addr), .cmd_lvl(cr_cmd_lvl)
    );

    // =========================================================================
    // desc_ring_buf
    // =========================================================================
    desc_ring_buf #(256, 8, 9) u_desc_ring_buf (
        .clk(clk), .rst_n(core_rst_n),
        .wr_en(desc_ring_wr_en), .wr_idx(desc_ring_wr_idx), .wr_entry(desc_ring_wr_entry),
        .head_wr_en(desc_ring_head_wr_en), .head_ptr(desc_ring_head_ptr),
        .head_ptr_cur(desc_ring_head_cur), .tail_ptr(desc_ring_tail),
        .desc_avail(desc_ring_avail),
        .desc_vld(), .desc_rdy(1'b0),
        .desc_id(), .batch_op(), .batch_flags(), .batch_count(),
        .input_desc_addr(), .output_desc_addr(),
        .desc_lvl(desc_ring_lvl), .desc_full()
    );

    // =========================================================================
    // ring_ctrl
    // =========================================================================
    ring_ctrl #(8) u_ring_ctrl (
        .clk(clk), .rst_n(core_rst_n),
        .mmio_cmd_wr_en(cmd_ring_wr_en), .mmio_cmd_wr_idx(cmd_ring_wr_idx),
        .mmio_cmd_wr_entry(cmd_ring_wr_entry),
        .mmio_cmd_head_wr_en(cmd_ring_head_wr_en), .mmio_cmd_head_ptr(cmd_ring_head_ptr),
        .mmio_desc_wr_en(desc_ring_wr_en), .mmio_desc_wr_idx(desc_ring_wr_idx),
        .mmio_desc_wr_entry(desc_ring_wr_entry),
        .mmio_desc_head_wr_en(desc_ring_head_wr_en), .mmio_desc_head_ptr(desc_ring_head_ptr),
        .cmd_avail(cmd_ring_avail), .cmd_head_cur(cmd_ring_head_cur), .cmd_tail(cmd_ring_tail),
        .desc_avail(desc_ring_avail), .desc_head_cur(desc_ring_head_cur), .desc_tail(desc_ring_tail),
        .dma_start(rc_dma_start), .dma_cmd_id(rc_dma_cmd_id),
        .dma_payload_addr(rc_dma_payload_addr), .dma_result_addr(rc_dma_result_addr),
        .dma_done(rc_dma_done), .dma_error(rc_dma_error),
        .msix_trigger(rc_msix_trigger)
    );

    // =========================================================================
    // cmd_parser
    // =========================================================================
    assign cp_i_vld = cr_cmd_vld;
    assign cr_cmd_rdy = cp_i_rdy;
    assign cp_i_op = cmd_op_map;
    assign cp_i_rid = cr_cmd_id[7:0];
    assign cp_i_prio = cmd_prio_map;
    assign cp_i_ia = {192'd0, cr_cmd_payload_addr, cr_cmd_result_addr};
    assign cp_i_ib = {224'd0, cr_cmd_flags, cr_cmd_id};
    assign cp_i_ic = 256'd0;

    // cmd_parser 的 i_rdy 是 output 且恒为 1, 悬空以免与 assign cp_i_rdy 双驱动
    // (同 pcie_front_subsys_v15.v, 综合后反压会失效)。
    cmd_parser u_cmd_parser (
        .clk(clk), .rst_n(core_rst_n),
        .i_vld(cp_i_vld), .i_rdy(),
        .i_op(cp_i_op), .i_rid(cp_i_rid), .i_prio(cp_i_prio),
        .i_ia(cp_i_ia), .i_ib(cp_i_ib), .i_ic(cp_i_ic),
        .o_legal(cp_o_legal), .o_illegal(cp_o_illegal), .o_err(cp_o_err),
        .o_op(), .o_rid(), .o_prio()
    );

    // =========================================================================
    // Stub 调度器 (替换 crypto_sched_subsys)
    // =========================================================================
    assign sched_cmd_vld = cp_o_legal;
    assign cp_i_rdy = sched_cmd_rdy;
    assign sched_cmd_rid = cp_i_rid;
    assign sched_cmd_op = cp_i_op;
    assign sched_cmd_prio = cp_i_prio;
    assign sched_cmd_ia = cp_i_ia;
    assign sched_cmd_ib = cp_i_ib;
    assign sched_cmd_ic = cp_i_ic;

    crypto_sched_subsys_stub u_sched_stub (
        .clk(clk), .rst_n(core_rst_n),
        .cmd_vld(sched_cmd_vld), .cmd_rdy(sched_cmd_rdy),
        .cmd_rid(sched_cmd_rid), .cmd_op(sched_cmd_op),
        .cmd_prio(sched_cmd_prio),
        .cmd_ia(sched_cmd_ia), .cmd_ib(sched_cmd_ib), .cmd_ic(sched_cmd_ic),
        .res_vld(sched_res_vld), .res_rdy(sched_res_rdy),
        .res_rid(sched_res_rid), .res_err(sched_res_err),
        .res_ok(sched_res_ok), .res_ra(sched_res_ra), .res_rb(sched_res_rb)
    );

    // =========================================================================
    // dma_desc_engine
    // =========================================================================
    dma_desc_engine u_dma (
        .clk(clk), .rst_n(core_rst_n),
        .res_vld(sched_res_vld), .res_rdy(sched_res_rdy),
        .res_rid(sched_res_rid), .res_err(sched_res_err),
        .res_ok(sched_res_ok), .res_ra(sched_res_ra), .res_rb(sched_res_rb),
        .dma_wr_vld(de_dma_wr_vld), .dma_wr_rdy(de_dma_wr_rdy),
        .dma_wr_desc(de_dma_wr_desc), .dma_wr_data(de_dma_wr_data),
        .dma_wr_rid(de_dma_wr_rid), .dma_wr_err(de_dma_wr_err),
        .dma_wr_ok(de_dma_wr_ok),
        .cq_lvl(de_cq_lvl), .cq_empty(de_cq_empty), .cq_full(de_cq_full)
    );

    assign dma_wr_vld = de_dma_wr_vld;
    assign de_dma_wr_rdy = dma_wr_rdy;
    assign dma_wr_desc = de_dma_wr_desc;
    assign dma_wr_data = de_dma_wr_data;
    assign dma_wr_rid = de_dma_wr_rid;
    assign dma_wr_err = de_dma_wr_err;
    assign dma_wr_ok = de_dma_wr_ok;

    assign rc_dma_done = de_dma_wr_vld & de_dma_wr_rdy;
    assign rc_dma_error = 1'b0;

    assign msix_irq_trigger = rc_msix_trigger | rc_dma_done;
    assign msix_irq_vec_in = rc_dma_done ? 4'd0 : (rc_msix_trigger ? 4'd1 : 4'd0);

    // =========================================================================
    // msix_ctrl
    // =========================================================================
    msix_ctrl #(16) u_msix (
        .clk(clk), .rst_n(rst_n),
        .tbl_wr_en(1'b0), .tbl_wr_vec(4'd0), .tbl_wr_addr(32'd0),
        .tbl_wr_data(32'd0), .tbl_wr_mask(1'b1),
        .irq_trigger(msix_irq_trigger), .irq_vec(msix_irq_vec_in),
        .irq_vld(msix_irq_vld), .irq_addr(msix_irq_addr), .irq_data(msix_irq_data),
        .irq_vec_out(msix_irq_vec), .pending(msix_pending),
        .masked(msix_masked), .any_pending(msix_any_pending)
    );

endmodule