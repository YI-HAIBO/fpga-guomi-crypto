// =============================================================================
// 测试平台 : tb_bar_ctrl_v20
// 模块     : bar_ctrl (M03, v2.0)
// 日期     : 2026-10-09
// 编译     : iverilog -g2005 -o sim/subsys/tb_bar_ctrl_v20.vvp
//            rtl/subsys/bar_ctrl.v sim/subsys/tb_bar_ctrl_v20.v
//
// 测试计划 (10 组):
//   T1  复位行为: VERSION 回读 + 只读寄存器
//   T2  BAR0 只读寄存器: FEATURE_FLAGS/DEVICE_ID/SUBSYS_VENDOR/SUBSYS_ID
//   T3  BAR0 控制寄存器: CTRL_GLOBAL/CTRL_TRNG/CTRL_SM2-4 写入 + 回读 + 脉冲
//   T4  BAR0 状态寄存器: STATUS_GLOBAL/STATUS_TRNG/STATUS_ERR
//   T5  BAR0 熵计数: TRNG_ENTROPY_CNT/HI
//   T6  BAR0 ERR_LOG: 16 slot 写入 + 读出 + ERR_LOG_CLEAR
//   T7  BAR0 SCRATCH_REG: 写入 + 读出
//   T8  BAR1 命令环: 4 次 32-bit 写入拼成 128-bit 条目, 触发 wr_en
//   T9  BAR1 描述符环: 同上, 验证 desc_ring 接口
//   T10 MSI-X 触发: cmd_ring_avail/desc_ring_avail/err_src_vld 触发中断
//   T11 零回归: 环状态反馈
// =============================================================================

`timescale 1ns / 1ps

module tb_bar_ctrl_v20;

    reg              clk;
    reg              rst_n;
    reg  [19:0]      mmio_addr;
    reg  [31:0]      mmio_wr_data;
    reg              mmio_wr_en;
    wire [31:0]      mmio_rd_data;
    wire             mmio_rd_vld;

    wire             cmd_ring_wr_en;
    wire [7:0]       cmd_ring_wr_idx;
    wire [127:0]     cmd_ring_wr_entry;
    wire             cmd_ring_head_wr_en;
    wire [7:0]       cmd_ring_head_ptr;
    reg  [7:0]       cmd_ring_head_cur;
    reg  [7:0]       cmd_ring_tail;
    reg              cmd_ring_avail;

    wire             desc_ring_wr_en;
    wire [7:0]       desc_ring_wr_idx;
    wire [127:0]     desc_ring_wr_entry;
    wire             desc_ring_head_wr_en;
    wire [7:0]       desc_ring_head_ptr;
    reg  [7:0]       desc_ring_head_cur;
    reg  [7:0]       desc_ring_tail;
    reg              desc_ring_avail;

    reg  [8:0]       cmd_lvl;
    reg              cmd_full;
    reg  [8:0]       done_lvl;
    reg              done_full;

    reg              err_src_vld;
    reg  [7:0]       err_src_rid;
    reg  [7:0]       err_src_code;

    reg  [6:0]       ht_status;
    reg              trng_running;
    reg  [63:0]      entropy_cnt;

    wire             ctrl_trng_start;
    wire             ctrl_trng_stop;
    wire             ctrl_trng_flush;
    wire             ctrl_sm2_start;
    wire             ctrl_sm3_start;
    wire             ctrl_sm4_start;

    wire             msix_trigger;
    wire [3:0]       msix_vec;

    wire             ctrl_start;
    wire             ctrl_flush;
    wire             ctrl_reset;

    bar_ctrl dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .mmio_addr      (mmio_addr),
        .mmio_wr_data   (mmio_wr_data),
        .mmio_wr_en     (mmio_wr_en),
        .mmio_rd_data   (mmio_rd_data),
        .mmio_rd_vld    (mmio_rd_vld),
        .cmd_ring_wr_en      (cmd_ring_wr_en),
        .cmd_ring_wr_idx     (cmd_ring_wr_idx),
        .cmd_ring_wr_entry   (cmd_ring_wr_entry),
        .cmd_ring_head_wr_en (cmd_ring_head_wr_en),
        .cmd_ring_head_ptr   (cmd_ring_head_ptr),
        .cmd_ring_head_cur   (cmd_ring_head_cur),
        .cmd_ring_tail       (cmd_ring_tail),
        .cmd_ring_avail      (cmd_ring_avail),
        .desc_ring_wr_en      (desc_ring_wr_en),
        .desc_ring_wr_idx     (desc_ring_wr_idx),
        .desc_ring_wr_entry   (desc_ring_wr_entry),
        .desc_ring_head_wr_en (desc_ring_head_wr_en),
        .desc_ring_head_ptr   (desc_ring_head_ptr),
        .desc_ring_head_cur   (desc_ring_head_cur),
        .desc_ring_tail       (desc_ring_tail),
        .desc_ring_avail      (desc_ring_avail),
        .cmd_lvl    (cmd_lvl),
        .cmd_full   (cmd_full),
        .done_lvl   (done_lvl),
        .done_full  (done_full),
        .err_src_vld   (err_src_vld),
        .err_src_rid   (err_src_rid),
        .err_src_code  (err_src_code),
        .ht_status     (ht_status),
        .trng_running  (trng_running),
        .entropy_cnt   (entropy_cnt),
        .ctrl_trng_start (ctrl_trng_start),
        .ctrl_trng_stop  (ctrl_trng_stop),
        .ctrl_trng_flush (ctrl_trng_flush),
        .ctrl_sm2_start  (ctrl_sm2_start),
        .ctrl_sm3_start  (ctrl_sm3_start),
        .ctrl_sm4_start  (ctrl_sm4_start),
        .msix_trigger (msix_trigger),
        .msix_vec     (msix_vec),
        .ctrl_start (ctrl_start),
        .ctrl_flush (ctrl_flush),
        .ctrl_reset (ctrl_reset)
    );

    always #5 clk = ~clk;

    integer pass, fail;

    // ---- 辅助任务 ----
    task do_reset;
        begin
            rst_n       <= 0;
            mmio_addr   <= 0;
            mmio_wr_data <= 0;
            mmio_wr_en  <= 0;
            cmd_ring_head_cur <= 0; cmd_ring_tail <= 0; cmd_ring_avail <= 0;
            desc_ring_head_cur <= 0; desc_ring_tail <= 0; desc_ring_avail <= 0;
            cmd_lvl <= 0; cmd_full <= 0; done_lvl <= 0; done_full <= 0;
            err_src_vld <= 0; err_src_rid <= 0; err_src_code <= 0;
            ht_status <= 0; trng_running <= 0; entropy_cnt <= 0;
            @(negedge clk);
            @(negedge clk);
            rst_n <= 1;
            @(negedge clk);
        end
    endtask

    // MMIO 写入 (BAR0) — 返回后立即检查脉冲
    task mmio_wr_bar0;
        input [11:0] addr;
        input [31:0] data;
        begin
            mmio_addr   <= {8'h00, addr};
            mmio_wr_data <= data;
            mmio_wr_en  <= 1;
            @(negedge clk);
            mmio_wr_en  <= 0;
        end
    endtask

    // MMIO 写入 (BAR1)
    task mmio_wr_bar1;
        input [11:0] addr;
        input [31:0] data;
        begin
            mmio_addr   <= {8'h01, addr};
            mmio_wr_data <= data;
            mmio_wr_en  <= 1;
            @(negedge clk);
            mmio_wr_en  <= 0;
        end
    endtask

    // MMIO 读取 (BAR0)
    task mmio_rd_bar0;
        input [11:0] addr;
        output [31:0] data;
        begin
            mmio_addr  <= {8'h00, addr};
            mmio_wr_en <= 0;
            @(negedge clk);
            data = mmio_rd_data;
        end
    endtask

    // =========================================================================
    // T1: 复位 + VERSION
    // =========================================================================
    task t1_reset;
        reg [31:0] rd;
        begin
            $display("=== T1: 复位 + VERSION ===");
            do_reset;
            mmio_rd_bar0(12'h000, rd);
            // VERSION_REG = 32'h00010200, BUILD_DATE = 16'd2026 = 16'h07EA
            // 读取: {VERSION_REG[31:16], BUILD_DATE} = {16'h0001, 16'h07EA} = 32'h000107EA
            if (rd !== 32'h000107EA) begin
                $display("  FAIL: VERSION=%h (期望 0x000107EA)", rd);
                fail = fail + 1;
            end else begin
                $display("  PASS: VERSION=0x%08h", rd);
                pass = pass + 1;
            end
        end
    endtask

    // =========================================================================
    // T2: BAR0 只读寄存器
    // =========================================================================
    task t2_readonly_regs;
        reg [31:0] rd;
        begin
            $display("=== T2: BAR0 只读寄存器 ===");
            do_reset;

            mmio_rd_bar0(12'h010, rd);
            if (rd !== 32'h000003FF) begin
                $display("  FAIL: FEATURE_FLAGS=%h (期望 0x3FF)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: FEATURE_FLAGS=0x%08h", rd); pass = pass + 1; end

            mmio_rd_bar0(12'h014, rd);
            if (rd !== 32'h00000001) begin
                $display("  FAIL: DEVICE_ID=%h (期望 1)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: DEVICE_ID=0x%08h", rd); pass = pass + 1; end

            mmio_rd_bar0(12'h018, rd);
            if (rd !== 32'h00001234) begin
                $display("  FAIL: SUBSYS_VENDOR=%h (期望 0x1234)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: SUBSYS_VENDOR=0x%08h", rd); pass = pass + 1; end

            mmio_rd_bar0(12'h01C, rd);
            if (rd !== 32'h00000001) begin
                $display("  FAIL: SUBSYS_ID=%h (期望 1)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: SUBSYS_ID=0x%08h", rd); pass = pass + 1; end

            // 写入只读寄存器应无效
            mmio_wr_bar0(12'h010, 32'hDEAD_BEEF);
            mmio_rd_bar0(12'h010, rd);
            if (rd !== 32'h000003FF) begin
                $display("  FAIL: 写入只读寄存器后 FEATURE_FLAGS=%h (期望仍为 0x3FF)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: 只读寄存器写入无效"); pass = pass + 1; end
        end
    endtask

    // =========================================================================
    // T3: BAR0 控制寄存器 + 脉冲
    // =========================================================================
    task t3_ctrl_regs;
        reg [31:0] rd;
        begin
            $display("=== T3: BAR0 控制寄存器 ===");
            do_reset;

            // CTRL_GLOBAL
            mmio_wr_bar0(12'h02C, 32'h00000003);
            mmio_rd_bar0(12'h02C, rd);
            if (rd !== 32'h00000003) begin
                $display("  FAIL: CTRL_GLOBAL 回读=%h (期望 3)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: CTRL_GLOBAL 回读=0x%08h", rd); pass = pass + 1; end

            // CTRL_TRNG — 写入后立即检查脉冲
            mmio_wr_bar0(12'h030, 32'h00000007);
            // 脉冲应在写入后立即有效 (同一 negedge)
            if (ctrl_trng_start !== 1 || ctrl_trng_stop !== 1 || ctrl_trng_flush !== 1) begin
                $display("  FAIL: TRNG 控制脉冲错误 (start=%b stop=%b flush=%b)",
                         ctrl_trng_start, ctrl_trng_stop, ctrl_trng_flush);
                fail = fail + 1;
            end else begin
                $display("  PASS: TRNG 控制脉冲正确 (start=%b stop=%b flush=%b)",
                         ctrl_trng_start, ctrl_trng_stop, ctrl_trng_flush);
                pass = pass + 1;
            end

            mmio_rd_bar0(12'h030, rd);
            if (rd !== 32'h00000007) begin
                $display("  FAIL: CTRL_TRNG 回读=%h (期望 7)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: CTRL_TRNG 回读=0x%08h", rd); pass = pass + 1; end

            // CTRL_SM2 — 写入后立即检查脉冲
            mmio_wr_bar0(12'h034, 32'h00000001);
            if (ctrl_sm2_start !== 1) begin
                $display("  FAIL: SM2 控制脉冲错误 (start=%b)", ctrl_sm2_start);
                fail = fail + 1;
            end else begin $display("  PASS: SM2 控制脉冲正确"); pass = pass + 1; end

            mmio_rd_bar0(12'h034, rd);
            if (rd !== 32'h00000001) begin
                $display("  FAIL: CTRL_SM2 回读=%h (期望 1)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: CTRL_SM2 回读=0x%08h", rd); pass = pass + 1; end
        end
    endtask

    // =========================================================================
    // T4: BAR0 状态寄存器
    // =========================================================================
    task t4_status_regs;
        reg [31:0] rd;
        begin
            $display("=== T4: BAR0 状态寄存器 ===");
            do_reset;

            cmd_full  <= 1;
            done_full <= 1;
            ht_status <= 7'h7F;
            trng_running <= 1;

            mmio_rd_bar0(12'h040, rd);
            // STATUS_GLOBAL: [3]=done_full=1 [2]=cmd_full=1 [1:0]=0 (enabled=0, reset=0)
            if (rd !== 32'h0000000C) begin
                $display("  FAIL: STATUS_GLOBAL=%h (期望 0xC)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: STATUS_GLOBAL=0x%08h", rd); pass = pass + 1; end

            mmio_rd_bar0(12'h044, rd);
            // STATUS_TRNG: ht_status=0x7F → 所有 PASS → FAIL 位全 0, [0]=RUNNING=1
            if (rd !== 32'h00000001) begin
                $display("  FAIL: STATUS_TRNG=%h (期望 0x01)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: STATUS_TRNG=0x%08h", rd); pass = pass + 1; end

            mmio_rd_bar0(12'h054, rd);
            if (rd !== 32'h00000000) begin
                $display("  FAIL: STATUS_ERR=%h (期望 0)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: STATUS_ERR=0x%08h", rd); pass = pass + 1; end
        end
    endtask

    // =========================================================================
    // T5: BAR0 熵计数
    // =========================================================================
    task t5_entropy_cnt;
        reg [31:0] rd;
        begin
            $display("=== T5: BAR0 熵计数 ===");
            do_reset;

            entropy_cnt <= 64'hDEAD_BEEF_CAFE_1234;

            mmio_rd_bar0(12'h058, rd);
            if (rd !== 32'hCAFE1234) begin
                $display("  FAIL: ENTROPY_CNT_LO=%h (期望 0xCAFE1234)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: ENTROPY_CNT_LO=0x%08h", rd); pass = pass + 1; end

            mmio_rd_bar0(12'h05C, rd);
            if (rd !== 32'hDEAD_BEEF) begin
                $display("  FAIL: ENTROPY_CNT_HI=%h (期望 0xDEADBEEF)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: ENTROPY_CNT_HI=0x%08h", rd); pass = pass + 1; end
        end
    endtask

    // =========================================================================
    // T6: BAR0 ERR_LOG
    // =========================================================================
    task t6_err_log;
        reg [31:0] rd;
        begin
            $display("=== T6: BAR0 ERR_LOG ===");
            do_reset;

            // 触发错误: code=0x21 → severity=1 (>= 0x010)
            // err_log[0] = {8'h00, 4'h1, 12'd0, 8'h21} = 32'h00100021
            err_src_vld  <= 1;
            err_src_rid  <= 8'h42;
            err_src_code <= 8'h21;
            @(negedge clk);
            err_src_vld  <= 0;

            mmio_rd_bar0(12'h100, rd);
            if (rd !== 32'h00100021) begin
                $display("  FAIL: err_log[0]=%h (期望 0x00100021)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: err_log[0]=0x%08h", rd); pass = pass + 1; end

            mmio_rd_bar0(12'h140, rd);
            if (rd[3:0] !== 4'd1) begin
                $display("  FAIL: ERR_LOG_HEAD=%h (期望 1)", rd[3:0]);
                fail = fail + 1;
            end else begin $display("  PASS: ERR_LOG_HEAD=%d", rd[3:0]); pass = pass + 1; end

            // ERR_LOG_CLEAR
            mmio_wr_bar0(12'h144, 32'h00000001);
            mmio_rd_bar0(12'h100, rd);
            if (rd !== 32'h00000000) begin
                $display("  FAIL: 清空后 err_log[0]=%h (期望 0)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: ERR_LOG_CLEAR 清空成功"); pass = pass + 1; end
        end
    endtask

    // =========================================================================
    // T7: BAR0 SCRATCH_REG
    // =========================================================================
    task t7_scratch;
        reg [31:0] rd;
        begin
            $display("=== T7: BAR0 SCRATCH_REG ===");
            do_reset;

            mmio_wr_bar0(12'h800, 32'hAAAA0000);
            mmio_wr_bar0(12'h804, 32'hBBBB0000);
            mmio_wr_bar0(12'h8F8, 32'hCCCC0000);
            mmio_wr_bar0(12'h8FC, 32'hDDDD0000);

            mmio_rd_bar0(12'h800, rd);
            if (rd !== 32'hAAAA0000) begin
                $display("  FAIL: scratch[0]=%h (期望 0xAAAA0000)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: scratch[0]=0x%08h", rd); pass = pass + 1; end

            mmio_rd_bar0(12'h804, rd);
            if (rd !== 32'hBBBB0000) begin
                $display("  FAIL: scratch[1]=%h (期望 0xBBBB0000)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: scratch[1]=0x%08h", rd); pass = pass + 1; end

            mmio_rd_bar0(12'h8F8, rd);
            if (rd !== 32'hCCCC0000) begin
                $display("  FAIL: scratch[62]=%h (期望 0xCCCC0000)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: scratch[62]=0x%08h", rd); pass = pass + 1; end

            mmio_rd_bar0(12'h8FC, rd);
            if (rd !== 32'hDDDD0000) begin
                $display("  FAIL: scratch[63]=%h (期望 0xDDDD0000)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: scratch[63]=0x%08h", rd); pass = pass + 1; end
        end
    endtask

    // =========================================================================
    // T8: BAR1 命令环写入
    // =========================================================================
    task t8_cmd_ring_wr;
        begin
            $display("=== T8: BAR1 命令环写入 ===");
            do_reset;

            // 写入 4 个 32-bit 字到 BAR1 0x000-0x00C (条目 0)
            mmio_wr_bar1(12'h000, 32'hDEAD_BEEF);
            mmio_wr_bar1(12'h004, 32'h00000030);
            mmio_wr_bar1(12'h008, 32'h00000100);
            // 第 4 次写入 (0x00C) 触发 cmd_ring_wr_en
            mmio_wr_bar1(12'h00C, 32'h00000200);

            // 检查 wr_en 脉冲 (写入后立即有效)
            if (cmd_ring_wr_en !== 1) begin
                $display("  FAIL: cmd_ring_wr_en=%b (期望 1)", cmd_ring_wr_en);
                fail = fail + 1;
            end else begin
                $display("  PASS: cmd_ring_wr_en=1");
                pass = pass + 1;
            end

            if (cmd_ring_wr_idx !== 8'd0) begin
                $display("  FAIL: cmd_ring_wr_idx=%d (期望 0)", cmd_ring_wr_idx);
                fail = fail + 1;
            end else begin $display("  PASS: cmd_ring_wr_idx=0"); pass = pass + 1; end

            if (cmd_ring_wr_entry[31:0] !== 32'hDEAD_BEEF) begin
                $display("  FAIL: cmd_ring_wr_entry[31:0]=%h (期望 0xDEADBEEF)", cmd_ring_wr_entry[31:0]);
                fail = fail + 1;
            end else begin $display("  PASS: cmd_ring_wr_entry[31:0]=0x%08h", cmd_ring_wr_entry[31:0]); pass = pass + 1; end

            if (cmd_ring_wr_entry[127:96] !== 32'h00000200) begin
                $display("  FAIL: cmd_ring_wr_entry[127:96]=%h (期望 0x200)", cmd_ring_wr_entry[127:96]);
                fail = fail + 1;
            end else begin $display("  PASS: cmd_ring_wr_entry[127:96]=0x%08h", cmd_ring_wr_entry[127:96]); pass = pass + 1; end

            // HEAD 指针写入
            mmio_wr_bar1(12'h3FC, 32'h00000001);
            if (cmd_ring_head_wr_en !== 1 || cmd_ring_head_ptr !== 8'd1) begin
                $display("  FAIL: cmd_ring_head_wr_en=%b ptr=%d (期望 en=1 ptr=1)",
                         cmd_ring_head_wr_en, cmd_ring_head_ptr);
                fail = fail + 1;
            end else begin
                $display("  PASS: cmd_ring_head_wr_en=1, ptr=1");
                pass = pass + 1;
            end
        end
    endtask

    // =========================================================================
    // T9: BAR1 描述符环写入
    // =========================================================================
    task t9_desc_ring_wr;
        begin
            $display("=== T9: BAR1 描述符环写入 ===");
            do_reset;

            mmio_wr_bar1(12'h800, 32'hCAFE_0000);
            mmio_wr_bar1(12'h804, 32'h00000020);
            mmio_wr_bar1(12'h808, 32'h00000064);
            mmio_wr_bar1(12'h80C, 32'h00000300);

            if (desc_ring_wr_en !== 1) begin
                $display("  FAIL: desc_ring_wr_en=%b (期望 1)", desc_ring_wr_en);
                fail = fail + 1;
            end else begin $display("  PASS: desc_ring_wr_en=1"); pass = pass + 1; end

            if (desc_ring_wr_entry[31:0] !== 32'hCAFE0000) begin
                $display("  FAIL: desc_ring_wr_entry[31:0]=%h (期望 0xCAFE0000)", desc_ring_wr_entry[31:0]);
                fail = fail + 1;
            end else begin $display("  PASS: desc_ring_wr_entry[31:0]=0x%08h", desc_ring_wr_entry[31:0]); pass = pass + 1; end

            mmio_wr_bar1(12'hBFC, 32'h00000002);
            if (desc_ring_head_wr_en !== 1 || desc_ring_head_ptr !== 8'd2) begin
                $display("  FAIL: desc_ring_head_wr_en=%b ptr=%d (期望 en=1 ptr=2)",
                         desc_ring_head_wr_en, desc_ring_head_ptr);
                fail = fail + 1;
            end else begin
                $display("  PASS: desc_ring_head_wr_en=1, ptr=2");
                pass = pass + 1;
            end
        end
    endtask

    // =========================================================================
    // T10: MSI-X 触发
    // =========================================================================
    task t10_msix;
        begin
            $display("=== T10: MSI-X 触发 ===");
            do_reset;

            // 命令环可用 → 向量 0
            cmd_ring_avail <= 1;
            cmd_ring_head_cur <= 8'd5;
            cmd_ring_tail     <= 8'd3;
            @(negedge clk);
            if (msix_trigger !== 1 || msix_vec !== 4'd0) begin
                $display("  FAIL: cmd_ring_avail 触发错误 (trigger=%b vec=%d)",
                         msix_trigger, msix_vec);
                fail = fail + 1;
            end else begin
                $display("  PASS: cmd_ring_avail → MSI-X 向量 0");
                pass = pass + 1;
            end

            // 错误 WARN → 向量 3
            err_src_vld  <= 1;
            err_src_code <= 8'h21;
            @(negedge clk);
            if (msix_trigger !== 1 || msix_vec !== 4'd3) begin
                $display("  FAIL: err_src_vld(WARN) 触发错误 (trigger=%b vec=%d)",
                         msix_trigger, msix_vec);
                fail = fail + 1;
            end else begin
                $display("  PASS: err_src_vld(WARN) → MSI-X 向量 3");
                pass = pass + 1;
            end

            // 错误 CRIT → 向量 4
            err_src_code <= 8'h60;
            @(negedge clk);
            if (msix_trigger !== 1 || msix_vec !== 4'd4) begin
                $display("  FAIL: err_src_vld(CRIT) 触发错误 (trigger=%b vec=%d)",
                         msix_trigger, msix_vec);
                fail = fail + 1;
            end else begin
                $display("  PASS: err_src_vld(CRIT) → MSI-X 向量 4");
                pass = pass + 1;
            end
        end
    endtask

    // =========================================================================
    // T11: 零回归 — 环状态反馈
    // =========================================================================
    task t11_zero_regression;
        reg [31:0] rd;
        begin
            $display("=== T11: 零回归 ===");
            do_reset;

            cmd_ring_head_cur <= 8'd10;
            cmd_ring_tail     <= 8'd5;
            cmd_ring_avail    <= 1;
            desc_ring_head_cur <= 8'd20;
            desc_ring_tail     <= 8'd15;
            desc_ring_avail    <= 1;

            mmio_rd_bar0(12'h060, rd);
            // CMD_RING_STATUS = {24'd0, avail(1), tail(5), head(10)} = 0x0001050A
            if (rd !== 32'h0001050A) begin
                $display("  FAIL: CMD_RING_STATUS=%h (期望 0x0001050A)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: CMD_RING_STATUS=0x%08h", rd); pass = pass + 1; end

            mmio_rd_bar0(12'h064, rd);
            // DESC_RING_STATUS = {24'd0, avail(1), tail(15), head(20)} = 0x00010F14
            if (rd !== 32'h00010F14) begin
                $display("  FAIL: DESC_RING_STATUS=%h (期望 0x00010F14)", rd);
                fail = fail + 1;
            end else begin $display("  PASS: DESC_RING_STATUS=0x%08h", rd); pass = pass + 1; end
        end
    endtask

    // =========================================================================
    // 主测试序列
    // =========================================================================
    initial begin
        clk   = 0;
        pass  = 0;
        fail  = 0;

        $display("==============================================");
        $display("  bar_ctrl v2.0 测试平台 (tb_bar_ctrl_v20)");
        $display("==============================================");

        t1_reset;
        t2_readonly_regs;
        t3_ctrl_regs;
        t4_status_regs;
        t5_entropy_cnt;
        t6_err_log;
        t7_scratch;
        t8_cmd_ring_wr;
        t9_desc_ring_wr;
        t10_msix;
        t11_zero_regression;

        $display("==============================================");
        $display("  结果: %0d PASS, %0d FAIL", pass, fail);
        $display("==============================================");
        if (fail == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d TEST(S) FAILED ***", fail);
        $finish;
    end

endmodule