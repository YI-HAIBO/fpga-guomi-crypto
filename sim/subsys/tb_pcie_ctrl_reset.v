// =============================================================================
// 模块名称 : tb_pcie_ctrl_reset
// 模块编号 : Phase 3.0 - CTRL_RESET 顶层回接验证
// 项目     : GM-CRYPTO-COORD-2026
// 视角     : sim-verifier (陈验证)
// 编译     : iverilog -g2005
// 场景     : S1 写 0x108 触发顶层软复位并清错状态
// =============================================================================

`timescale 1ns / 1ps

module tb_pcie_ctrl_reset;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg         mmio_wr_en = 0;
    reg  [11:0] mmio_addr  = 0;
    reg  [31:0] mmio_wr_data = 0;
    wire [31:0] mmio_rd_data;
    wire        mmio_rd_vld;

    wire        dma_wr_vld;
    reg         dma_wr_rdy = 1;
    wire [63:0] dma_wr_desc;
    wire [511:0] dma_wr_data;
    wire [7:0]  dma_wr_rid;
    wire [7:0]  dma_wr_err;
    wire        dma_wr_ok;

    wire        msix_irq_vld;
    wire [31:0] msix_irq_addr;
    wire [31:0] msix_irq_data;
    wire [2:0]  msix_irq_vec;
    wire [7:0]  msix_pending;
    wire [7:0]  msix_masked;
    wire        msix_any_pending;

    wire [4:0]  cmd_queue_lvl;
    wire [4:0]  done_queue_lvl;

    pcie_front_subsys u_dut (
        .clk(clk), .rst_n(rst_n),
        .mmio_addr(mmio_addr), .mmio_wr_data(mmio_wr_data), .mmio_wr_en(mmio_wr_en),
        .mmio_rd_data(mmio_rd_data), .mmio_rd_vld(mmio_rd_vld),
        .dma_wr_vld(dma_wr_vld), .dma_wr_rdy(dma_wr_rdy),
        .dma_wr_desc(dma_wr_desc), .dma_wr_data(dma_wr_data),
        .dma_wr_rid(dma_wr_rid), .dma_wr_err(dma_wr_err), .dma_wr_ok(dma_wr_ok),
        .msix_irq_vld(msix_irq_vld), .msix_irq_addr(msix_irq_addr),
        .msix_irq_data(msix_irq_data), .msix_irq_vec(msix_irq_vec),
        .msix_pending(msix_pending), .msix_masked(msix_masked),
        .msix_any_pending(msix_any_pending),
        .cmd_queue_lvl(cmd_queue_lvl), .done_queue_lvl(done_queue_lvl)
    );

    integer ntest  = 0;
    integer npass  = 0;
    integer npfail = 0;
    integer i_w    = 0;
    integer err_seen = 0;
    reg [31:0] rd_val = 0;

    reg [31:0] cap_rid;
    reg [7:0]  cap_err;
    reg        cap_ok;
    reg [511:0] cap_data;

    task mmio_write;
        input [11:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            mmio_addr    = addr;
            mmio_wr_data = data;
            mmio_wr_en   = 1'b1;
            @(posedge clk);
            #1;
            mmio_wr_en   = 1'b0;
        end
    endtask

    task mmio_read;
        input  [11:0] addr;
        output [31:0] val;
        begin
            @(negedge clk);
            mmio_addr  = addr;
            mmio_wr_en = 1'b0;
            @(posedge clk);
            #1;
            val = mmio_rd_data;
        end
    endtask

    task submit_cmd;
        input [7:0]   rid;
        input [3:0]   op;
        input [1:0]   prio;
        input [255:0] ia;
        input [255:0] ib;
        input [255:0] ic;
        reg [31:0] head;
        reg [255:0] tmp_data;
        reg [3:0]  tmp_idx;
        reg [11:0] addr;
        begin
            head = {24'd0, prio, 8'd0, rid, op};
            mmio_write(12'h000, head);
            tmp_data = ia;
            for (tmp_idx = 4'd0; tmp_idx < 4'd8; tmp_idx = tmp_idx + 4'd1) begin
                addr = 12'h004 + (tmp_idx << 2);
                mmio_write(addr, tmp_data[31:0]);
                tmp_data = tmp_data >> 32;
            end
            tmp_data = ib;
            for (tmp_idx = 4'd0; tmp_idx < 4'd8; tmp_idx = tmp_idx + 4'd1) begin
                addr = 12'h024 + (tmp_idx << 2);
                mmio_write(addr, tmp_data[31:0]);
                tmp_data = tmp_data >> 32;
            end
            tmp_data = ic;
            for (tmp_idx = 4'd0; tmp_idx < 4'd8; tmp_idx = tmp_idx + 4'd1) begin
                addr = 12'h044 + (tmp_idx << 2);
                mmio_write(addr, tmp_data[31:0]);
                tmp_data = tmp_data >> 32;
            end
            mmio_write(12'h100, 32'd0);
        end
    endtask

    task wait_dma;
        integer t;
        begin
            t = 0;
            forever begin
                @(posedge clk);
                #1;
                t = t + 1;
                if (dma_wr_vld) begin
                    cap_rid  = dma_wr_rid;
                    cap_err  = dma_wr_err;
                    cap_ok   = dma_wr_ok;
                    cap_data = dma_wr_data;
                    disable wait_dma;
                end
                if (t > 100000) begin
                    $display("  [TIMEOUT] wait_dma t=%0d", t);
                    npfail = npfail + 1;
                    ntest  = ntest + 1;
                    disable wait_dma;
                end
            end
        end
    endtask

    task check_eq;
        input         cond;
        input [511:0] name;
        begin
            ntest = ntest + 1;
            if (cond) begin
                npass = npass + 1;
                $display("  [PASS] %0s", name);
            end else begin
                npfail = npfail + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    initial begin
        $display("==========================================================");
        $display("  CTRL_RESET top-level verification");
        $display("==========================================================");
        $display("");

        rst_n = 0;
        mmio_wr_en = 0;
        mmio_addr = 0;
        mmio_wr_data = 0;
        repeat (5) @(posedge clk); #1;
        rst_n = 1;
        repeat (2) @(posedge clk); #1;

        mmio_write(12'h300, 32'hDEAD);
        mmio_write(12'h304, 32'hBEEF);
        mmio_write(12'h308, 32'd0);
        repeat (3) @(posedge clk); #1;

        submit_cmd(8'h11, 4'h0, 2'd0,
                   256'h0123456789ABCDEFFEDCBA9876543210,
                   256'h0123456789ABCDEFFEDCBA9876543210,
                   256'd0);
        wait_dma;
        check_eq(cap_ok == 1'b1 && cap_rid == 8'h11, "S1 base cmd ok");

        submit_cmd(8'h22, 4'hF, 2'd0, 256'd0, 256'd0, 256'd0);
        wait_dma;
        mmio_read(12'h004, rd_val);
        check_eq(rd_val[2] == 1'b1, "S1 status.err set");

        mmio_read(12'h200, rd_val);
        check_eq(rd_val[31:16] == 16'h2202, "S1 err_log set");

        mmio_write(12'h108, 32'h0000_0000);
        @(posedge clk);
        #1;
        check_eq(u_dut.soft_rst_n == 1'b0, "S1 soft_rst_n low on 0x108");
        @(posedge clk);
        #1;
        check_eq(u_dut.soft_rst_n == 1'b1, "S1 soft_rst_n recovers");
        repeat (2) @(posedge clk); #1;

        mmio_read(12'h004, rd_val);
        check_eq(rd_val[2] == 1'b0, "S1 status.err cleared");
        mmio_read(12'h200, rd_val);
        check_eq(rd_val == 32'd0, "S1 err_log cleared");
        check_eq(cmd_queue_lvl == 5'd0, "S1 cmd_queue cleared");
        check_eq(done_queue_lvl == 5'd0, "S1 done_queue cleared");

        submit_cmd(8'h33, 4'h0, 2'd0,
                   256'h0123456789ABCDEFFEDCBA9876543210,
                   256'h0123456789ABCDEFFEDCBA9876543210,
                   256'd0);
        wait_dma;
        check_eq(cap_ok == 1'b1 && cap_rid == 8'h33 && cap_data[383:256] == 128'h681EDF34D206965E86B3E94F536E4246,
                 "S1 post-reset cmd ok");

        $display("");
        $display("==========================================================");
        $display("  ntest=%0d  npass=%0d  npfail=%0d", ntest, npass, npfail);
        if (npfail == 0)
            $display("  RESULT: PASS");
        else
            $display("  RESULT: FAIL");
        $display("==========================================================");
        $finish;
    end

endmodule
