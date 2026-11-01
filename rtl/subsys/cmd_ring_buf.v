// =============================================================================
// 模块名称 : cmd_ring_buf
// 模块编号 : M07 (SS1 - PCIe Front-End, v1.5 命令模型迁移 Phase A1)
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.1 (BRAM 版本, 减少 FF 占用)
// 日期     : 2026-10-17
// 视角     : rtl-designer (葛逻辑)
// 时钟     : clk_l400 (100 MHz, PCIe Gen2 参考时钟)
//
// 功能     : BAR1 命令环缓冲。256 条目 × 16 字节, 支持 HEAD/TAIL 指针管理。
//            Host 经 BAR1 MMIO 写入条目 + 更新 HEAD (生产者);
//            Device 经 cmd_vld/cmd_rdy 握手消费条目 + 推进 TAIL (消费者)。
//
// v1.1 变更: 使用 BRAM 替代寄存器阵列, 减少 ~28K FF 占用
//            移除 reset 循环 (BRAM 不支持逐条目 reset)
//            添加 RAM_STYLE="block" 属性强制 BRAM 推断
//
// 条目格式 (16 字节, 对齐 v0 §3.2):
//   Byte 0-3   : cmd_id (32-bit, 单调递增)
//   Byte 4     : cmd_type (0x01=TRNG, 0x10=SM2_SIGN, 0x20=SM3, 0x30=SM4_*,
//                                 0x40=KEY_*, 0xFF=NOOP)
//   Byte 5     : flags
//   Byte 6-7   : payload_len
//   Byte 8-11  : payload_addr (host physical, 4 KB aligned)
//   Byte 12-15 : result_addr (host physical, 4 KB aligned)
//
// 设计约定:
//   - HEAD 由 Host 管理 (head_wr_en/head_ptr), 模块存储并回读 head_ptr_cur。
//   - TAIL 由 Device 内部管理, cmd_vld & cmd_rdy 时自动推进。
//   - cmd_avail = (HEAD != TAIL); cmd_full = ((HEAD+1) == TAIL) 留 1 空位。
//   - cmd_lvl 为环内有效条目数 (0..256), 由 HEAD/TAIL 计算。
//   - 写入 (wr_en/wr_idx/wr_entry) 不检查满/空 —— Host 负责协议。
//
// 编译     : iverilog -g2005
// =============================================================================

`timescale 1ns / 1ps

module cmd_ring_buf #(
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

    // ---- 命令可用 ----
    output wire             cmd_avail,     // HEAD != TAIL, 有命令可取

    // ---- 命令输出 (到 cmd_parser / 调度器) ----
    output wire             cmd_vld,       // = cmd_avail
    input  wire             cmd_rdy,
    output wire [31:0]      cmd_id,
    output wire [7:0]       cmd_type,
    output wire [7:0]       cmd_flags,
    output wire [15:0]      cmd_payload_len,
    output wire [31:0]      cmd_payload_addr,
    output wire [31:0]      cmd_result_addr,

    // ---- 状态 ----
    output wire [CNT_W-1:0] cmd_lvl,       // 环内有效条目数 (0..256)
    output wire             cmd_full       // 环满 (留 1 空位)
);

    // =========================================================================
    // 存储阵列 (256 × 128-bit, BRAM 版本)
    // =========================================================================
    localparam DEPTH_S = DEPTH;

    (* RAM_STYLE = "block" *)
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
    // 指针更新
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
            if (cmd_vld && cmd_rdy) begin
                tail <= pntx(tail);
            end
        end
    end

    // =========================================================================
    // 存储写入 (Host MMIO, 不检查满/空)
    // BRAM 不支持 reset, 条目初始值未定义 (Host 负责写入后再提交)
    // =========================================================================
    always @(posedge clk) begin
        if (wr_en) begin
            mem_entry[wr_idx] <= wr_entry;
        end
    end

    // =========================================================================
    // 命令输出 (组合, 从当前 TAIL 读出)
    // =========================================================================
    wire [127:0] entry_out = mem_entry[tail];

    // 条目字段解包 (对齐 v0 §3.2, 小端序 within 128-bit vector)
    assign cmd_id          = entry_out[31:0];
    assign cmd_type        = entry_out[39:32];
    assign cmd_flags       = entry_out[47:40];
    assign cmd_payload_len = entry_out[63:48];
    assign cmd_payload_addr = entry_out[95:64];
    assign cmd_result_addr = entry_out[127:96];

    // =========================================================================
    // 状态输出
    // =========================================================================
    assign head_ptr_cur = head;
    assign tail_ptr     = tail;

    assign cmd_avail = (head != tail);
    assign cmd_vld   = cmd_avail;

    // 环满: HEAD+1 == TAIL (留 1 空位区分满/空)
    assign cmd_full  = (pntx(head) == tail);

    // cmd_lvl: 环内有效条目数 (0..256)
    //   head >= tail  → head - tail
    //   head <  tail  → head + DEPTH - tail
    wire [CNT_W-1:0] lvl_ge = head - tail;
    wire [CNT_W-1:0] lvl_lt = head + (DEPTH_S - tail);
    assign cmd_lvl = (head >= tail) ? lvl_ge : lvl_lt;

endmodule
