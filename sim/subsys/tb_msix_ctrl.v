// =============================================================================
// 测试模块 : tb_msix_ctrl
// 模块编号 : M05 (MSI-X 中断控制器)
// 版本     : v1.2 (16 向量)
// 日期     : 2026-10-09
// 仿真工具 : iverilog -g2005
//
// 测试覆盖:
//   T1  复位: 全部向量屏蔽, pending=0
//   T2  向量表编程: 写入地址/数据/屏蔽
//   T3  中断触发 (未屏蔽): irq_vld 脉冲, 输出正确
//   T4  中断触发 (屏蔽): pending 置位, 不发 irq_vld
//   T5  多向量触发: 不同向量号输出不同
//   T6  向量 15 边界值
//   T7  pending 总线正确
//   T8  masked 总线正确
//   T9  any_pending 标志
//   T10 零回归: 触发→清除→再触发
// =============================================================================

`timescale 1ns / 1ps

module tb_msix_ctrl;

    reg         clk;
    reg         rst_n;

    // 向量表编程
    reg         tbl_wr_en;
    reg  [3:0]  tbl_wr_vec;
    reg  [31:0] tbl_wr_addr;
    reg  [31:0] tbl_wr_data;
    reg         tbl_wr_mask;

    // 中断触发
    reg         irq_trigger;
    reg  [3:0]  irq_vec;

    // 输出
    wire        irq_vld;
    wire [31:0] irq_addr;
    wire [31:0] irq_data;
    wire [3:0]  irq_vec_out;
    wire [15:0] pending;
    wire [15:0] masked;
    wire        any_pending;

    integer     pass, fail;

    // =========================================================================
    // DUT
    // =========================================================================
    msix_ctrl #(
        .NVECT(16)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .tbl_wr_en(tbl_wr_en),
        .tbl_wr_vec(tbl_wr_vec),
        .tbl_wr_addr(tbl_wr_addr),
        .tbl_wr_data(tbl_wr_data),
        .tbl_wr_mask(tbl_wr_mask),
        .irq_trigger(irq_trigger),
        .irq_vec(irq_vec),
        .irq_vld(irq_vld),
        .irq_addr(irq_addr),
        .irq_data(irq_data),
        .irq_vec_out(irq_vec_out),
        .pending(pending),
        .masked(masked),
        .any_pending(any_pending)
    );

    // =========================================================================
    // 时钟
    // =========================================================================
    always #5 clk = ~clk;

    // =========================================================================
    // 辅助任务
    // =========================================================================
    task do_reset;
        begin
            rst_n       = 0;
            tbl_wr_en   = 0;
            tbl_wr_vec  = 0;
            tbl_wr_addr = 0;
            tbl_wr_data = 0;
            tbl_wr_mask = 0;
            irq_trigger = 0;
            irq_vec     = 0;
            @(negedge clk);
            @(negedge clk);
            rst_n = 1;
            @(negedge clk);
        end
    endtask

    task wr_vec;
        input [3:0]  vec;
        input [31:0] addr;
        input [31:0] data;
        input        mask;
        begin
            tbl_wr_en   = 1;
            tbl_wr_vec  = vec;
            tbl_wr_addr = addr;
            tbl_wr_data = data;
            tbl_wr_mask = mask;
            @(negedge clk);
            tbl_wr_en   = 0;
        end
    endtask

    task trig_irq;
        input [3:0] vec;
        begin
            irq_trigger = 1;
            irq_vec     = vec;
            @(negedge clk);
            irq_trigger = 0;
        end
    endtask

    // =========================================================================
    // 测试主体
    // =========================================================================
    initial begin
        pass = 0;
        fail = 0;
        clk  = 0;

        // =====================================================================
        // T1: 复位
        // =====================================================================
        $display("=== T1: 复位 ===");
        do_reset;
        if (masked === 16'hFFFF && pending === 16'h0000 && any_pending === 1'b0) begin
            $display("  PASS: 全部向量屏蔽, pending=0");
            pass = pass + 1;
        end else begin
            $display("  FAIL: masked=%h pending=%h any_pending=%b", masked, pending, any_pending);
            fail = fail + 1;
        end

        // =====================================================================
        // T2: 向量表编程 (写入向量 0 的地址/数据/取消屏蔽)
        // =====================================================================
        $display("=== T2: 向量表编程 ===");
        wr_vec(4'd0, 32'hFFFF0000, 32'hDEADBEEF, 1'b0);
        if (masked[0] === 1'b0) begin
            $display("  PASS: 向量 0 屏蔽已清除");
            pass = pass + 1;
        end else begin
            $display("  FAIL: 向量 0 屏蔽未清除");
            fail = fail + 1;
        end

        // 编程向量 5
        wr_vec(4'd5, 32'hAAAABBBB, 32'hCAFEBABE, 1'b0);

        // 编程向量 15
        wr_vec(4'd15, 32'h12345678, 32'h87654321, 1'b0);

        // =====================================================================
        // T3: 中断触发 (未屏蔽向量 0)
        // =====================================================================
        $display("=== T3: 中断触发 (未屏蔽) ===");
        trig_irq(4'd0);
        if (irq_vld === 1'b1 && irq_addr === 32'hFFFF0000 && irq_data === 32'hDEADBEEF && irq_vec_out === 4'd0) begin
            $display("  PASS: 向量 0 中断消息正确");
            pass = pass + 1;
        end else begin
            $display("  FAIL: vld=%b addr=%h data=%h vec=%d", irq_vld, irq_addr, irq_data, irq_vec_out);
            fail = fail + 1;
        end
        // 下一拍 irq_vld 应为 0
        @(negedge clk);
        if (irq_vld === 1'b0) begin
            $display("  PASS: irq_vld 单拍脉冲");
            pass = pass + 1;
        end else begin
            $display("  FAIL: irq_vld 未清零");
            fail = fail + 1;
        end

        // =====================================================================
        // T4: 中断触发 (屏蔽向量)
        // =====================================================================
        $display("=== T4: 中断触发 (屏蔽) ===");
        // 先屏蔽向量 0
        wr_vec(4'd0, 32'hFFFF0000, 32'hDEADBEEF, 1'b1);
        trig_irq(4'd0);
        if (irq_vld === 1'b0 && pending[0] === 1'b1) begin
            $display("  PASS: 屏蔽向量挂起, 不发中断");
            pass = pass + 1;
        end else begin
            $display("  FAIL: vld=%b pending[0]=%b", irq_vld, pending[0]);
            fail = fail + 1;
        end

        // =====================================================================
        // T5: 多向量触发 (向量 5)
        // =====================================================================
        $display("=== T5: 多向量触发 ===");
        trig_irq(4'd5);
        if (irq_vld === 1'b1 && irq_addr === 32'hAAAABBBB && irq_data === 32'hCAFEBABE && irq_vec_out === 4'd5) begin
            $display("  PASS: 向量 5 中断消息正确");
            pass = pass + 1;
        end else begin
            $display("  FAIL: vld=%b addr=%h data=%h vec=%d", irq_vld, irq_addr, irq_data, irq_vec_out);
            fail = fail + 1;
        end

        // =====================================================================
        // T6: 向量 15 边界值
        // =====================================================================
        $display("=== T6: 向量 15 边界值 ===");
        trig_irq(4'd15);
        if (irq_vld === 1'b1 && irq_addr === 32'h12345678 && irq_data === 32'h87654321 && irq_vec_out === 4'd15) begin
            $display("  PASS: 向量 15 中断消息正确");
            pass = pass + 1;
        end else begin
            $display("  FAIL: vld=%b addr=%h data=%h vec=%d", irq_vld, irq_addr, irq_data, irq_vec_out);
            fail = fail + 1;
        end

        // =====================================================================
        // T7: pending 总线
        // =====================================================================
        $display("=== T7: pending 总线 ===");
        // 当前 pending[0]=1 (T4 挂起), 其余应为 0
        if (pending[0] === 1'b1 && pending[15:1] === 15'h0000) begin
            $display("  PASS: pending[0]=1, 其余=0");
            pass = pass + 1;
        end else begin
            $display("  FAIL: pending=%h", pending);
            fail = fail + 1;
        end
        if (any_pending === 1'b1) begin
            $display("  PASS: any_pending=1");
            pass = pass + 1;
        end else begin
            $display("  FAIL: any_pending=0 (应为 1)");
            fail = fail + 1;
        end

        // =====================================================================
        // T8: masked 总线
        // =====================================================================
        $display("=== T8: masked 总线 ===");
        // 向量 0 屏蔽, 向量 5/15 未屏蔽, 其余默认屏蔽
        if (masked[0] === 1'b1 && masked[5] === 1'b0 && masked[15] === 1'b0) begin
            $display("  PASS: masked[0]=1, masked[5]=0, masked[15]=0");
            pass = pass + 1;
        end else begin
            $display("  FAIL: masked=%h", masked);
            fail = fail + 1;
        end

        // =====================================================================
        // T9: any_pending 清除
        // =====================================================================
        $display("=== T9: any_pending 清除 ===");
        // 取消屏蔽向量 0 并触发 (清除 pending)
        wr_vec(4'd0, 32'hFFFF0000, 32'hDEADBEEF, 1'b0);
        trig_irq(4'd0);
        @(negedge clk);
        if (pending[0] === 1'b0) begin
            $display("  PASS: pending[0] 已清除");
            pass = pass + 1;
        end else begin
            $display("  FAIL: pending[0] 未清除");
            fail = fail + 1;
        end

        // =====================================================================
        // T10: 零回归 (再触发向量 15)
        // =====================================================================
        $display("=== T10: 零回归 ===");
        trig_irq(4'd15);
        if (irq_vld === 1'b1 && irq_vec_out === 4'd15) begin
            $display("  PASS: 再触发向量 15 正确");
            pass = pass + 1;
        end else begin
            $display("  FAIL: vld=%b vec=%d", irq_vld, irq_vec_out);
            fail = fail + 1;
        end

        // =====================================================================
        // 汇总
        // =====================================================================
        $display("==============================================");
        $display("结果: %0d PASS, %0d FAIL", pass, fail);
        if (fail == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** %0d TEST(S) FAILED ***", fail);
        $finish;
    end

endmodule