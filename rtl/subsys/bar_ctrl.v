// =============================================================================
// 模块名称 : bar_ctrl
// 模块编号 : M03 (SS1 - PCIe Front-End, 见 phase1/架构与模块划分说明书_v1.md §2.1)
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v2.0
// 日期     : 2026-10-09
// 变更记录 :
//   v1.0-v1.5 : 见历史版本 (v1.5 对齐 PCIe v0 规格, 见 Phase7 对齐分析文档)
//   v2.0 2026-10-09 Phase 7 v1.5 命令模型迁移:
//       (a) 移除 BAR0 shadow (shadow_head/ia/ib/ic) + doorbell 路径
//       (b) 移除旧命令输出端口 (cmd_wr_en/cmd_rid/cmd_op/cmd_prio/cmd_ia/cmd_ib/cmd_ic)
//       (c) 新增环管理输出端口: cmd_ring_*/desc_ring_* (对齐 cmd_ring_buf/desc_ring_buf)
//       (d) 新增 BAR1 数据面 MMIO 转发: 将 BAR1 命令环/描述符环写入转发到环缓冲
//       (e) 新增 MSI-X 触发输出: msix_trigger/msix_vec
//       (f) 保留全部 v1.5 控制/状态/错误/scratch 寄存器 (零回归)
//       (g) 旧版兼容寄存器 (0x004/0x008/0x00C/0x148-0x154/0x200-0x21C) 移除
//           —— v2.0 不再兼容旧驱动, 驱动须按 v0 规格访问
//
// 视角     : rtl-designer (葛逻辑)
// 时钟     : clk_l400
//
// 功能     : BAR0 控制面 + BAR1 数据面寄存器映射。
//            BAR0 (4KB) - 控制/状态寄存器 [v2.0 对齐 v0 规格]
//            BAR1 (1MB) - 数据面: 命令环/描述符环/TRNG 缓冲/结果缓冲/DMA 区
//
// BAR0 寄存器布局 (mmio_addr[11:0]) — v2.0:
//   0x000 VERSION       RO  [31:28]=MAJOR=1 [27:24]=MINOR=2 [23:16]=PATCH=0 [15:0]=BUILD_DATE
//   0x010 FEATURE_FLAGS RO  bit0-9 特性位图 (当前 0x3FF)
//   0x014 DEVICE_ID     RO  0x0001
//   0x018 SUBSYS_VENDOR RO  0x1234
//   0x01C SUBSYS_ID     RO  0x0001
//   0x02C CTRL_GLOBAL   RW  bit0=ENABLE, bit1=RESET_SOFT
//   0x030 CTRL_TRNG     RW  bit0=START, bit1=STOP, bit2=FLUSH
//   0x034 CTRL_SM2      RW  bit0=START
//   0x038 CTRL_SM3      RW  bit0=START
//   0x03C CTRL_SM4      RW  bit0=START
//   0x040 STATUS_GLOBAL RO  [0]=enabled [1]=reset_active [2]=cmd_busy [3]=done_pending
//   0x044 STATUS_TRNG   RO  [0]=RUNNING [1]=T1_FAIL [2]=T2_FAIL [3]=T3_FAIL
//                                  [4]=T4_FAIL [5]=T5_FAIL [6]=T6_FAIL [7]=T7_FAIL
//   0x048 STATUS_SM2    RO  [0]=busy [1]=err (预留)
//   0x04C STATUS_SM3    RO  [0]=busy [1]=err (预留)
//   0x050 STATUS_SM4    RO  [0]=busy [1]=err (预留)
//   0x054 STATUS_ERR    RW1C [0]=err_flag (粘滞, W1C 清零)
//   0x058 TRNG_ENTROPY_CNT    RO  熵计数低 32 位
//   0x05C TRNG_ENTROPY_CNT_HI RO  熵计数高 32 位
//   0x100-0x13F ERROR_LOG[0..15] RO  16 slot, 格式 {timestamp, severity, errcode}
//   0x140 ERR_LOG_HEAD  RO  [3:0] 当前写指针
//   0x144 ERR_LOG_CLEAR WO  写 1 清空日志 (只清 log, 不清 flag)
//   0x800-0x8FF SCRATCH_REG[0..63] RW  用户 scratch
//
// BAR1 数据面布局 (mmio_addr[19:0]) — v2.0 对齐 v0 §3.1:
//   0x00000-0x003FF  CMD_RING      命令环 (256 × 16B) → cmd_ring_buf
//   0x00400-0x007FF  CMD_RING_RES  命令环结果回写 (预留)
//   0x00800-0x00BFF  DESC_RING     描述符环 (256 × 16B) → desc_ring_buf
//   0x00C00-0x00FFF  DESC_RING_RES 描述符环结果回写 (预留)
//   0x01000-0x01FFF  TRNG_STREAM_BUF TRNG 随机字节缓存
//   0x02000-0x0FFFF  PAYLOAD_BUF   Payload 缓冲
//   0x10000-0x1FFFF  RESULT_BUF    结果缓冲
//   0x40000-0xFFFFF  DMA_PAYLOAD_AREA DMA 大块数据传输
//
// 编译     : iverilog -g2005
// =============================================================================

`timescale 1ns / 1ps

module bar_ctrl (
    input  wire         clk,
    input  wire         rst_n,

    // ---- MMIO 接口 (AXI4-Lite) ----
    input  wire [19:0]  mmio_addr,      // v2.0: 扩展到 20-bit (BAR1 1MB)
    input  wire [31:0]  mmio_wr_data,
    input  wire         mmio_wr_en,
    output reg  [31:0]  mmio_rd_data,
    output reg          mmio_rd_vld,

    // ---- 环管理输出: 命令环 (对接 cmd_ring_buf) ----
    output reg          cmd_ring_wr_en,
    output reg  [7:0]   cmd_ring_wr_idx,
    output reg  [127:0] cmd_ring_wr_entry,
    output reg          cmd_ring_head_wr_en,
    output reg  [7:0]   cmd_ring_head_ptr,
    input  wire [7:0]   cmd_ring_head_cur,
    input  wire [7:0]   cmd_ring_tail,
    input  wire         cmd_ring_avail,

    // ---- 环管理输出: 描述符环 (对接 desc_ring_buf) ----
    output reg          desc_ring_wr_en,
    output reg  [7:0]   desc_ring_wr_idx,
    output reg  [127:0] desc_ring_wr_entry,
    output reg          desc_ring_head_wr_en,
    output reg  [7:0]   desc_ring_head_ptr,
    input  wire [7:0]   desc_ring_head_cur,
    input  wire [7:0]   desc_ring_tail,
    input  wire         desc_ring_avail,

    // ---- 队列状态反馈 ----
    input  wire [8:0]   cmd_lvl,
    input  wire         cmd_full,
    input  wire [8:0]   done_lvl,
    input  wire         done_full,

    // ---- 错误上报接口 ----
    input  wire         err_src_vld,
    input  wire [7:0]   err_src_rid,
    input  wire [7:0]   err_src_code,

    // ---- v1.5 新增: TRNG 健康测试状态 (接 trng_health_test_v3.v) ----
    input  wire [6:0]   ht_status,
    input  wire         trng_running,

    // ---- v1.5 新增: 熵计数 (接 TRNG 模块) ----
    input  wire [63:0]  entropy_cnt,

    // ---- v1.5 新增: 引擎控制输出 ----
    output reg          ctrl_trng_start,
    output reg          ctrl_trng_stop,
    output reg          ctrl_trng_flush,
    output reg          ctrl_sm2_start,
    output reg          ctrl_sm3_start,
    output reg          ctrl_sm4_start,

    // ---- v2.0 新增: MSI-X 触发输出 ----
    output reg          msix_trigger,
    output reg  [3:0]   msix_vec,

    // ---- 队列控制输出 ----
    output reg          ctrl_start,
    output reg          ctrl_flush,
    output reg          ctrl_reset
);

    // =========================================================================
    // 常量
    // =========================================================================
    localparam [31:0] VERSION_REG = 32'h00010200;   // MAJOR=1, MINOR=2, PATCH=0
    localparam [15:0] BUILD_DATE  = 16'd2026;        // 2026-10-09
    localparam [31:0] FEATURE_FLAGS_REG = 32'h000003FF; // bit0-9 set
    localparam [31:0] DEVICE_ID_REG     = 32'h00000001;
    localparam [31:0] SUBSYS_VENDOR_REG = 32'h00001234;
    localparam [31:0] SUBSYS_ID_REG     = 32'h00000001;

    // BAR1 数据面基地址 (用于地址译码)
    // BAR0: mmio_addr[19:12] == 0 (4KB 对齐)
    // BAR1: mmio_addr[19:12] >= 1
    wire is_bar0 = (mmio_addr[19:12] == 8'h00);
    wire is_bar1 = (mmio_addr[19:12] != 8'h00);

    // =========================================================================
    // 控制寄存器
    // =========================================================================
    reg         ctrl_global_en    = 0;
    reg         ctrl_global_rst   = 0;
    reg         ctrl_trng_start_r = 0;
    reg         ctrl_trng_stop_r  = 0;
    reg         ctrl_trng_flush_r = 0;
    reg         ctrl_sm2_start_r  = 0;
    reg         ctrl_sm3_start_r  = 0;
    reg         ctrl_sm4_start_r  = 0;

    // =========================================================================
    // 用户 scratch (v1.5 新增)
    // =========================================================================
    reg [31:0]  scratch_reg [0:63];

    // =========================================================================
    // 错误日志 (v1.5: 16 slot, v0 格式)
    // =========================================================================
    reg [31:0]  err_log [0:15];
    reg [3:0]   err_log_wr_idx = 0;
    reg         err_flag = 0;

    // v0 格式: [31:24]=timestamp, [23:20]=severity, [19:0]=errcode
    wire [7:0]  err_timestamp = 8'd0;
    wire [3:0]  err_severity;
    assign err_severity = (err_src_code >= 8'h40) ? 4'd2 :
                          (err_src_code >= 8'h10) ? 4'd1 :
                                                    4'd0;

    // =========================================================================
    // MMIO 地址解码 + 写入
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            // 注: cmd_ring_wr_en/wr_idx, desc_ring_wr_en/wr_idx 由"环写入使能"
            //     always 块统一驱动(含复位); cmd_ring/desc_ring_head_wr_en 由
            //     "HEAD 指针更新"块驱动; ctrl_trng/sm2/3/4_start 由"引擎控制脉冲"
            //     块驱动; msix_trigger/vec 由"MSI-X 触发"块驱动。
            //     此处只复位本块独占的寄存器, 避免 Synth 8-6859 双驱动告警。
            cmd_ring_wr_entry   <= 0;
            cmd_ring_head_ptr   <= 0;
            desc_ring_wr_entry  <= 0;
            desc_ring_head_ptr  <= 0;
            ctrl_start          <= 0;
            ctrl_flush          <= 0;
            ctrl_reset          <= 0;
            ctrl_global_en      <= 0;
            ctrl_global_rst     <= 0;
            ctrl_trng_start_r   <= 0;
            ctrl_trng_stop_r    <= 0;
            ctrl_trng_flush_r   <= 0;
            ctrl_sm2_start_r    <= 0;
            ctrl_sm3_start_r    <= 0;
            ctrl_sm4_start_r    <= 0;
        end else begin
            if (mmio_wr_en) begin
                if (is_bar0) begin
                    // =========================================================
                    // BAR0 控制面 (4KB)
                    // =========================================================
                    case (mmio_addr[11:0])
                        // ---- 控制寄存器 ----
                        12'h02C: begin
                            ctrl_global_en  <= mmio_wr_data[0];
                            ctrl_global_rst <= mmio_wr_data[1];
                        end
                        12'h030: begin
                            ctrl_trng_start_r <= mmio_wr_data[0];
                            ctrl_trng_stop_r  <= mmio_wr_data[1];
                            ctrl_trng_flush_r <= mmio_wr_data[2];
                        end
                        12'h034: ctrl_sm2_start_r <= mmio_wr_data[0];
                        12'h038: ctrl_sm3_start_r <= mmio_wr_data[0];
                        12'h03C: ctrl_sm4_start_r <= mmio_wr_data[0];

                        // ---- ERR_LOG_CLEAR (WO) ----
                        12'h144: begin
                            if (mmio_wr_data != 0) begin
                                // 清空 err_log (只清 log, 不清 flag)
                                // 在 err_log always 块中处理
                            end
                        end

                        // ---- SCRATCH_REG ----
                        12'h800: scratch_reg[0]  <= mmio_wr_data;
                        12'h804: scratch_reg[1]  <= mmio_wr_data;
                        12'h808: scratch_reg[2]  <= mmio_wr_data;
                        12'h80C: scratch_reg[3]  <= mmio_wr_data;
                        12'h810: scratch_reg[4]  <= mmio_wr_data;
                        12'h814: scratch_reg[5]  <= mmio_wr_data;
                        12'h818: scratch_reg[6]  <= mmio_wr_data;
                        12'h81C: scratch_reg[7]  <= mmio_wr_data;
                        12'h820: scratch_reg[8]  <= mmio_wr_data;
                        12'h824: scratch_reg[9]  <= mmio_wr_data;
                        12'h828: scratch_reg[10] <= mmio_wr_data;
                        12'h82C: scratch_reg[11] <= mmio_wr_data;
                        12'h830: scratch_reg[12] <= mmio_wr_data;
                        12'h834: scratch_reg[13] <= mmio_wr_data;
                        12'h838: scratch_reg[14] <= mmio_wr_data;
                        12'h83C: scratch_reg[15] <= mmio_wr_data;
                        12'h840: scratch_reg[16] <= mmio_wr_data;
                        12'h844: scratch_reg[17] <= mmio_wr_data;
                        12'h848: scratch_reg[18] <= mmio_wr_data;
                        12'h84C: scratch_reg[19] <= mmio_wr_data;
                        12'h850: scratch_reg[20] <= mmio_wr_data;
                        12'h854: scratch_reg[21] <= mmio_wr_data;
                        12'h858: scratch_reg[22] <= mmio_wr_data;
                        12'h85C: scratch_reg[23] <= mmio_wr_data;
                        12'h860: scratch_reg[24] <= mmio_wr_data;
                        12'h864: scratch_reg[25] <= mmio_wr_data;
                        12'h868: scratch_reg[26] <= mmio_wr_data;
                        12'h86C: scratch_reg[27] <= mmio_wr_data;
                        12'h870: scratch_reg[28] <= mmio_wr_data;
                        12'h874: scratch_reg[29] <= mmio_wr_data;
                        12'h878: scratch_reg[30] <= mmio_wr_data;
                        12'h87C: scratch_reg[31] <= mmio_wr_data;
                        12'h880: scratch_reg[32] <= mmio_wr_data;
                        12'h884: scratch_reg[33] <= mmio_wr_data;
                        12'h888: scratch_reg[34] <= mmio_wr_data;
                        12'h88C: scratch_reg[35] <= mmio_wr_data;
                        12'h890: scratch_reg[36] <= mmio_wr_data;
                        12'h894: scratch_reg[37] <= mmio_wr_data;
                        12'h898: scratch_reg[38] <= mmio_wr_data;
                        12'h89C: scratch_reg[39] <= mmio_wr_data;
                        12'h8A0: scratch_reg[40] <= mmio_wr_data;
                        12'h8A4: scratch_reg[41] <= mmio_wr_data;
                        12'h8A8: scratch_reg[42] <= mmio_wr_data;
                        12'h8AC: scratch_reg[43] <= mmio_wr_data;
                        12'h8B0: scratch_reg[44] <= mmio_wr_data;
                        12'h8B4: scratch_reg[45] <= mmio_wr_data;
                        12'h8B8: scratch_reg[46] <= mmio_wr_data;
                        12'h8BC: scratch_reg[47] <= mmio_wr_data;
                        12'h8C0: scratch_reg[48] <= mmio_wr_data;
                        12'h8C4: scratch_reg[49] <= mmio_wr_data;
                        12'h8C8: scratch_reg[50] <= mmio_wr_data;
                        12'h8CC: scratch_reg[51] <= mmio_wr_data;
                        12'h8D0: scratch_reg[52] <= mmio_wr_data;
                        12'h8D4: scratch_reg[53] <= mmio_wr_data;
                        12'h8D8: scratch_reg[54] <= mmio_wr_data;
                        12'h8DC: scratch_reg[55] <= mmio_wr_data;
                        12'h8E0: scratch_reg[56] <= mmio_wr_data;
                        12'h8E4: scratch_reg[57] <= mmio_wr_data;
                        12'h8E8: scratch_reg[58] <= mmio_wr_data;
                        12'h8EC: scratch_reg[59] <= mmio_wr_data;
                        12'h8F0: scratch_reg[60] <= mmio_wr_data;
                        12'h8F4: scratch_reg[61] <= mmio_wr_data;
                        12'h8F8: scratch_reg[62] <= mmio_wr_data;
                        12'h8FC: scratch_reg[63] <= mmio_wr_data;

                        default: begin
                            // BAR0 未识别地址: 无操作
                        end
                    endcase
                end else if (is_bar1) begin
                    // =========================================================
                    // BAR1 数据面 (1MB) — 环缓冲写入转发
                    // =========================================================
                    // BAR1 偏移 (去掉 BAR 基址后的 offset)
                    // mmio_addr[11:0] 为 BAR 内偏移 (4KB 对齐)
                    // mmio_addr[19:12] 为 BAR 号 (0=BAR0, >=1=BAR1)
                    // 对于 BAR1, 实际数据面偏移 = mmio_addr[11:0] + (bar_num-1)*0x1000
                    // 简化: 直接用 mmio_addr[11:0] 区分 BAR1 内区域

                    case (mmio_addr[11:0])
                        // ---- 命令环: 0x000-0x3FF (256 条目 × 16B) ----
                        // 条目写入: 每 16 字节一个条目, 地址 [11:4] = 条目号, [3:0] = 字节内偏移
                        // 简化: 主机以 32-bit 写入, 我们需要重组 128-bit 条目
                        // 方案: 4 次 32-bit 写入拼成一个 128-bit 条目
                        // 条目号 = mmio_addr[11:4], 字节偏移 = mmio_addr[3:0]
                        12'h000: cmd_ring_wr_entry[31:0]    <= mmio_wr_data;
                        12'h004: cmd_ring_wr_entry[63:32]   <= mmio_wr_data;
                        12'h008: cmd_ring_wr_entry[95:64]   <= mmio_wr_data;
                        12'h00C: cmd_ring_wr_entry[127:96]  <= mmio_wr_data;

                        // ---- 命令环 HEAD 指针更新 (0x3FC) ----
                        // 主机写入 HEAD 值 (8-bit), 触发提交
                        12'h3FC: begin
                            cmd_ring_head_ptr <= mmio_wr_data[7:0];
                        end

                        // ---- 描述符环: 0x800-0xBFF (256 条目 × 16B) ----
                        12'h800: desc_ring_wr_entry[31:0]    <= mmio_wr_data;
                        12'h804: desc_ring_wr_entry[63:32]   <= mmio_wr_data;
                        12'h808: desc_ring_wr_entry[95:64]   <= mmio_wr_data;
                        12'h80C: desc_ring_wr_entry[127:96]  <= mmio_wr_data;

                        // ---- 描述符环 HEAD 指针更新 (0xBFC) ----
                        12'hBFC: begin
                            desc_ring_head_ptr <= mmio_wr_data[7:0];
                        end

                        default: begin
                            // BAR1 其他区域: 无操作 (TRNG/Payload/Result/DMA 区由各自模块处理)
                        end
                    endcase
                end
            end
        end
    end

    // =========================================================================
    // 环写入使能控制 (检测 4 次 32-bit 写入完成)
    // =========================================================================
    // 当主机完成一个 128-bit 条目的 4 次写入 (最后一个字节偏移 = 0xC),
    // 触发 wr_en 脉冲。
    // 简化: 每次写入 0x00C (条目最后一个 32-bit 字) 时触发 wr_en。
    always @(posedge clk) begin
        if (!rst_n) begin
            cmd_ring_wr_en    <= 0;
            cmd_ring_wr_idx   <= 0;
            desc_ring_wr_en   <= 0;
            desc_ring_wr_idx  <= 0;
        end else begin
            cmd_ring_wr_en    <= 0;
            desc_ring_wr_en   <= 0;

            if (mmio_wr_en && is_bar1) begin
                // 命令环: 写入 0x00C (条目最后一个字) → 触发
                if (mmio_addr[11:0] == 12'h00C) begin
                    cmd_ring_wr_en  <= 1;
                    cmd_ring_wr_idx <= mmio_addr[11:4];  // 条目号 = 地址 [11:4]
                end
                // 描述符环: 写入 0x80C (条目最后一个字) → 触发
                if (mmio_addr[11:0] == 12'h80C) begin
                    desc_ring_wr_en  <= 1;
                    desc_ring_wr_idx <= mmio_addr[11:4];  // 条目号 = 地址 [11:4]
                end
            end
        end
    end

    // =========================================================================
    // HEAD 指针更新使能 (检测 HEAD 指针写入)
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            cmd_ring_head_wr_en <= 0;
            desc_ring_head_wr_en <= 0;
        end else begin
            cmd_ring_head_wr_en  <= 0;
            desc_ring_head_wr_en <= 0;

            if (mmio_wr_en && is_bar1) begin
                if (mmio_addr[11:0] == 12'h3FC) begin
                    cmd_ring_head_wr_en <= 1;
                end
                if (mmio_addr[11:0] == 12'hBFC) begin
                    desc_ring_head_wr_en <= 1;
                end
            end
        end
    end

    // =========================================================================
    // 引擎控制脉冲输出
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            ctrl_trng_start <= 0;
            ctrl_trng_stop  <= 0;
            ctrl_trng_flush <= 0;
            ctrl_sm2_start  <= 0;
            ctrl_sm3_start  <= 0;
            ctrl_sm4_start  <= 0;
        end else begin
            ctrl_trng_start <= mmio_wr_en && is_bar0 && (mmio_addr[11:0] == 12'h030) && mmio_wr_data[0];
            ctrl_trng_stop  <= mmio_wr_en && is_bar0 && (mmio_addr[11:0] == 12'h030) && mmio_wr_data[1];
            ctrl_trng_flush <= mmio_wr_en && is_bar0 && (mmio_addr[11:0] == 12'h030) && mmio_wr_data[2];
            ctrl_sm2_start  <= mmio_wr_en && is_bar0 && (mmio_addr[11:0] == 12'h034) && mmio_wr_data[0];
            ctrl_sm3_start  <= mmio_wr_en && is_bar0 && (mmio_addr[11:0] == 12'h038) && mmio_wr_data[0];
            ctrl_sm4_start  <= mmio_wr_en && is_bar0 && (mmio_addr[11:0] == 12'h03C) && mmio_wr_data[0];
        end
    end

    // =========================================================================
    // MSI-X 触发输出
    // =========================================================================
    // 当命令环或描述符环有新命令可用时触发对应 MSI-X 向量
    always @(posedge clk) begin
        if (!rst_n) begin
            msix_trigger <= 0;
            msix_vec     <= 0;
        end else begin
            msix_trigger <= 0;
            msix_vec     <= 0;

            // 命令环有新命令 → 向量 0 (CMD_BATCH_DONE)
            if (cmd_ring_avail && cmd_ring_head_cur != cmd_ring_tail) begin
                msix_trigger <= 1;
                msix_vec     <= 4'd0;
            end
            // 描述符环有新描述符 → 向量 1 (DESC_BATCH_DONE)
            if (desc_ring_avail && desc_ring_head_cur != desc_ring_tail) begin
                msix_trigger <= 1;
                msix_vec     <= 4'd1;
            end
            // 错误 → 向量 3 (ERR_WARN) 或 4 (ERR_CRIT)
            if (err_src_vld) begin
                msix_trigger <= 1;
                msix_vec     <= (err_src_code >= 8'h40) ? 4'd4 : 4'd3;
            end
        end
    end

    // =========================================================================
    // 错误日志写入 + 清零 (v1.5: 16 slot, v0 格式, 优先级不变)
    // =========================================================================
    integer i_rst;
    always @(posedge clk) begin
        if (!rst_n) begin
            err_log_wr_idx <= 0;
            err_flag       <= 0;
            for (i_rst = 0; i_rst < 16; i_rst = i_rst + 1)
                err_log[i_rst] = 32'd0;
        end else if (err_src_vld) begin
            // v0 格式: [31:24]=timestamp, [23:20]=severity, [19:0]=errcode
            err_log[err_log_wr_idx] <= {err_timestamp, err_severity, 12'd0, err_src_code};
            err_flag                <= 1;
            if (err_log_wr_idx == 4'd15)
                err_log_wr_idx <= 0;
            else
                err_log_wr_idx <= err_log_wr_idx + 1'b1;
        end else if (mmio_wr_en && is_bar0 && (mmio_addr == 12'h144) && (mmio_wr_data != 0)) begin
            // ERR_LOG_CLEAR (WO): 只清 err_log, 不清 err_flag
            err_log_wr_idx <= 0;
            for (i_rst = 0; i_rst < 16; i_rst = i_rst + 1)
                err_log[i_rst] <= 32'd0;
        end
    end

    // =========================================================================
    // MMIO 读取
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            mmio_rd_data <= 0;
            mmio_rd_vld  <= 0;
        end else begin
            mmio_rd_vld <= 1'b1;

            if (is_bar0) begin
                // =========================================================
                // BAR0 控制面读取
                // =========================================================
                case (mmio_addr[11:0])
                    // ---- 版本 / 设备 ID ----
                    12'h000: mmio_rd_data <= {VERSION_REG[31:16], BUILD_DATE};
                    12'h010: mmio_rd_data <= FEATURE_FLAGS_REG;
                    12'h014: mmio_rd_data <= DEVICE_ID_REG;
                    12'h018: mmio_rd_data <= SUBSYS_VENDOR_REG;
                    12'h01C: mmio_rd_data <= SUBSYS_ID_REG;

                    // ---- 控制寄存器回读 ----
                    12'h02C: mmio_rd_data <= {30'd0, ctrl_global_rst, ctrl_global_en};
                    12'h030: mmio_rd_data <= {29'd0, ctrl_trng_flush_r, ctrl_trng_stop_r, ctrl_trng_start_r};
                    12'h034: mmio_rd_data <= {31'd0, ctrl_sm2_start_r};
                    12'h038: mmio_rd_data <= {31'd0, ctrl_sm3_start_r};
                    12'h03C: mmio_rd_data <= {31'd0, ctrl_sm4_start_r};

                    // ---- 状态寄存器 ----
                    12'h040: mmio_rd_data <= {28'd0, done_full, cmd_full, ctrl_global_rst, ctrl_global_en};
                    12'h044: mmio_rd_data <= {24'd0,
                                               ~ht_status[6],   // [7] T7_FAIL
                                               ~ht_status[5],   // [6] T6_FAIL
                                               ~ht_status[4],   // [5] T5_FAIL
                                               ~ht_status[0],   // [4] T4_FAIL
                                               ~ht_status[1],   // [3] T3_FAIL
                                               ~ht_status[2],   // [2] T2_FAIL
                                               ~ht_status[3],   // [1] T1_FAIL
                                               trng_running};   // [0] RUNNING
                    12'h048: mmio_rd_data <= 32'd0;   // STATUS_SM2 (预留)
                    12'h04C: mmio_rd_data <= 32'd0;   // STATUS_SM3 (预留)
                    12'h050: mmio_rd_data <= 32'd0;   // STATUS_SM4 (预留)
                    12'h054: mmio_rd_data <= {31'd0, err_flag};  // STATUS_ERR

                    // ---- 熵计数 ----
                    12'h058: mmio_rd_data <= entropy_cnt[31:0];
                    12'h05C: mmio_rd_data <= entropy_cnt[63:32];

                    // ---- ERR_LOG (16 slot, 0x100-0x13F) ----
                    12'h100: mmio_rd_data <= err_log[0];
                    12'h104: mmio_rd_data <= err_log[1];
                    12'h108: mmio_rd_data <= err_log[2];
                    12'h10C: mmio_rd_data <= err_log[3];
                    12'h110: mmio_rd_data <= err_log[4];
                    12'h114: mmio_rd_data <= err_log[5];
                    12'h118: mmio_rd_data <= err_log[6];
                    12'h11C: mmio_rd_data <= err_log[7];
                    12'h120: mmio_rd_data <= err_log[8];
                    12'h124: mmio_rd_data <= err_log[9];
                    12'h128: mmio_rd_data <= err_log[10];
                    12'h12C: mmio_rd_data <= err_log[11];
                    12'h130: mmio_rd_data <= err_log[12];
                    12'h134: mmio_rd_data <= err_log[13];
                    12'h138: mmio_rd_data <= err_log[14];
                    12'h13C: mmio_rd_data <= err_log[15];

                    // ---- ERR_LOG_HEAD ----
                    12'h140: mmio_rd_data <= {28'd0, err_log_wr_idx};

                    // ---- ERR_LOG_CLEAR: WO, 读回 0 ----
                    12'h144: mmio_rd_data <= 32'd0;

                    // ---- SCRATCH_REG ----
                    12'h800: mmio_rd_data <= scratch_reg[0];
                    12'h804: mmio_rd_data <= scratch_reg[1];
                    12'h808: mmio_rd_data <= scratch_reg[2];
                    12'h80C: mmio_rd_data <= scratch_reg[3];
                    12'h810: mmio_rd_data <= scratch_reg[4];
                    12'h814: mmio_rd_data <= scratch_reg[5];
                    12'h818: mmio_rd_data <= scratch_reg[6];
                    12'h81C: mmio_rd_data <= scratch_reg[7];
                    12'h820: mmio_rd_data <= scratch_reg[8];
                    12'h824: mmio_rd_data <= scratch_reg[9];
                    12'h828: mmio_rd_data <= scratch_reg[10];
                    12'h82C: mmio_rd_data <= scratch_reg[11];
                    12'h830: mmio_rd_data <= scratch_reg[12];
                    12'h834: mmio_rd_data <= scratch_reg[13];
                    12'h838: mmio_rd_data <= scratch_reg[14];
                    12'h83C: mmio_rd_data <= scratch_reg[15];
                    12'h840: mmio_rd_data <= scratch_reg[16];
                    12'h844: mmio_rd_data <= scratch_reg[17];
                    12'h848: mmio_rd_data <= scratch_reg[18];
                    12'h84C: mmio_rd_data <= scratch_reg[19];
                    12'h850: mmio_rd_data <= scratch_reg[20];
                    12'h854: mmio_rd_data <= scratch_reg[21];
                    12'h858: mmio_rd_data <= scratch_reg[22];
                    12'h85C: mmio_rd_data <= scratch_reg[23];
                    12'h860: mmio_rd_data <= scratch_reg[24];
                    12'h864: mmio_rd_data <= scratch_reg[25];
                    12'h868: mmio_rd_data <= scratch_reg[26];
                    12'h86C: mmio_rd_data <= scratch_reg[27];
                    12'h870: mmio_rd_data <= scratch_reg[28];
                    12'h874: mmio_rd_data <= scratch_reg[29];
                    12'h878: mmio_rd_data <= scratch_reg[30];
                    12'h87C: mmio_rd_data <= scratch_reg[31];
                    12'h880: mmio_rd_data <= scratch_reg[32];
                    12'h884: mmio_rd_data <= scratch_reg[33];
                    12'h888: mmio_rd_data <= scratch_reg[34];
                    12'h88C: mmio_rd_data <= scratch_reg[35];
                    12'h890: mmio_rd_data <= scratch_reg[36];
                    12'h894: mmio_rd_data <= scratch_reg[37];
                    12'h898: mmio_rd_data <= scratch_reg[38];
                    12'h89C: mmio_rd_data <= scratch_reg[39];
                    12'h8A0: mmio_rd_data <= scratch_reg[40];
                    12'h8A4: mmio_rd_data <= scratch_reg[41];
                    12'h8A8: mmio_rd_data <= scratch_reg[42];
                    12'h8AC: mmio_rd_data <= scratch_reg[43];
                    12'h8B0: mmio_rd_data <= scratch_reg[44];
                    12'h8B4: mmio_rd_data <= scratch_reg[45];
                    12'h8B8: mmio_rd_data <= scratch_reg[46];
                    12'h8BC: mmio_rd_data <= scratch_reg[47];
                    12'h8C0: mmio_rd_data <= scratch_reg[48];
                    12'h8C4: mmio_rd_data <= scratch_reg[49];
                    12'h8C8: mmio_rd_data <= scratch_reg[50];
                    12'h8CC: mmio_rd_data <= scratch_reg[51];
                    12'h8D0: mmio_rd_data <= scratch_reg[52];
                    12'h8D4: mmio_rd_data <= scratch_reg[53];
                    12'h8D8: mmio_rd_data <= scratch_reg[54];
                    12'h8DC: mmio_rd_data <= scratch_reg[55];
                    12'h8E0: mmio_rd_data <= scratch_reg[56];
                    12'h8E4: mmio_rd_data <= scratch_reg[57];
                    12'h8E8: mmio_rd_data <= scratch_reg[58];
                    12'h8EC: mmio_rd_data <= scratch_reg[59];
                    12'h8F0: mmio_rd_data <= scratch_reg[60];
                    12'h8F4: mmio_rd_data <= scratch_reg[61];
                    12'h8F8: mmio_rd_data <= scratch_reg[62];
                    12'h8FC: mmio_rd_data <= scratch_reg[63];

                    // ---- 环状态反馈 (v2.0 新增) ----
                    // 0x060: CMD_RING_STATUS = {head_cur, tail, avail}
                    12'h060: mmio_rd_data <= {24'd0, cmd_ring_avail, cmd_ring_tail, cmd_ring_head_cur};
                    // 0x064: DESC_RING_STATUS
                    12'h064: mmio_rd_data <= {24'd0, desc_ring_avail, desc_ring_tail, desc_ring_head_cur};

                    default: begin
                        mmio_rd_data <= 32'd0;
                    end
                endcase
            end else if (is_bar1) begin
                // =========================================================
                // BAR1 数据面读取
                // =========================================================
                case (mmio_addr[11:0])
                    // 命令环条目读取 (回读最后写入的条目)
                    12'h000: mmio_rd_data <= cmd_ring_wr_entry[31:0];
                    12'h004: mmio_rd_data <= cmd_ring_wr_entry[63:32];
                    12'h008: mmio_rd_data <= cmd_ring_wr_entry[95:64];
                    12'h00C: mmio_rd_data <= cmd_ring_wr_entry[127:96];

                    // 描述符环条目读取
                    12'h800: mmio_rd_data <= desc_ring_wr_entry[31:0];
                    12'h804: mmio_rd_data <= desc_ring_wr_entry[63:32];
                    12'h808: mmio_rd_data <= desc_ring_wr_entry[95:64];
                    12'h80C: mmio_rd_data <= desc_ring_wr_entry[127:96];

                    // HEAD 指针回读
                    12'h3FC: mmio_rd_data <= {24'd0, cmd_ring_head_cur};
                    12'hBFC: mmio_rd_data <= {24'd0, desc_ring_head_cur};

                    default: begin
                        mmio_rd_data <= 32'd0;
                    end
                endcase
            end else begin
                mmio_rd_data <= 32'd0;
            end
        end
    end

endmodule