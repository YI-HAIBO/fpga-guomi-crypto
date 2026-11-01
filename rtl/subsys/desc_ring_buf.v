// =============================================================================
// 模块名称 : desc_ring_buf
// 模块编号 : M08 (SS1 - PCIe Front-End, v1.5 命令模型迁移 Phase A2)
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-09
// 视角     : rtl-designer (葛逻辑)
// 时钟     : clk_l400 (100 MHz, PCIe Gen2 参考时钟)
//
// 功能     : BAR1 描述符环缓冲。256 条目 × 16 字节, 用于大批量批处理。
//            与 cmd_ring_buf 同构, 但条目字段为描述符语义。
//
// 条目格式 (16 字节, 对齐 v0 §3.3):
//   Byte 0-3   : desc_id (32-bit)
//   Byte 4     : batch_op (与 cmd_type 相同编码)
//   Byte 5     : batch_flags
//   Byte 6-7   : batch_count (16-bit, 本批次任务数)
//   Byte 8-11  : input_desc_addr (host physical, 指向输入描述符数组)
//   Byte 12-15 : output_desc_addr (host physical, 指向输出描述符数组)
//
// 设计约定:
//   - 与 cmd_ring_buf 完全相同的 HEAD/TAIL 管理策略。
//   - HEAD 由 Host 管理 (head_wr_en/head_ptr), TAIL 由 Device 内部推进。
//   - desc_avail = (HEAD != TAIL); desc_full = ((HEAD+1) == TAIL) 留 1 空位。
//   - 写入 (wr_en/wr_idx/wr_entry) 不检查满/空 —— Host 负责协议。
//
// 编译     : iverilog -g2005
// =============================================================================

`timescale 1ns / 1ps

module desc_ring_buf #(
    parameter DEPTH   = 256,
    parameter PTR_W   = 8,        // $clog2(256) = 8
    parameter CNT_W   = 9         // 0..256
) (
    input  wire             clk,
    input  wire             rst_n,

    // ---- BAR1 MMIO 写入 (Host → 环) ----
    input  wire             wr_en,
    input  wire [PTR_W-1:0] wr_idx,        // 写入条目号 (0..255)
    input  wire [127:0]     wr_entry,      // 16 字节条目

    // ---- HEAD 指针 (Host 更新, 触发提交) ----
    input  wire             head_wr_en,
    input  wire [PTR_W-1:0] head_ptr,      // Host 写入的 HEAD 值
    output wire [PTR_W-1:0] head_ptr_cur,  // 当前 HEAD

    // ---- TAIL 指针 (Device 消费) ----
    output wire [PTR_W-1:0] tail_ptr,      // Device 已消费到

    // ---- 描述符可用 ----
    output wire             desc_avail,    // HEAD != TAIL, 有描述符可取

    // ---- 描述符输出 (到调度器) ----
    output wire             desc_vld,      // = desc_avail
    input  wire             desc_rdy,
    output wire [31:0]      desc_id,
    output wire [7:0]       batch_op,
    output wire [7:0]       batch_flags,
    output wire [15:0]      batch_count,
    output wire [31:0]      input_desc_addr,
    output wire [31:0]      output_desc_addr,

    // ---- 状态 ----
    output wire [CNT_W-1:0] desc_lvl,      // 环内有效条目数 (0..256)
    output wire             desc_full      // 环满 (留 1 空位)
);

    // =========================================================================
    // 存储阵列 (256 × 128-bit)
    // =========================================================================
    localparam DEPTH_S = DEPTH;

    reg [127:0]  mem_entry [0:DEPTH_S-1];

    reg [PTR_W-1:0]  head;
    reg [PTR_W-1:0]  tail;

    // =========================================================================
    // 指针推进 (环形, 8-bit 自然溢出)
    // =========================================================================
    function [PTR_W-1:0] pntx;
        input [PTR_W-1:0] p;
        begin
            if (p + 1 == DEPTH_S) pntx = 0;
            else                  pntx = p + 1;
        end
    endfunction

    // =========================================================================
    // 写入逻辑
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            head <= 0;
            tail <= 0;
        end else begin
            // Host 更新 HEAD
            if (head_wr_en) begin
                head <= head_ptr;
            end
            // Device 推进 TAIL (消费)
            if (desc_vld && desc_rdy) begin
                tail <= pntx(tail);
            end
        end
    end

    // =========================================================================
    // 存储写入 (Host MMIO, 不检查满/空)
    // =========================================================================
    integer i_wr;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i_wr = 0; i_wr < DEPTH_S; i_wr = i_wr + 1) begin
                mem_entry[i_wr] <= 128'd0;
            end
        end else begin
            if (wr_en) begin
                mem_entry[wr_idx] <= wr_entry;
            end
        end
    end

    // =========================================================================
    // 描述符输出 (组合, 从当前 TAIL 读出)
    // =========================================================================
    wire [127:0] entry_out = mem_entry[tail];

    // 条目字段解包 (对齐 v0 §3.3, 小端序 within 128-bit vector)
    assign desc_id          = entry_out[31:0];
    assign batch_op         = entry_out[39:32];
    assign batch_flags      = entry_out[47:40];
    assign batch_count      = entry_out[63:48];
    assign input_desc_addr  = entry_out[95:64];
    assign output_desc_addr = entry_out[127:96];

    // =========================================================================
    // 状态输出
    // =========================================================================
    assign head_ptr_cur = head;
    assign tail_ptr     = tail;

    assign desc_avail = (head != tail);
    assign desc_vld   = desc_avail;

    // 环满: HEAD+1 == TAIL (留 1 空位区分满/空)
    assign desc_full  = (pntx(head) == tail);

    // desc_lvl: 环内有效条目数 (0..256)
    //   head >= tail  → head - tail
    //   head <  tail  → head + DEPTH - tail
    wire [CNT_W-1:0] lvl_ge = head - tail;
    wire [CNT_W-1:0] lvl_lt = head + (DEPTH_S - tail);
    assign desc_lvl = (head >= tail) ? lvl_ge : lvl_lt;

endmodule