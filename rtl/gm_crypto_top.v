// =============================================================================
// 模块名称 : gm_crypto_top
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-05
// 视角     : fpga-fullflow-lead (齐流晶)
//
// 功能     : Phase 5 系统顶层。包装 crypto_sched_subsys 提供主机接口。
//            主机通过 host_cmd_wr 写入命令，通过 host_res_vld 读取结果。
//            中断输出在结果有效时拉高，由 res_rdy 清零。
//
// 数据通路 :
//   Host -> host_cmd_wr/cmd_rid/cmd_op/cmd_prio/cmd_ia/cmd_ib/cmd_ic
//        -> crypto_sched_subsys -> engine pool -> result FIFO
//        -> host_res_vld/res_rid/res_err/res_ok/res_ra/res_rb
//
// 设计决策 :
//   D1: 薄包装层，不修改调度器逻辑。
//   D2: 主机接口采用 valid/ready 握手。
//   D3: 中断为电平保持，由 res_rdy 清零。
//   D4: 状态寄存器纯组合输出。
//   D5: 密钥由命令参数直接传入（不引入 SS4）。
//
// 编译     : iverilog -g2005
// =============================================================================

`timescale 1ns / 1ps

module gm_crypto_top (
    input  wire         clk,
    input  wire         rst_n,

    // ---- 主机命令接口 ----
    input  wire         host_cmd_wr,     // 命令写入脉冲
    input  wire [7:0]   host_cmd_rid,    // 请求 ID
    input  wire [3:0]   host_cmd_op,     // 操作码
    input  wire [1:0]   host_cmd_prio,   // 优先级
    input  wire [511:0] host_cmd_ia,     // 参数 A
    input  wire [511:0] host_cmd_ib,     // 参数 B
    input  wire [255:0] host_cmd_ic,     // 参数 C

    // ---- 主机结果接口 ----
    output wire         host_res_vld,    // 结果有效
    input  wire         host_res_rdy,    // 读取确认
    output wire [7:0]   host_res_rid,    // 结果请求 ID
    output wire [7:0]   host_res_err,    // 错误码
    output wire         host_res_ok,     // 操作成功
    output wire [255:0] host_res_ra,     // 结果 A
    output wire [255:0] host_res_rb,     // 结果 B

    // ---- 状态与中断 ----
    output wire [31:0]  status,          // 状态寄存器
    output wire         interrupt        // 中断输出
);

    // =========================================================================
    // 内部信号：连接到 crypto_sched_subsys
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
    // 例化 crypto_sched_subsys
    // =========================================================================
    crypto_sched_subsys u_sched (
        .clk(clk), .rst_n(rst_n),
        .cmd_vld(sched_cmd_vld), .cmd_rdy(sched_cmd_rdy),
        .cmd_rid(sched_cmd_rid), .cmd_op(sched_cmd_op),
        .cmd_prio(sched_cmd_prio),
        .cmd_ia(sched_cmd_ia), .cmd_ib(sched_cmd_ib), .cmd_ic(sched_cmd_ic),
        .res_vld(sched_res_vld), .res_rdy(sched_res_rdy),
        .res_rid(sched_res_rid), .res_err(sched_res_err),
        .res_ok(sched_res_ok),
        .res_ra(sched_res_ra), .res_rb(sched_res_rb)
    );

    // =========================================================================
    // 主机命令接口：写脉冲 -> cmd_vld
    //   host_cmd_wr 是 1 拍脉冲，直接连到 cmd_vld。
    //   命令参数通过寄存器锁存，避免 NBA 时序问题。
    // =========================================================================
    reg [7:0]   cmd_rid_r;
    reg [3:0]   cmd_op_r;
    reg [1:0]   cmd_prio_r;
    reg [511:0] cmd_ia_r;
    reg [511:0] cmd_ib_r;
    reg [255:0] cmd_ic_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_rid_r  <= 8'd0;
            cmd_op_r   <= 4'd0;
            cmd_prio_r <= 2'd0;
            cmd_ia_r   <= 512'd0;
            cmd_ib_r   <= 512'd0;
            cmd_ic_r   <= 256'd0;
        end else if (host_cmd_wr) begin
            cmd_rid_r  <= host_cmd_rid;
            cmd_op_r   <= host_cmd_op;
            cmd_prio_r <= host_cmd_prio;
            cmd_ia_r   <= host_cmd_ia;
            cmd_ib_r   <= host_cmd_ib;
            cmd_ic_r   <= host_cmd_ic;
        end
    end

    // 主机命令接口：写脉冲 -> cmd_vld（延迟 1 拍，确保参数先锁存）
    //   原因：cmd_rid_r 等参数在 posedge 锁存，若同拍断言 cmd_vld，
    //   调度器会采样到旧值（NBA 竞态）。延迟 1 拍消除竞态。
    reg cmd_wr_d1 = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cmd_wr_d1 <= 0;
        else
            cmd_wr_d1 <= host_cmd_wr;
    end

    assign sched_cmd_vld = cmd_wr_d1;
    assign host_cmd_rdy  = sched_cmd_rdy;

    assign sched_cmd_rid  = cmd_rid_r;
    assign sched_cmd_op   = cmd_op_r;
    assign sched_cmd_prio = cmd_prio_r;
    assign sched_cmd_ia   = cmd_ia_r;
    assign sched_cmd_ib   = cmd_ib_r;
    assign sched_cmd_ic   = cmd_ic_r;

    // =========================================================================
    // 主机结果接口：直接透传
    // =========================================================================
    assign host_res_vld = sched_res_vld;
    assign sched_res_rdy = host_res_rdy;
    assign host_res_rid  = sched_res_rid;
    assign host_res_err  = sched_res_err;
    assign host_res_ok   = sched_res_ok;
    assign host_res_ra   = sched_res_ra;
    assign host_res_rb   = sched_res_rb;

    // =========================================================================
    // 中断：结果有效时拉高，由 res_rdy 清零
    // =========================================================================
    reg irq_reg = 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_reg <= 1'b0;
        end else begin
            if (sched_res_vld) irq_reg <= 1'b1;
            else if (host_res_rdy) irq_reg <= 1'b0;
        end
    end
    assign interrupt = irq_reg;

    // =========================================================================
    // 状态寄存器（纯组合输出）
    //   bit[0]  = RES_VLD (结果待取)
    //   bit[1]  = CMD_RDY (可接受新命令)
    //   bit[2]  = ENG0_BUSY (引擎0忙)
    //   bit[3]  = ENG1_BUSY (引擎1忙)
    //   bit[4]  = ERROR (最近一次错误)
    // =========================================================================
    // 引擎忙信号需要从调度器内部引出，但调度器没有暴露。
    // 这里用简化方式：通过命令/结果活动推断。
    // 更准确的做法是修改 crypto_sched_subsys 增加引擎忙端口。
    // 本版本先用简化状态。
    assign status = {
        27'd0,
        1'b0,  // [4] ERROR - 简化，未实现
        1'b0,  // [3] ENG1_BUSY - 简化，未实现
        1'b0,  // [2] ENG0_BUSY - 简化，未实现
        sched_cmd_rdy,  // [1] CMD_RDY
        sched_res_vld   // [0] RES_VLD
    };

endmodule
