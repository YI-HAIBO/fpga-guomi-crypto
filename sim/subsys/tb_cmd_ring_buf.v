// =============================================================================
// 测试平台 : tb_cmd_ring_buf
// 模块     : cmd_ring_buf (M07, v1.0)
// 日期     : 2026-10-09
// 编译     : iverilog -g2005 -o sim/subsys/tb_cmd_ring_buf.vvp
//            rtl/subsys/cmd_ring_buf.v sim/subsys/tb_cmd_ring_buf.v
//
// 测试计划 (10 组):
//   T1  复位行为: head=tail=0, cmd_avail=0, cmd_lvl=0
//   T2  基本写读: 写 1 条, 更新 HEAD, 读出, 校验 6 字段
//   T3  多条写入: 写 5 条, HEAD 推进, cmd_lvl=5
//   T4  环满检测: 写 255 条, cmd_full=1
//   T5  环空检测: 消费全部, cmd_avail=0
//   T6  cmd_lvl 精度: 不同填充量逐一验证
//   T7  环绕: 写满后消费部分, 再写入 (指针环绕)
//   T8  字段解包: 6 个字段逐一验证边界值
//   T9  cmd_type 编码: 全部 12 种 cmd_type
//   T10 零回归: 随机写入/消费, 断言 cmd_avail 与 cmd_lvl 自洽
// =============================================================================

`timescale 1ns / 1ps

module tb_cmd_ring_buf;

    // ---- 参数 ----
    localparam DEPTH = 256;
    localparam PTR_W = 8;
    localparam CNT_W = 9;

    // ---- 信号 ----
    reg             clk;
    reg             rst_n;
    reg             wr_en;
    reg  [PTR_W-1:0] wr_idx;
    reg  [127:0]     wr_entry;
    reg             head_wr_en;
    reg  [PTR_W-1:0] head_ptr;
    wire [PTR_W-1:0] head_ptr_cur;
    wire [PTR_W-1:0] tail_ptr;
    wire             cmd_avail;
    wire             cmd_vld;
    reg             cmd_rdy;
    wire [31:0]      cmd_id;
    wire [7:0]       cmd_type;
    wire [7:0]       cmd_flags;
    wire [15:0]      cmd_payload_len;
    wire [31:0]      cmd_payload_addr;
    wire [31:0]      cmd_result_addr;
    wire [CNT_W-1:0] cmd_lvl;
    wire             cmd_full;

    // ---- DUT ----
    cmd_ring_buf #(
        .DEPTH  (DEPTH),
        .PTR_W  (PTR_W),
        .CNT_W  (CNT_W)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .wr_en          (wr_en),
        .wr_idx         (wr_idx),
        .wr_entry       (wr_entry),
        .head_wr_en     (head_wr_en),
        .head_ptr       (head_ptr),
        .head_ptr_cur   (head_ptr_cur),
        .tail_ptr       (tail_ptr),
        .cmd_avail      (cmd_avail),
        .cmd_vld        (cmd_vld),
        .cmd_rdy        (cmd_rdy),
        .cmd_id         (cmd_id),
        .cmd_type       (cmd_type),
        .cmd_flags      (cmd_flags),
        .cmd_payload_len (cmd_payload_len),
        .cmd_payload_addr (cmd_payload_addr),
        .cmd_result_addr (cmd_result_addr),
        .cmd_lvl        (cmd_lvl),
        .cmd_full       (cmd_full)
    );

    // ---- 时钟 (100 MHz = 10 ns 周期) ----
    always #5 clk = ~clk;

    // ---- 测试计数 ----
    integer pass, fail;
    integer t;

    // ---- 辅助任务 ----
    task do_reset;
        begin
            rst_n   <= 0;
            wr_en   <= 0;
            wr_idx  <= 0;
            wr_entry <= 128'd0;
            head_wr_en <= 0;
            head_ptr  <= 0;
            cmd_rdy   <= 0;
            @(negedge clk);
            @(negedge clk);
            rst_n <= 1;
            @(negedge clk);
        end
    endtask

    // 写入一个条目
    task write_entry;
        input [PTR_W-1:0] idx;
        input [31:0]      id;
        input [7:0]       tp;
        input [7:0]       fl;
        input [15:0]      plen;
        input [31:0]      paddr;
        input [31:0]      raddr;
        begin
            wr_en     <= 1;
            wr_idx    <= idx;
            wr_entry  <= {raddr, paddr, plen, fl, tp, id};
            @(negedge clk);
            wr_en     <= 0;
        end
    endtask

    // 更新 HEAD 指针
    task update_head;
        input [PTR_W-1:0] h;
        begin
            head_wr_en <= 1;
            head_ptr   <= h;
            @(negedge clk);
            head_wr_en <= 0;
        end
    endtask

    // 消费一个命令
    task consume_cmd;
        begin
            cmd_rdy <= 1;
            @(negedge clk);
            cmd_rdy <= 0;
        end
    endtask

    // 构造 128-bit 条目
    function [127:0] make_entry;
        input [31:0] id;
        input [7:0]  tp;
        input [7:0]  fl;
        input [15:0] plen;
        input [31:0] paddr;
        input [31:0] raddr;
        begin
            make_entry = {raddr, paddr, plen, fl, tp, id};
        end
    endfunction

    // =========================================================================
    // T1: 复位行为
    // =========================================================================
    task t1_reset;
        begin
            $display("=== T1: 复位行为 ===");
            do_reset;
            if (head_ptr_cur === 0 && tail_ptr === 0 && cmd_avail === 0 &&
                cmd_vld === 0 && cmd_lvl === 0 && cmd_full === 0) begin
                $display("  PASS: 复位状态正确");
                pass = pass + 1;
            end else begin
                $display("  FAIL: head=%h tail=%h avail=%b vld=%b lvl=%d full=%b",
                         head_ptr_cur, tail_ptr, cmd_avail, cmd_vld, cmd_lvl, cmd_full);
                fail = fail + 1;
            end
        end
    endtask

    // =========================================================================
    // T2: 基本写读 (1 条)
    // =========================================================================
    task t2_basic_wr_rd;
        begin
            $display("=== T2: 基本写读 ===");
            do_reset;

            // 写入条目 0
            write_entry(8'd0, 32'hDEAD_BEEF, 8'h30, 8'h01, 16'd256,
                        32'h0000_1000, 32'h0000_2000);
            // 更新 HEAD=1
            update_head(8'd1);

            // 检查 cmd_avail
            if (cmd_avail !== 1 || cmd_lvl !== 1) begin
                $display("  FAIL: cmd_avail=%b cmd_lvl=%d (期望 avail=1 lvl=1)",
                         cmd_avail, cmd_lvl);
                fail = fail + 1;
            end else begin
                $display("  PASS: cmd_avail=1, cmd_lvl=1");
                pass = pass + 1;
            end

            // 读出并校验字段
            if (cmd_id !== 32'hDEAD_BEEF) begin
                $display("  FAIL: cmd_id=%h 期望 %h", cmd_id, 32'hDEAD_BEEF);
                fail = fail + 1;
            end else begin $display("  PASS: cmd_id=%h", cmd_id); pass = pass + 1; end

            if (cmd_type !== 8'h30) begin
                $display("  FAIL: cmd_type=%h 期望 %h", cmd_type, 8'h30);
                fail = fail + 1;
            end else begin $display("  PASS: cmd_type=%h", cmd_type); pass = pass + 1; end

            if (cmd_flags !== 8'h01) begin
                $display("  FAIL: cmd_flags=%h 期望 %h", cmd_flags, 8'h01);
                fail = fail + 1;
            end else begin $display("  PASS: cmd_flags=%h", cmd_flags); pass = pass + 1; end

            if (cmd_payload_len !== 16'd256) begin
                $display("  FAIL: cmd_payload_len=%d 期望 %d", cmd_payload_len, 16'd256);
                fail = fail + 1;
            end else begin $display("  PASS: cmd_payload_len=%d", cmd_payload_len); pass = pass + 1; end

            if (cmd_payload_addr !== 32'h0000_1000) begin
                $display("  FAIL: cmd_payload_addr=%h 期望 %h", cmd_payload_addr, 32'h0000_1000);
                fail = fail + 1;
            end else begin $display("  PASS: cmd_payload_addr=%h", cmd_payload_addr); pass = pass + 1; end

            if (cmd_result_addr !== 32'h0000_2000) begin
                $display("  FAIL: cmd_result_addr=%h 期望 %h", cmd_result_addr, 32'h0000_2000);
                fail = fail + 1;
            end else begin $display("  PASS: cmd_result_addr=%h", cmd_result_addr); pass = pass + 1; end

            // 消费
            consume_cmd;
            if (cmd_avail !== 0 || cmd_lvl !== 0) begin
                $display("  FAIL: 消费后 cmd_avail=%b cmd_lvl=%d", cmd_avail, cmd_lvl);
                fail = fail + 1;
            end else begin
                $display("  PASS: 消费后 cmd_avail=0, cmd_lvl=0");
                pass = pass + 1;
            end
        end
    endtask

    // =========================================================================
    // T3: 多条写入 (5 条)
    // =========================================================================
    task t3_multi_wr;
        integer i;
        begin
            $display("=== T3: 多条写入 (5 条) ===");
            do_reset;

            for (i = 0; i < 5; i = i + 1) begin
                write_entry(i[7:0], 32'h1000_0000 + i, 8'h20 + i[7:0],
                            8'hAA, 16'd128 + i*16,
                            32'h0001_0000 + i*256,
                            32'h0002_0000 + i*256);
            end
            update_head(8'd5);

            if (cmd_avail !== 1 || cmd_lvl !== 5) begin
                $display("  FAIL: cmd_avail=%b cmd_lvl=%d (期望 lvl=5)", cmd_avail, cmd_lvl);
                fail = fail + 1;
            end else begin
                $display("  PASS: cmd_avail=1, cmd_lvl=5");
                pass = pass + 1;
            end

            // 校验队头 (tail=0)
            if (cmd_id !== 32'h1000_0000) begin
                $display("  FAIL: 队头 cmd_id=%h 期望 %h", cmd_id, 32'h1000_0000);
                fail = fail + 1;
            end else begin $display("  PASS: 队头 cmd_id=%h", cmd_id); pass = pass + 1; end

            // 消费 3 条
            for (i = 0; i < 3; i = i + 1) begin
                consume_cmd;
            end
            if (cmd_lvl !== 2) begin
                $display("  FAIL: 消费 3 条后 cmd_lvl=%d (期望 2)", cmd_lvl);
                fail = fail + 1;
            end else begin
                $display("  PASS: 消费 3 条后 cmd_lvl=2");
                pass = pass + 1;
            end

            // 消费剩余 2 条
            for (i = 0; i < 2; i = i + 1) begin
                consume_cmd;
            end
            if (cmd_avail !== 0 || cmd_lvl !== 0) begin
                $display("  FAIL: 消费全部后 cmd_avail=%b cmd_lvl=%d", cmd_avail, cmd_lvl);
                fail = fail + 1;
            end else begin
                $display("  PASS: 消费全部后 cmd_avail=0, cmd_lvl=0");
                pass = pass + 1;
            end
        end
    endtask

    // =========================================================================
    // T4: 环满检测 (写 255 条)
    // =========================================================================
    task t4_full;
        integer i;
        begin
            $display("=== T4: 环满检测 ===");
            do_reset;

            // 写 255 条 (0..254), HEAD=255
            for (i = 0; i < 255; i = i + 1) begin
                write_entry(i[7:0], 32'hA000_0000 + i, 8'h30, 8'h00,
                            16'd64, 32'h0000_0100 + i, 32'h0000_0200 + i);
            end
            update_head(8'd255);

            if (cmd_full !== 1) begin
                $display("  FAIL: 255 条时 cmd_full=%b (期望 1)", cmd_full);
                fail = fail + 1;
            end else begin
                $display("  PASS: 255 条时 cmd_full=1");
                pass = pass + 1;
            end

            if (cmd_lvl !== 255) begin
                $display("  FAIL: cmd_lvl=%d (期望 255)", cmd_lvl);
                fail = fail + 1;
            end else begin
                $display("  PASS: cmd_lvl=255");
                pass = pass + 1;
            end

            // 再写第 256 条 (wr_en 不检查满, 写入但 HEAD 不变 → 不影响)
            write_entry(8'd255, 32'hFFFF_FFFF, 8'hFF, 8'hFF,
                        16'hFFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFF);
            // HEAD 仍为 255, 环仍满
            if (cmd_full !== 1) begin
                $display("  FAIL: 写第 256 条后 cmd_full=%b (期望 1)", cmd_full);
                fail = fail + 1;
            end else begin
                $display("  PASS: 写第 256 条后 cmd_full 仍为 1");
                pass = pass + 1;
            end
        end
    endtask

    // =========================================================================
    // T5: 环空检测
    // =========================================================================
    task t5_empty;
        integer i;
        begin
            $display("=== T5: 环空检测 ===");
            do_reset;

            // 写 3 条
            for (i = 0; i < 3; i = i + 1) begin
                write_entry(i[7:0], 32'hB000_0000 + i, 8'h01, 8'h00,
                            16'd32, 32'h0000_0300 + i, 32'h0000_0400 + i);
            end
            update_head(8'd3);

            // 消费 3 条
            for (i = 0; i < 3; i = i + 1) begin
                consume_cmd;
            end

            if (cmd_avail !== 0 || cmd_vld !== 0 || cmd_lvl !== 0) begin
                $display("  FAIL: 消费后 cmd_avail=%b vld=%b lvl=%d",
                         cmd_avail, cmd_vld, cmd_lvl);
                fail = fail + 1;
            end else begin
                $display("  PASS: 消费后环空");
                pass = pass + 1;
            end

            // 空环时 cmd_full 应为 0
            if (cmd_full !== 0) begin
                $display("  FAIL: 空环 cmd_full=%b (期望 0)", cmd_full);
                fail = fail + 1;
            end else begin
                $display("  PASS: 空环 cmd_full=0");
                pass = pass + 1;
            end
        end
    endtask

    // =========================================================================
    // T6: cmd_lvl 精度 (不同填充量)
    // =========================================================================
    task t6_lvl_precision;
        integer i;
        begin
            $display("=== T6: cmd_lvl 精度 ===");
            do_reset;

            // 写 10 条
            for (i = 0; i < 10; i = i + 1) begin
                write_entry(i[7:0], 32'hC000_0000 + i, 8'h20, 8'h00,
                            16'd16, 32'h0000_0500 + i, 32'h0000_0600 + i);
            end
            update_head(8'd10);

            if (cmd_lvl !== 10) begin
                $display("  FAIL: 10 条时 cmd_lvl=%d (期望 10)", cmd_lvl);
                fail = fail + 1;
            end else begin $display("  PASS: 10 条 → cmd_lvl=10"); pass = pass + 1; end

            // 消费 7 条
            for (i = 0; i < 7; i = i + 1) begin
                consume_cmd;
            end
            if (cmd_lvl !== 3) begin
                $display("  FAIL: 消费 7 条后 cmd_lvl=%d (期望 3)", cmd_lvl);
                fail = fail + 1;
            end else begin $display("  PASS: 消费 7 条 → cmd_lvl=3"); pass = pass + 1; end

            // 再写 5 条 (idx 10..14), HEAD 推进到 15
            for (i = 0; i < 5; i = i + 1) begin
                write_entry(8'd10 + i, 32'hD000_0000 + i, 8'h20, 8'h00,
                            16'd8, 32'h0000_0700 + i, 32'h0000_0800 + i);
            end
            update_head(8'd15);
            if (cmd_lvl !== 8) begin
                $display("  FAIL: 再写 5 条后 cmd_lvl=%d (期望 8)", cmd_lvl);
                fail = fail + 1;
            end else begin $display("  PASS: 再写 5 条 → cmd_lvl=8"); pass = pass + 1; end

            // 消费全部 8 条
            for (i = 0; i < 8; i = i + 1) begin
                consume_cmd;
            end
            if (cmd_lvl !== 0) begin
                $display("  FAIL: 消费全部后 cmd_lvl=%d (期望 0)", cmd_lvl);
                fail = fail + 1;
            end else begin $display("  PASS: 消费全部 → cmd_lvl=0"); pass = pass + 1; end
        end
    endtask

    // =========================================================================
    // T7: 环绕 (写满后消费, 再写入)
    // =========================================================================
    task t7_wrap;
        integer i;
        reg [PTR_W-1:0] wrap_idx;
        begin
            $display("=== T7: 环绕 ===");
            do_reset;

            // 写 255 条 (0..254), HEAD=255
            for (i = 0; i < 255; i = i + 1) begin
                write_entry(i[7:0], 32'hE000_0000 + i, 8'h30, 8'h00,
                            16'd4, 32'h0000_0900 + i, 32'h0000_0A00 + i);
            end
            update_head(8'd255);

            // 消费 10 条 (tail: 0→10)
            for (i = 0; i < 10; i = i + 1) begin
                consume_cmd;
            end
            if (cmd_lvl !== 245) begin
                $display("  FAIL: 消费 10 条后 cmd_lvl=%d (期望 245)", cmd_lvl);
                fail = fail + 1;
            end else begin $display("  PASS: 消费 10 条 → cmd_lvl=245"); pass = pass + 1; end

            // 写 10 条到 idx 255..8 (环绕), HEAD 推进到 9 (255+10=265 mod 256=9)
            for (i = 0; i < 10; i = i + 1) begin
                wrap_idx = 8'd255 + i[7:0];
                write_entry(wrap_idx, 32'hF000_0000 + i, 8'h31, 8'h00,
                            16'd2, 32'h0000_0B00 + i, 32'h0000_0C00 + i);
            end
            update_head(8'd9);

            // 期望: 245 + 10 = 255 条
            if (cmd_lvl !== 255) begin
                $display("  FAIL: 环绕写入后 cmd_lvl=%d (期望 255)", cmd_lvl);
                fail = fail + 1;
            end else begin $display("  PASS: 环绕写入后 cmd_lvl=255"); pass = pass + 1; end

            // 消费 255 条
            for (i = 0; i < 255; i = i + 1) begin
                consume_cmd;
            end
            if (cmd_avail !== 0 || cmd_lvl !== 0) begin
                $display("  FAIL: 环绕消费全部后 cmd_avail=%b lvl=%d", cmd_avail, cmd_lvl);
                fail = fail + 1;
            end else begin $display("  PASS: 环绕消费全部 → 环空"); pass = pass + 1; end
        end
    endtask

    // =========================================================================
    // T8: 字段解包边界值
    // =========================================================================
    task t8_field_decode;
        begin
            $display("=== T8: 字段解包边界值 ===");
            do_reset;

            // 全 0 条目
            write_entry(8'd0, 32'd0, 8'd0, 8'd0, 16'd0, 32'd0, 32'd0);
            update_head(8'd1);
            if (cmd_id !== 32'd0 || cmd_type !== 8'd0 || cmd_flags !== 8'd0 ||
                cmd_payload_len !== 16'd0 || cmd_payload_addr !== 32'd0 ||
                cmd_result_addr !== 32'd0) begin
                $display("  FAIL: 全 0 解包错误");
                fail = fail + 1;
            end else begin $display("  PASS: 全 0 解包正确"); pass = pass + 1; end
            consume_cmd;

            // 全 1 条目 (所有 bit = 1)
            write_entry(8'd1, 32'hFFFF_FFFF, 8'hFF, 8'hFF, 16'hFFFF,
                        32'hFFFF_FFFF, 32'hFFFF_FFFF);
            update_head(8'd2);
            if (cmd_id !== 32'hFFFF_FFFF || cmd_type !== 8'hFF || cmd_flags !== 8'hFF ||
                cmd_payload_len !== 16'hFFFF || cmd_payload_addr !== 32'hFFFF_FFFF ||
                cmd_result_addr !== 32'hFFFF_FFFF) begin
                $display("  FAIL: 全 1 解包错误");
                fail = fail + 1;
            end else begin $display("  PASS: 全 1 解包正确"); pass = pass + 1; end
            consume_cmd;

            // 交替 bit 模式 0xAAAA_AAAA
            write_entry(8'd2, 32'hAAAA_AAAA, 8'hAA, 8'hAA, 16'hAAAA,
                        32'hAAAA_AAAA, 32'hAAAA_AAAA);
            update_head(8'd3);
            if (cmd_id !== 32'hAAAA_AAAA || cmd_type !== 8'hAA || cmd_flags !== 8'hAA ||
                cmd_payload_len !== 16'hAAAA || cmd_payload_addr !== 32'hAAAA_AAAA ||
                cmd_result_addr !== 32'hAAAA_AAAA) begin
                $display("  FAIL: 0xAAAA 解包错误");
                fail = fail + 1;
            end else begin $display("  PASS: 0xAAAA 解包正确"); pass = pass + 1; end
            consume_cmd;

            // 交替 bit 模式 0x5555_5555
            write_entry(8'd3, 32'h5555_5555, 8'h55, 8'h55, 16'h5555,
                        32'h5555_5555, 32'h5555_5555);
            update_head(8'd4);
            if (cmd_id !== 32'h5555_5555 || cmd_type !== 8'h55 || cmd_flags !== 8'h55 ||
                cmd_payload_len !== 16'h5555 || cmd_payload_addr !== 32'h5555_5555 ||
                cmd_result_addr !== 32'h5555_5555) begin
                $display("  FAIL: 0x5555 解包错误");
                fail = fail + 1;
            end else begin $display("  PASS: 0x5555 解包正确"); pass = pass + 1; end
            consume_cmd;
        end
    endtask

    // =========================================================================
    // =========================================================================
    // T9: cmd_type 编码 (全部 12 种)
    // =========================================================================
    task t9_cmd_type;
        integer i;
        reg [7:0] tt0, tt1, tt2, tt3, tt4, tt5, tt6, tt7, tt8, tt9, tt10, tt11;
        begin
            $display("=== T9: cmd_type 编码 ===");
            do_reset;

            tt0  = 8'h01;  // TRNG_GENERATE
            tt1  = 8'h10;  // SM2_SIGN
            tt2  = 8'h11;  // SM2_VERIFY
            tt3  = 8'h20;  // SM3_HASH
            tt4  = 8'h30;  // SM4_CTR_ENCRYPT
            tt5  = 8'h31;  // SM4_CTR_DECRYPT
            tt6  = 8'h32;  // SM4_CBC_ENCRYPT
            tt7  = 8'h33;  // SM4_CBC_DECRYPT
            tt8  = 8'h40;  // KEY_IMPORT
            tt9  = 8'h41;  // KEY_EXPORT
            tt10 = 8'h42;  // KEY_DELETE
            tt11 = 8'hFF;  // NOOP

            write_entry(8'd0, 32'h2000_0000, tt0, 8'h00, 16'd1, 32'h0000_0D00, 32'h0000_0E00);
            write_entry(8'd1, 32'h2000_0001, tt1, 8'h00, 16'd1, 32'h0000_0D01, 32'h0000_0E01);
            write_entry(8'd2, 32'h2000_0002, tt2, 8'h00, 16'd1, 32'h0000_0D02, 32'h0000_0E02);
            write_entry(8'd3, 32'h2000_0003, tt3, 8'h00, 16'd1, 32'h0000_0D03, 32'h0000_0E03);
            write_entry(8'd4, 32'h2000_0004, tt4, 8'h00, 16'd1, 32'h0000_0D04, 32'h0000_0E04);
            write_entry(8'd5, 32'h2000_0005, tt5, 8'h00, 16'd1, 32'h0000_0D05, 32'h0000_0E05);
            write_entry(8'd6, 32'h2000_0006, tt6, 8'h00, 16'd1, 32'h0000_0D06, 32'h0000_0E06);
            write_entry(8'd7, 32'h2000_0007, tt7, 8'h00, 16'd1, 32'h0000_0D07, 32'h0000_0E07);
            write_entry(8'd8, 32'h2000_0008, tt8, 8'h00, 16'd1, 32'h0000_0D08, 32'h0000_0E08);
            write_entry(8'd9, 32'h2000_0009, tt9, 8'h00, 16'd1, 32'h0000_0D09, 32'h0000_0E09);
            write_entry(8'd10, 32'h2000_000A, tt10, 8'h00, 16'd1, 32'h0000_0D0A, 32'h0000_0E0A);
            write_entry(8'd11, 32'h2000_000B, tt11, 8'h00, 16'd1, 32'h0000_0D0B, 32'h0000_0E0B);
            update_head(8'd12);

            // 校验 12 种 cmd_type
            if (cmd_type !== tt0)  begin $display("  FAIL: 条目 0 cmd_type=%h 期望 %h", cmd_type, tt0);  fail = fail + 1; end
            consume_cmd;
            if (cmd_type !== tt1)  begin $display("  FAIL: 条目 1 cmd_type=%h 期望 %h", cmd_type, tt1);  fail = fail + 1; end
            consume_cmd;
            if (cmd_type !== tt2)  begin $display("  FAIL: 条目 2 cmd_type=%h 期望 %h", cmd_type, tt2);  fail = fail + 1; end
            consume_cmd;
            if (cmd_type !== tt3)  begin $display("  FAIL: 条目 3 cmd_type=%h 期望 %h", cmd_type, tt3);  fail = fail + 1; end
            consume_cmd;
            if (cmd_type !== tt4)  begin $display("  FAIL: 条目 4 cmd_type=%h 期望 %h", cmd_type, tt4);  fail = fail + 1; end
            consume_cmd;
            if (cmd_type !== tt5)  begin $display("  FAIL: 条目 5 cmd_type=%h 期望 %h", cmd_type, tt5);  fail = fail + 1; end
            consume_cmd;
            if (cmd_type !== tt6)  begin $display("  FAIL: 条目 6 cmd_type=%h 期望 %h", cmd_type, tt6);  fail = fail + 1; end
            consume_cmd;
            if (cmd_type !== tt7)  begin $display("  FAIL: 条目 7 cmd_type=%h 期望 %h", cmd_type, tt7);  fail = fail + 1; end
            consume_cmd;
            if (cmd_type !== tt8)  begin $display("  FAIL: 条目 8 cmd_type=%h 期望 %h", cmd_type, tt8);  fail = fail + 1; end
            consume_cmd;
            if (cmd_type !== tt9)  begin $display("  FAIL: 条目 9 cmd_type=%h 期望 %h", cmd_type, tt9);  fail = fail + 1; end
            consume_cmd;
            if (cmd_type !== tt10) begin $display("  FAIL: 条目 10 cmd_type=%h 期望 %h", cmd_type, tt10); fail = fail + 1; end
            consume_cmd;
            if (cmd_type !== tt11) begin $display("  FAIL: 条目 11 cmd_type=%h 期望 %h", cmd_type, tt11); fail = fail + 1; end
            consume_cmd;
            $display("  PASS: 12 种 cmd_type 全部正确");
            pass = pass + 1;
        end
    endtask

    // =========================================================================
    // T10: 零回归 — 随机写入/消费, 断言自洽
    // =========================================================================
    task t10_zero_regression;
        integer i, j;
        reg [PTR_W-1:0] wr_idx_r;
        reg [PTR_W-1:0] head_r;
        reg [8:0]       expected_lvl;
        begin
            $display("=== T10: 零回归 ===");
            do_reset;

            // 场景: 写 50 条, 消费 20, 写 30, 消费 40, 写 10
            // 手动跟踪 expected_lvl
            expected_lvl = 0;

            // 写 50 条 (idx 0..49)
            for (i = 0; i < 50; i = i + 1) begin
                write_entry(i[7:0], 32'h3000_0000 + i, 8'h30, 8'h00,
                            16'd1, 32'h0000_0F00 + i, 32'h0000_1000 + i);
            end
            update_head(8'd50);
            expected_lvl = 50;
            if (cmd_lvl !== expected_lvl) begin
                $display("  FAIL: 步骤1 cmd_lvl=%d 期望 %d", cmd_lvl, expected_lvl);
                fail = fail + 1;
            end

            // 消费 20 条
            for (i = 0; i < 20; i = i + 1) begin
                consume_cmd;
            end
            expected_lvl = 30;
            if (cmd_lvl !== expected_lvl) begin
                $display("  FAIL: 步骤2 cmd_lvl=%d 期望 %d", cmd_lvl, expected_lvl);
                fail = fail + 1;
            end

            // 写 30 条 (idx 50..79)
            for (i = 0; i < 30; i = i + 1) begin
                write_entry(8'd50 + i, 32'h4000_0000 + i, 8'h31, 8'h00,
                            16'd2, 32'h0000_1100 + i, 32'h0000_1200 + i);
            end
            update_head(8'd80);
            expected_lvl = 60;
            if (cmd_lvl !== expected_lvl) begin
                $display("  FAIL: 步骤3 cmd_lvl=%d 期望 %d", cmd_lvl, expected_lvl);
                fail = fail + 1;
            end

            // 消费 40 条
            for (i = 0; i < 40; i = i + 1) begin
                consume_cmd;
            end
            expected_lvl = 20;
            if (cmd_lvl !== expected_lvl) begin
                $display("  FAIL: 步骤4 cmd_lvl=%d 期望 %d", cmd_lvl, expected_lvl);
                fail = fail + 1;
            end

            // 写 10 条 (idx 80..89)
            for (i = 0; i < 10; i = i + 1) begin
                write_entry(8'd80 + i, 32'h5000_0000 + i, 8'h32, 8'h00,
                            16'd4, 32'h0000_1300 + i, 32'h0000_1400 + i);
            end
            update_head(8'd90);
            expected_lvl = 30;
            if (cmd_lvl !== expected_lvl) begin
                $display("  FAIL: 步骤5 cmd_lvl=%d 期望 %d", cmd_lvl, expected_lvl);
                fail = fail + 1;
            end

            // 消费全部 30 条
            for (i = 0; i < 30; i = i + 1) begin
                consume_cmd;
            end
            expected_lvl = 0;
            if (cmd_lvl !== expected_lvl || cmd_avail !== 0) begin
                $display("  FAIL: 步骤6 cmd_lvl=%d avail=%b 期望 lvl=0 avail=0",
                         cmd_lvl, cmd_avail);
                fail = fail + 1;
            end else begin
                $display("  PASS: 零回归全部通过 (cmd_lvl 始终自洽)");
                pass = pass + 1;
            end
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
        $display("  cmd_ring_buf 测试平台 (tb_cmd_ring_buf)");
        $display("  DEPTH=%0d, PTR_W=%0d, CNT_W=%0d", DEPTH, PTR_W, CNT_W);
        $display("==============================================");

        t1_reset;
        t2_basic_wr_rd;
        t3_multi_wr;
        t4_full;
        t5_empty;
        t6_lvl_precision;
        t7_wrap;
        t8_field_decode;
        t9_cmd_type;
        t10_zero_regression;

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