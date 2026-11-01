// =============================================================================
// 模块名称 : dma_desc_engine
// 模块编号 : M04 (SS1 - PCIe Front-End, 见 phase1/架构与模块划分说明书_v1.md §2.1)
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.1
// 日期     : 2026-10-03
// 变更记录 :
//   v1.0 2026-10-03 首版
//   v1.1 2026-10-03 两处修正:
//                  1) 描述符拼接右对齐到 64 bit, 避免 iverilog 对窄常量
//                     左对齐使 dir/cmd_type 漂到 [63:16]、低位全 0
//                  2) 新增 cap_* 快照寄存: 接收拍立即锁存 res_*,
//                     因 res_pop 与本模块 enq 同拍, 次拍 S_PACK 再读
//                     res_* 会读到已被 FIFO pop 掉的位置 (全 X)

// 视角     : rtl-designer (葛逻辑)
// 时钟     : clk_l400
//
// 功能     : DMA 描述符引擎。收集 crypto_sched_subsys 的完成结果,
//            打包成 DMA 描述符 (completion entry), 写入完成队列,
//            并通过 DMA 回写通道通知主机。
//
// 描述符格式 (64-bit, phase1/接口表_v1.md §1.3):
//   bit[0]      : dir (1=write to host)
//   bit[1]      : cmd_type (1=data_transfer=completion)
//   bit[2:3]    : reserved
//   bit[30:4]   : host_addr (27-bit, 128MB 范围)
//   bit[35:31]  : local_addr (5-bit, BAR0 内偏移)
//   bit[41:36]  : burst_size (6-bit, 0-63 blocks)
//   bit[63:42]  : tag (22-bit, DMA 事务标签)
//
// 完成队列 (completion buffer):
//   深度 256, 每条 64-bit 描述符 + 32-bit status + 256-bit result_low + 256-bit result_high
//   简化: 用独立寄存器存各字段
//
// 编译     : iverilog -g2005
// =============================================================================

`timescale 1ns / 1ps

module dma_desc_engine #(
    parameter CQ_DEPTH   = 256,
    parameter PTR_W      = 8,
    parameter CNT_W      = 9
) (
    input  wire             clk,
    input  wire             rst_n,

    // ---- 结果输入 (从 crypto_sched_subsys) ----
    input  wire             res_vld,
    output wire             res_rdy,
    input  wire [7:0]       res_rid,
    input  wire [7:0]       res_err,
    input  wire             res_ok,
    input  wire [255:0]     res_ra,
    input  wire [255:0]     res_rb,

    // ---- DMA 回写输出 (模拟写回主机内存) ----
    output reg              dma_wr_vld,
    input  wire             dma_wr_rdy,
    output reg  [63:0]      dma_wr_desc,      // 描述符
    output reg  [511:0]     dma_wr_data,      // 结果数据 (ra||rb)
    output reg  [7:0]       dma_wr_rid,
    output reg  [7:0]       dma_wr_err,
    output reg              dma_wr_ok,

    // ---- 完成队列状态 ----
    output wire [CNT_W-1:0] cq_lvl,
    output wire             cq_empty,
    output wire             cq_full,
    output wire [PTR_W-1:0] cq_head_ptr,
    output wire [PTR_W-1:0] cq_tail_ptr,

    // ---- 控制 ----
    input  wire             i_flush          // 1 拍脉冲: 清空完成队列
);

    // =========================================================================
    // 完成队列存储
    // =========================================================================
    localparam CQ_DEPTH_S = (CQ_DEPTH < 256) ? 256 : CQ_DEPTH;

    reg [63:0]    cq_desc [0:CQ_DEPTH_S-1];
    reg [7:0]     cq_rid  [0:CQ_DEPTH_S-1];
    reg [7:0]     cq_err  [0:CQ_DEPTH_S-1];
    reg           cq_ok   [0:CQ_DEPTH_S-1];
    reg [511:0]   cq_data [0:CQ_DEPTH_S-1];

    reg [PTR_W-1:0]  head;
    reg [PTR_W-1:0]  tail;
    reg [CNT_W-1:0]  cnt;

    // =========================================================================
    // 指针推进
    // =========================================================================
    function [PTR_W-1:0] pntx;
        input [PTR_W-1:0] p;
        begin
            if (p + 1 == CQ_DEPTH_S) pntx = 0;
            else                     pntx = p + 1;
        end
    endfunction

    // =========================================================================
    // DMA 写握手
    // =========================================================================
    wire dma_wr = dma_wr_vld & dma_wr_rdy;

    // =========================================================================
    // 入队 / 出队
    // =========================================================================
    wire enq = res_vld & res_rdy & ~cq_full;
    wire deq = dma_wr_vld & dma_wr_rdy;

    // =========================================================================
    // 状态机: 收集结果 -> 打包描述符 -> DMA 回写
    // =========================================================================
    localparam S_IDLE  = 2'd0;
    localparam S_PACK  = 2'd1;
    localparam S_DMA   = 2'd2;
    localparam S_DONE  = 2'd3;

    reg [1:0]    st_r;
    reg [7:0]    tag_r;       // 递增标签
    reg [31:0]   host_addr_r; // 简化: 固定基地址 + 递增偏移

    // 结果快照寄存器。
    // 必须在 S_IDLE 的「接收拍」立即锁存 res_*:
    // 调度器侧 res_pop = res_vld & res_rdy 与本模块 enq 同拍发生, FIFO 的 head
    // 会在同一 posedge 前进, 下一拍 S_PACK 再读 res_* 会读到未写过的位置 (X)。
    // Phase 2.8c E2E 首跑正是因此 dma_wr_data / dma_wr_ok 全 X。
    reg [255:0]  cap_ra;
    reg [255:0]  cap_rb;
    reg [7:0]    cap_rid;
    reg [7:0]    cap_err;
    reg          cap_ok;

    always @(posedge clk) begin
        if (!rst_n) begin
            st_r        <= S_IDLE;
            tag_r       <= 0;
            host_addr_r <= 32'h0000_0000;
            dma_wr_vld  <= 0;
            dma_wr_desc <= 64'd0;
            dma_wr_data <= 512'd0;
            dma_wr_rid  <= 0;
            dma_wr_err  <= 0;
            dma_wr_ok   <= 0;
            cap_ra      <= 256'd0;
            cap_rb      <= 256'd0;
            cap_rid     <= 0;
            cap_err     <= 0;
            cap_ok      <= 0;
            head        <= 0;
            tail        <= 0;
            cnt         <= 0;
        end else begin
            case (st_r)
                S_IDLE: begin
                    dma_wr_vld <= 0;
                    if (res_vld & res_rdy) begin
                        // 接收拍立即快照, 不能留到 S_PACK
                        cap_ra  <= res_ra;
                        cap_rb  <= res_rb;
                        cap_rid <= res_rid;
                        cap_err <= res_err;
                        cap_ok  <= res_ok;
                        st_r    <= S_PACK;
                    end
                end
                S_PACK: begin
                    // 打包描述符, 存入完成队列
                    // 位域必须右对齐凑满 64 bit, 否则 iverilog 对窄常量左对齐,
                    // dir/cmd_type 会漂到 [63:16], 低位全 0 (Phase 2.8c 首跑暴露).
                    dma_wr_desc <= {16'd0, tag_r, 6'd1, 5'd0, 27'd0, 2'b11}; // dir=1, type=1
                    dma_wr_data <= {cap_ra, cap_rb};
                    dma_wr_rid  <= cap_rid;
                    dma_wr_err  <= cap_err;
                    dma_wr_ok   <= cap_ok;
                    // 写入完成队列
                    cq_desc[tail] <= {16'd0, tag_r, 6'd1, 5'd0, 27'd0, 2'b11};
                    cq_rid[tail]  <= cap_rid;
                    cq_err[tail]  <= cap_err;
                    cq_ok[tail]   <= cap_ok;
                    cq_data[tail] <= {cap_ra, cap_rb};
                    tail <= pntx(tail);
                    tag_r <= tag_r + 1;
                    host_addr_r <= host_addr_r + 32'd64;
                    st_r <= S_DMA;
                end
                S_DMA: begin
                    dma_wr_vld <= 1;
                    if (dma_wr_rdy) begin
                        st_r <= S_IDLE;
                    end
                end
                default: begin
                    st_r <= S_IDLE;
                end
            endcase

            // 完成队列计数
            if (i_flush) begin
                head <= 0; tail <= 0; cnt <= 0;
            end else begin
                if (enq && !dma_wr) begin
                    cnt <= cnt + 1;
                end else if (!enq && dma_wr) begin
                    cnt <= cnt - 1;
                end
                // 注意: enq 和 dma_wr 同拍时 cnt 不变 (入出平衡)
                // 但完成队列的 head 推进由 dma_wr 触发
                if (dma_wr) begin
                    head <= pntx(head);
                end
            end
        end
    end

    // =========================================================================
    // res_rdy: 仅在 S_IDLE 且队列未满时接受
    // =========================================================================
    assign res_rdy = (st_r == S_IDLE) & ~cq_full;

    // =========================================================================
    // 状态输出
    // =========================================================================
    assign cq_lvl    = cnt;
    assign cq_empty  = (cnt == 0);
    assign cq_full   = (cnt == CQ_DEPTH_S[CNT_W-1:0]);
    assign cq_head_ptr = head;
    assign cq_tail_ptr = tail;

endmodule
