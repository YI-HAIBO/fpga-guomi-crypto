// =============================================================================
// 模块名称 : pcie_front_subsys
// 模块编号 : SS1 (Phase 7 v1.5 - PCIe Front-End 顶层, 环+DMA+MSI-X 命令模型)
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.1
// 日期     : 2026-10-25
// 变更记录 :
//   v1.0 2026-10-10 首版 (v1.5 命令模型)
//   v1.1 2026-10-25 新增模块参数 USE_SM4_MASKED (默认 0), 向下穿透到
//                  crypto_sched_subsys -> crypto_coord_subsys:
//                  2 = sm4_engine_masked_v4 (板级掩码出片)。
//                  外部端口与默认行为不变。
// 视角     : fpga-fullflow-lead (齐流晶)
//
// 功能     : SS1 PCIe 前端子系统顶层, v1.5 环+DMA+MSI-X 命令模型。
//            替换旧 bar_ctrl+doorbell+shadow 模型:
//   - M03  bar_ctrl v2.0     : BAR0/BAR1 寄存器映射 + 环写转发 + MSI-X 触发
//   - M07  cmd_ring_buf      : BAR1 命令环 (256 × 16B)
//   - M08  desc_ring_buf     : BAR1 描述符环 (256 × 16B)
//   - M22  ring_ctrl         : 环管理 + DMA 协调 + MSI-X 触发
//   - M06  cmd_parser        : 命令解析与合法性校验
//   - SS2  crypto_sched_subsys : 命令调度器 + 2 引擎
//   - M04  dma_desc_engine   : 结果收集 + DMA 描述符打包
//   - M05  msix_ctrl         : MSI-X 中断控制器 (16 向量)
//
// 数据通路 (v1.5):
//   [Host MMIO] --BAR0/BAR1--> bar_ctrl v2.0 (译码 + 环写转发)
//                       --CMD_RING_WR--> cmd_ring_buf (入环)
//                       --DESC_RING_WR--> desc_ring_buf (入环)
//   cmd_ring_buf (cmd_vld/rdy) --> ring_ctrl (检测 avail)
//   ring_ctrl (dma_start) --> dma_desc_engine (触发 DMA)
//   ring_ctrl (cmd_vld/rdy) --> cmd_parser (解析)
//   cmd_parser (o_legal) --> crypto_sched_subsys (调度)
//   crypto_sched_subsys (res_vld) --> dma_desc_engine (结果打包)
//   dma_desc_engine (dma_wr_vld) --> [Host DMA 写回]
//   dma_desc_engine (irq_trigger) --> msix_ctrl
//   ring_ctrl (msix_trigger) --> msix_ctrl
//   msix_ctrl (irq_vld) --> [PCIe MSI-X 消息]
//
// 编译     : iverilog -g2005
// =============================================================================

`timescale 1ns / 1ps

module pcie_front_subsys #(
    // 向下穿透: 0 = sm4 baseline (默认), 1 = v3 (兼容), 2 = v4 输出再掩码
    parameter USE_SM4_MASKED = 0
) (
    input  wire         clk,
    input  wire         rst_n,

    // ---- 主机 MMIO 接口 (AXI4-Lite) ----
    input  wire [19:0]  mmio_addr,      // v2.0: 20-bit (BAR0 4KB + BAR1 1MB)
    input  wire [31:0]  mmio_wr_data,
    input  wire         mmio_wr_en,
    output wire [31:0]  mmio_rd_data,
    output wire         mmio_rd_vld,

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
    output wire [15:0]  msix_pending,     // v1.2: 16 向量
    output wire [15:0]  msix_masked,      // v1.2: 16 向量
    output wire         msix_any_pending,

    // ---- 状态指示 ----
    output wire [8:0]   cmd_ring_lvl,
    output wire [8:0]   desc_ring_lvl,
    output wire [4:0]   cmd_queue_lvl,
    output wire [4:0]   done_queue_lvl,
    input  wire [63:0]  mask_seed_init   // v4 掩码种子初值 (每设备保密, P0-6 修复)
);

    // =========================================================================
    // 内部连线: bar_ctrl <-> cmd_ring_buf / desc_ring_buf
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

    // =========================================================================
    // 内部连线: ring_ctrl <-> cmd_ring_buf / desc_ring_buf
    // =========================================================================
    wire        rc_dma_start;
    wire [7:0]  rc_dma_cmd_id;
    wire [31:0] rc_dma_payload_addr;
    wire [31:0] rc_dma_result_addr;
    wire        rc_dma_done;
    wire        rc_dma_error;
    wire        rc_msix_trigger;

    // =========================================================================
    // 内部连线: cmd_ring_buf -> cmd_parser
    // =========================================================================
    wire        cr_cmd_vld;
    wire        cr_cmd_rdy;
    wire [31:0] cr_cmd_id;
    wire [7:0]  cr_cmd_type;
    wire [7:0]  cr_cmd_flags;
    wire [15:0] cr_cmd_payload_len;
    wire [31:0] cr_cmd_payload_addr;
    wire [31:0] cr_cmd_result_addr;
    wire [8:0]  cr_cmd_lvl;

    // =========================================================================
    // 内部连线: cmd_parser -> crypto_sched_subsys
    // =========================================================================
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

    // =========================================================================
    // 内部连线: crypto_sched_subsys <-> dma_desc_engine
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
    // 内部连线: dma_desc_engine <-> msix_ctrl
    // =========================================================================
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

    wire        msix_tbl_wr_en;
    wire [3:0]  msix_tbl_wr_vec;
    wire [31:0] msix_tbl_wr_addr;
    wire [31:0] msix_tbl_wr_data;
    wire        msix_tbl_wr_mask;

    wire        msix_irq_trigger;
    wire [3:0]  msix_irq_vec_in;

    // =========================================================================
    // 内部连线: trng_monitor <-> bar_ctrl (TRNG 健康监视)
    //   bar_ctrl v1.5 的 STATUS_TRNG / ENTROPY_CNT 接口早已定义, 但旧版把
    //   ht_status / trng_running / entropy_cnt 三输入硬接常数, 导致 trng_ok
    //   在结构上永不可达 (板级绿灯不可达)。此处接线 trng_monitor (free-
    //   running 监视器)。详见 trng_monitor.v 文件头。
    // =========================================================================
    wire        trng_start;
    wire        trng_stop;
    wire        trng_flush;
    wire [6:0]  mon_ht_status;
    wire        mon_trng_running;
    wire [63:0] mon_entropy_cnt;

    // =========================================================================
    // 环条目 -> 命令参数映射
    //   cmd_type -> op: 0x01=TRNG(op=0), 0x10=SM2_SIGN(op=5), 0x20=SM3(op=3),
    //                    0x30=SM4_ENC(op=0), 0x31=SM4_DEC(op=1), 0xFF=NOOP
    //   cmd_id   -> rid
    //   flags[1:0] -> prio
    //   payload_addr -> ia (低 32 位), result_addr -> ib (低 32 位)
    //   ia/ib/ic 其余位补 0 (简化: 实际数据由 DMA 从 Host 内存搬移)
    // =========================================================================
    wire [3:0]  cmd_op_map;
    wire [1:0]  cmd_prio_map;

    // cmd_type 到 op 的映射 (组合逻辑)
    assign cmd_op_map = (cr_cmd_type == 8'h01) ? 4'h0 :   // TRNG
                        (cr_cmd_type == 8'h10) ? 4'h5 :   // SM2_SIGN
                        (cr_cmd_type == 8'h20) ? 4'h3 :   // SM3
                        (cr_cmd_type == 8'h30) ? 4'h0 :   // SM4_ENC
                        (cr_cmd_type == 8'h31) ? 4'h1 :   // SM4_DEC
                        (cr_cmd_type == 8'h40) ? 4'h2 :   // KEY_*
                        4'h7;                             // NOOP/未知

    assign cmd_prio_map = cr_cmd_flags[1:0];

    // =========================================================================
    // CTRL_RESET 脉冲回接: bc_ctrl_reset -> soft_rst_n -> 下游内核
    // =========================================================================
    reg  soft_rst_n = 1'b1;
    wire bc_ctrl_reset;

    always @(posedge clk) begin
        if (!rst_n)
            soft_rst_n <= 1'b1;
        else if (bc_ctrl_reset)
            soft_rst_n <= 1'b0;
        else
            soft_rst_n <= 1'b1;
    end
    wire core_rst_n = rst_n & soft_rst_n;

    // =========================================================================
    // bar_ctrl v2.0 (M03)
    // =========================================================================
    bar_ctrl u_bar_ctrl (
        .clk(clk), .rst_n(rst_n),
        .mmio_addr(mmio_addr),
        .mmio_wr_data(mmio_wr_data),
        .mmio_wr_en(mmio_wr_en),
        .mmio_rd_data(mmio_rd_data),
        .mmio_rd_vld(mmio_rd_vld),
        // 环管理输出: 命令环
        .cmd_ring_wr_en(cmd_ring_wr_en),
        .cmd_ring_wr_idx(cmd_ring_wr_idx),
        .cmd_ring_wr_entry(cmd_ring_wr_entry),
        .cmd_ring_head_wr_en(cmd_ring_head_wr_en),
        .cmd_ring_head_ptr(cmd_ring_head_ptr),
        .cmd_ring_head_cur(cmd_ring_head_cur),
        .cmd_ring_tail(cmd_ring_tail),
        .cmd_ring_avail(cmd_ring_avail),
        // 环管理输出: 描述符环
        .desc_ring_wr_en(desc_ring_wr_en),
        .desc_ring_wr_idx(desc_ring_wr_idx),
        .desc_ring_wr_entry(desc_ring_wr_entry),
        .desc_ring_head_wr_en(desc_ring_head_wr_en),
        .desc_ring_head_ptr(desc_ring_head_ptr),
        .desc_ring_head_cur(desc_ring_head_cur),
        .desc_ring_tail(desc_ring_tail),
        .desc_ring_avail(desc_ring_avail),
        // 队列状态反馈
        .cmd_lvl(cr_cmd_lvl),
        .cmd_full(),
        .done_lvl(de_cq_lvl),
        .done_full(de_cq_full),
        // 错误上报
        .err_src_vld(sched_res_vld && !sched_res_ok),
        .err_src_rid(sched_res_rid),
        .err_src_code(sched_res_err),
        // TRNG 健康测试 (接 trng_monitor)
        .ht_status(mon_ht_status),
        .trng_running(mon_trng_running),
        // 熵计数 (接 trng_monitor)
        .entropy_cnt(mon_entropy_cnt),
        // 引擎控制输出 (接 trng_monitor)
        .ctrl_trng_start(trng_start),
        .ctrl_trng_stop(trng_stop),
        .ctrl_trng_flush(trng_flush),
        .ctrl_sm2_start(),
        .ctrl_sm3_start(),
        .ctrl_sm4_start(),
        // MSI-X 触发 (由 ring_ctrl 协调, 此处预留)
        .msix_trigger(),
        .msix_vec(),
        // 队列控制
        .ctrl_start(),
        .ctrl_flush(),
        .ctrl_reset(bc_ctrl_reset)
    );

    // =========================================================================
    // trng_monitor - TRNG 健康监视 (free-running)
    //   bar_ctrl 的 STATUS_TRNG (0x044) 与 ENTROPY_CNT (0x058/0x05C) 接口
    //   在此落地: trng_entropy (trng_sm3.v:331) -> trng_health_test_v3
    //   (7 项 NIST SP 800-90B 检验, WIN=1024) -> bar_ctrl 状态寄存器。
    //   熵源统计质量实测 (entropy_ht_check.py): 2000 窗口 ALL 7 PASS =
    //   90.850%, 首窗口即 7/7 通过 -> 熵源本身无需改, 接线即可。
    // =========================================================================
    trng_monitor u_trng_monitor (
        .clk            (clk),
        .rst_n          (rst_n),
        .i_start        (trng_start),
        .i_stop         (trng_stop),
        .i_flush        (trng_flush),
        .o_ht_status    (mon_ht_status),
        .o_trng_running (mon_trng_running),
        .o_entropy_cnt  (mon_entropy_cnt)
    );

    // =========================================================================
    // cmd_ring_buf (M07) - 命令环缓冲
    // =========================================================================
    cmd_ring_buf #(
        .DEPTH(256), .PTR_W(8), .CNT_W(9)
    ) u_cmd_ring_buf (
        .clk(clk), .rst_n(core_rst_n),
        .wr_en(cmd_ring_wr_en),
        .wr_idx(cmd_ring_wr_idx),
        .wr_entry(cmd_ring_wr_entry),
        .head_wr_en(cmd_ring_head_wr_en),
        .head_ptr(cmd_ring_head_ptr),
        .head_ptr_cur(cmd_ring_head_cur),
        .tail_ptr(cmd_ring_tail),
        .cmd_avail(cmd_ring_avail),
        .cmd_vld(cr_cmd_vld),
        .cmd_rdy(cr_cmd_rdy),
        .cmd_id(cr_cmd_id),
        .cmd_type(cr_cmd_type),
        .cmd_flags(cr_cmd_flags),
        .cmd_payload_len(cr_cmd_payload_len),
        .cmd_payload_addr(cr_cmd_payload_addr),
        .cmd_result_addr(cr_cmd_result_addr),
        .cmd_lvl(cr_cmd_lvl)
    );

    // =========================================================================
    // desc_ring_buf (M08) - 描述符环缓冲
    // =========================================================================
    desc_ring_buf #(
        .DEPTH(256), .PTR_W(8), .CNT_W(9)
    ) u_desc_ring_buf (
        .clk(clk), .rst_n(core_rst_n),
        .wr_en(desc_ring_wr_en),
        .wr_idx(desc_ring_wr_idx),
        .wr_entry(desc_ring_wr_entry),
        .head_wr_en(desc_ring_head_wr_en),
        .head_ptr(desc_ring_head_ptr),
        .head_ptr_cur(desc_ring_head_cur),
        .tail_ptr(desc_ring_tail),
        .desc_avail(desc_ring_avail),
        .desc_vld(),
        .desc_rdy(1'b0),
        .desc_id(),
        .batch_op(),
        .batch_flags(),
        .batch_count(),
        .input_desc_addr(),
        .output_desc_addr(),
        .desc_lvl(desc_ring_lvl),
        .desc_full()
    );

    // =========================================================================
    // ring_ctrl (M22) - 环管理 + DMA 协调 + MSI-X
    // =========================================================================
    ring_ctrl #(
        .PTR_W(8)
    ) u_ring_ctrl (
        .clk(clk), .rst_n(core_rst_n),
        // MMIO 写入 (直通 bar_ctrl -> 环)
        .mmio_cmd_wr_en(cmd_ring_wr_en),
        .mmio_cmd_wr_idx(cmd_ring_wr_idx),
        .mmio_cmd_wr_entry(cmd_ring_wr_entry),
        .mmio_cmd_head_wr_en(cmd_ring_head_wr_en),
        .mmio_cmd_head_ptr(cmd_ring_head_ptr),
        .mmio_desc_wr_en(desc_ring_wr_en),
        .mmio_desc_wr_idx(desc_ring_wr_idx),
        .mmio_desc_wr_entry(desc_ring_wr_entry),
        .mmio_desc_head_wr_en(desc_ring_head_wr_en),
        .mmio_desc_head_ptr(desc_ring_head_ptr),
        // 环状态
        .cmd_avail(cmd_ring_avail),
        .cmd_head_cur(cmd_ring_head_cur),
        .cmd_tail(cmd_ring_tail),
        .desc_avail(desc_ring_avail),
        .desc_head_cur(desc_ring_head_cur),
        .desc_tail(desc_ring_tail),
        // DMA 控制
        .dma_start(rc_dma_start),
        .dma_cmd_id(rc_dma_cmd_id),
        .dma_payload_addr(rc_dma_payload_addr),
        .dma_result_addr(rc_dma_result_addr),
        .dma_done(rc_dma_done),
        .dma_error(rc_dma_error),
        // MSI-X
        .msix_trigger(rc_msix_trigger)
    );

    // =========================================================================
    // cmd_parser (M06) - 命令解析与合法性校验
    // =========================================================================
    // 将环条目映射到 cmd_parser 接口
    assign cp_i_vld    = cr_cmd_vld;
    assign cr_cmd_rdy  = cp_i_rdy;
    assign cp_i_op     = cmd_op_map;
    assign cp_i_rid    = cr_cmd_id[7:0];
    assign cp_i_prio   = cmd_prio_map;
    // 简化: ia = {payload_addr, result_addr, 0...}, ib = {cmd_id, flags, 0...}, ic = 0
    assign cp_i_ia     = {192'd0, cr_cmd_payload_addr, cr_cmd_result_addr};
    assign cp_i_ib     = {224'd0, cr_cmd_flags, cr_cmd_id};
    assign cp_i_ic     = 256'd0;

    // 注意: cmd_parser 的 i_rdy 是 **output** 且内部恒为 1 (cmd_parser.v:100)。
    // 若连到 cp_i_rdy, 会与 `assign cp_i_rdy = sched_cmd_rdy` (见下) 双驱动,
    // Vivado 保留 VCC 常数而忽略 sched_cmd_rdy -> 综合后环反压永久失效。
    // 此处悬空; cp_i_rdy 只由 sched_cmd_rdy 驱动。
    cmd_parser u_cmd_parser (
        .clk(clk), .rst_n(core_rst_n),
        .i_vld(cp_i_vld),
        .i_rdy(),
        .i_op(cp_i_op),
        .i_rid(cp_i_rid),
        .i_prio(cp_i_prio),
        .i_ia(cp_i_ia),
        .i_ib(cp_i_ib),
        .i_ic(cp_i_ic),
        .o_legal(cp_o_legal),
        .o_illegal(cp_o_illegal),
        .o_err(cp_o_err),
        .o_op(),
        .o_rid(),
        .o_prio()
    );

    // =========================================================================
    // crypto_sched_subsys (SS2) - 命令调度器 + 2 引擎
    // =========================================================================
    assign sched_cmd_vld   = cp_o_legal;
    assign cp_i_rdy        = sched_cmd_rdy;
    assign sched_cmd_rid   = cp_i_rid;
    assign sched_cmd_op    = cp_i_op;
    assign sched_cmd_prio  = cp_i_prio;
    assign sched_cmd_ia    = cp_i_ia;
    assign sched_cmd_ib    = cp_i_ib;
    assign sched_cmd_ic    = cp_i_ic;

    crypto_sched_subsys #(
        .USE_SM4_MASKED (USE_SM4_MASKED)
    ) u_sched (
        .clk(clk), .rst_n(core_rst_n),
        .cmd_vld(sched_cmd_vld),
        .cmd_rdy(sched_cmd_rdy),
        .cmd_rid(sched_cmd_rid),
        .cmd_op(sched_cmd_op),
        .cmd_prio(sched_cmd_prio),
        .cmd_ia(sched_cmd_ia),
        .cmd_ib(sched_cmd_ib),
        .cmd_ic(sched_cmd_ic),
        .mask_seed_init (mask_seed_init),  // v4 掩码种子 (P0-6 修复)
        .res_vld(sched_res_vld),
        .res_rdy(sched_res_rdy),
        .res_rid(sched_res_rid),
        .res_err(sched_res_err),
        .res_ok(sched_res_ok),
        .res_ra(sched_res_ra),
        .res_rb(sched_res_rb)
    );

    // =========================================================================
    // dma_desc_engine (M04) - 结果收集 + DMA 描述符打包
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

    // =========================================================================
    // DMA 完成信号 -> ring_ctrl
    //   dma_done = DMA 写回握手成功 (vld & rdy)
    // =========================================================================
    assign rc_dma_done = de_dma_wr_vld & de_dma_wr_rdy;
    assign rc_dma_error = 1'b0;

    // =========================================================================
    // MSI-X 中断触发: ring_ctrl + dma_done 双路触发
    // =========================================================================
    assign msix_irq_trigger = rc_msix_trigger | rc_dma_done;
    assign msix_irq_vec_in  = rc_dma_done ? 4'd0 :     // CMD_BATCH_DONE
                              rc_msix_trigger ? 4'd1 : // DESC_BATCH_DONE
                              4'd0;

    // =========================================================================
    // MSI-X 配置: 由 bar_ctrl v2.0 管理 (默认全部屏蔽, TB 取消屏蔽)
    // =========================================================================
    // 注意: bar_ctrl v2.0 的 msix_trigger/msix_vec 输出未连接 (由 ring_ctrl 接管)
    // MSI-X 表编程通过 BAR1 0x300-0x30F 区域, 由 bar_ctrl 内部处理
    // 这里提供默认值: 全部屏蔽 (vec_mask=1), TB 需通过 tbl_wr 取消屏蔽
    assign msix_tbl_wr_en   = 1'b0;   // 由 bar_ctrl 内部处理, 此处不额外驱动
    assign msix_tbl_wr_vec  = 4'd0;
    assign msix_tbl_wr_addr = 32'd0;
    assign msix_tbl_wr_data = 32'd0;
    assign msix_tbl_wr_mask = 1'b1;

    // =========================================================================
    // msix_ctrl (M05 v1.2) - 16 向量
    // =========================================================================
    msix_ctrl #(
        .NVECT(16)
    ) u_msix (
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

    // =========================================================================
    // 状态输出
    // =========================================================================
    assign cmd_ring_lvl   = cr_cmd_lvl;
    assign desc_ring_lvl  = desc_ring_lvl;
    assign cmd_queue_lvl  = de_cq_lvl[4:0];
    assign done_queue_lvl = de_cq_lvl[4:0];

endmodule