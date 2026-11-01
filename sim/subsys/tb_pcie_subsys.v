// =============================================================================
// 模块名称 : tb_pcie_subsys
// 模块编号 : Phase 2.8c - SS1 顶层端到端验证
// 项目     : GM-CRYPTO-COORD-2026
// 视角     : sim-verifier (陈验证)
// 编译     : iverilog -g2005
// 场景     : S1-S6
// =============================================================================

`timescale 1ns / 1ps

module tb_pcie_subsys;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;   // 100 MHz

    // =========================================================================
    // 顶层端口
    // =========================================================================
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
    reg  [31:0] rd_val = 0;

    // DMA 捕获
    reg [511:0] cap_data;
    reg [63:0]  cap_desc;
    reg [7:0]   cap_rid;
    reg [7:0]   cap_err;
    reg         cap_ok;
    // MSI-X 捕获
    // 初始化为 X: 某场景未捕获到中断时, 断言因 X 比较失败而报错,
    // 而不是命中上一场景的残留值 (S2 曾因此假通过 0xDEAD)。
    reg [31:0] cap_irq_addr = 32'hxxxxxxxx;
    reg [31:0] cap_irq_data = 32'hxxxxxxxx;
    reg [2:0]  cap_irq_vec  = 3'bxxx;
    integer    cap_irq_cnt  = 0;

    // =========================================================================
    // 任务
    // =========================================================================
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
                    cap_data = dma_wr_data;
                    cap_desc = dma_wr_desc;
                    cap_rid  = dma_wr_rid;
                    cap_err  = dma_wr_err;
                    cap_ok   = dma_wr_ok;
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

    task wait_msix;
        integer t;
        begin
            t = 0;
            forever begin
                @(posedge clk);
                #1;
                t = t + 1;
                if (msix_irq_vld) begin
                    cap_irq_addr = msix_irq_addr;
                    cap_irq_data = msix_irq_data;
                    cap_irq_vec  = msix_irq_vec;
                    cap_irq_cnt  = cap_irq_cnt + 1;   // 累计捕获次数, 防残留假通过
                    disable wait_msix;
                end
                if (t > 100000) begin
                    $display("  [TIMEOUT] wait_msix t=%0d", t);
                    npfail = npfail + 1;
                    ntest  = ntest + 1;
                    disable wait_msix;
                end
            end
        end
    endtask

    // =========================================================================
    // 主测试
    // =========================================================================
    initial begin
        $display("==========================================================");
        $display("  Phase 2.8c - SS1 PCIe Front-End E2E Testbench");
        $display("==========================================================");
        $display("");

        rst_n = 0; mmio_wr_en = 0; mmio_addr = 0; mmio_wr_data = 0; dma_wr_rdy = 1;
        repeat (5) @(posedge clk); #1;
        rst_n = 1;
        repeat (2) @(posedge clk); #1;

        $display("[Init] MSI-X vec0: addr=0xDEAD data=0xBEEF mask=0(unmask)");
        mmio_write(12'h300, 32'hDEAD);
        mmio_write(12'h304, 32'hBEEF);
        mmio_write(12'h308, 32'd0);
        repeat (3) @(posedge clk); #1;

        // ---------------- S1 ----------------
        $display("");
        $display("-------- S1: Normal SM4_ENCRYPT E2E --------");
        submit_cmd(8'h11, 4'h0, 2'd0,
                   256'h0123456789ABCDEFFEDCBA9876543210,
                   256'h0123456789ABCDEFFEDCBA9876543210,
                   256'd0);
        // 早期满 10 拍观测。dma_wr_vld 是 1 拍脉冲, 等待期间不能插长 repeat,
        // 否则脉冲已过 (SM4 约 68c 出结果), wait_dma 只会超时 (首跑 S1 丢拍根因)。
        repeat (10) @(posedge clk); #1;
        $display("  [MON] 10c: cmd_lvl=%0d cmd_idx_gen=%0d pq_cnt=%0d eng0_busy=%b eng0_done=%b",
                 cmd_queue_lvl, u_dut.u_sched.cmd_idx_gen,
                 u_dut.u_sched.pq_cnt, u_dut.u_sched.eng0_busy, u_dut.u_sched.eng0_done);
        wait_dma;
        $display("  [DEBUG] cap_ok=%b cap_err=0x%0h cap_rid=0x%0h cap_data[383:256]=0x%h",
                 cap_ok, cap_err, cap_rid, cap_data[383:256]);
        $display("  [MON] post-dma: eng0_busy=%b eng0_ok=%b res_vld=%b fifo_cnt=%0d",
                 u_dut.u_sched.eng0_busy, u_dut.u_sched.eng0_ok,
                 u_dut.sched_res_vld, u_dut.u_sched.fifo_cnt);
        check_eq(cap_ok == 1'b1,                                     "S1 dma_ok");
        check_eq(cap_err == 8'd0,                                    "S1 dma_err==0");
        check_eq(cap_rid == 8'h11,                                   "S1 dma_rid==0x11");
        check_eq(cap_data[383:256] == 128'h681EDF34D206965E86B3E94F536E4246,
                 "S1 dma_data==GB_CT");
        check_eq(cap_desc[0] == 1'b1,                                 "S1 desc.dir==1");
        check_eq(cap_desc[1] == 1'b1,                                 "S1 desc.cmd_type==1");
        wait_msix;
        check_eq(cap_irq_cnt == 1,                                     "S1 msix captured (#1)");
        check_eq(cap_irq_addr == 32'hDEAD,                            "S1 msix.addr==0xDEAD");
        check_eq(cap_irq_data == 32'hBEEF,                            "S1 msix.data==0xBEEF");
        check_eq(cap_irq_vec  == 3'd0,                                "S1 msix.vec==0");

        // ---------------- S2 ----------------
        $display("");
        $display("-------- S2: Illegal op -> ERR_ILLEGAL_OP --------");
        submit_cmd(8'h22, 4'hF, 2'd0, 256'd0, 256'd0, 256'd0);
        wait_dma;
        check_eq(cap_ok == 1'b0,                                     "S2 dma_ok==0");
        check_eq(cap_err == 8'h02,                                   "S2 dma_err==0x02");
        check_eq(cap_rid == 8'h22,                                   "S2 dma_rid==0x22");
        check_eq(cap_data == 512'd0,                                 "S2 dma_data==0 (fast-return)");

        // irq_vld 是 1 拍脉冲, 紧跟 dma_wr_vld 的下一拍, 必须立刻等;
        // 中间插 MMIO 事务会吃掉脉冲 (首跑 S2 wait_msix 超时即此因)。
        wait_msix;
        check_eq(cap_irq_cnt == 2,                                     "S2 msix captured (#2)");
        check_eq(cap_irq_addr == 32'hDEAD,                            "S2 msix fires on error");
        check_eq(cap_irq_vec  == 3'd0,                                "S2 msix.vec==0");

        mmio_read(12'h200, rd_val);
        $display("  [DEBUG] rd_val=0x%0h err_log[0]=0x%0h err_idx=%0d",
                 rd_val, u_dut.u_bar_ctrl.err_log[0], u_dut.u_bar_ctrl.err_log_wr_idx);
        check_eq(rd_val[31:24] == 8'h22,                             "S2 ERR_LOG[0].rid==0x22");
        check_eq(rd_val[23:16] == 8'h02,                             "S2 ERR_LOG[0].code==0x02");

        // ---------------- S3 ----------------
        $display("");
        $display("-------- S3: Multi-command 2x SM4_ENCRYPT --------");
        submit_cmd(8'h31, 4'h0, 2'd0,
                   256'h0123456789ABCDEFFEDCBA9876543210,
                   256'h0123456789ABCDEFFEDCBA9876543210, 256'd0);
        submit_cmd(8'h32, 4'h0, 2'd1,
                   256'h0123456789ABCDEFFEDCBA9876543210,
                   256'h0123456789ABCDEFFEDCBA9876543210, 256'd0);
        wait_dma;
        check_eq(cap_rid == 8'h31,                                   "S3 cmd1 rid==0x31");
        check_eq(cap_data[383:256] == 128'h681EDF34D206965E86B3E94F536E4246, "S3 cmd1 data==GB_CT");
        wait_msix;
        check_eq(cap_irq_cnt == 3,                                    "S3 cmd1 msix captured (#3)");
        wait_dma;
        check_eq(cap_rid == 8'h32,                                   "S3 cmd2 rid==0x32");
        check_eq(cap_data[383:256] == 128'h681EDF34D206965E86B3E94F536E4246, "S3 cmd2 data==GB_CT");
        wait_msix;
        check_eq(cap_irq_cnt == 4,                                    "S3 cmd2 msix captured (#4)");

        // ---------------- S4 ----------------
        $display("");
        $display("-------- S4: CTRL_FLUSH + post-flush --------");
        repeat (20) @(posedge clk); #1;
        mmio_write(12'h104, 32'd0);
        repeat (3) @(posedge clk); #1;
        check_eq(cmd_queue_lvl == 5'd0,                              "S4 cmd_lvl==0 after flush");
        check_eq(done_queue_lvl == 5'd0,                              "S4 done_lvl==0");
        submit_cmd(8'h41, 4'h0, 2'd0,
                   256'h0123456789ABCDEFFEDCBA9876543210,
                   256'h0123456789ABCDEFFEDCBA9876543210, 256'd0);
        wait_dma;
        check_eq(cap_rid == 8'h41,                                   "S4 post-flush rid==0x41");
        check_eq(cap_data[383:256] == 128'h681EDF34D206965E86B3E94F536E4246, "S4 post-flush data==GB_CT");
        wait_msix;
        check_eq(cap_irq_cnt == 5,                                    "S4 msix captured (#5)");

        // ---------------- S5 ----------------
        $display("");
        $display("-------- S5: MSI-X mask/unmask --------");
        mmio_write(12'h308, 32'd1);
        repeat (3) @(posedge clk); #1;
        check_eq(msix_masked[0] == 1'b1,                             "S5a masked[0]==1 (masked)");
        submit_cmd(8'h51, 4'h0, 2'd0,
                   256'h0123456789ABCDEFFEDCBA9876543210,
                   256'h0123456789ABCDEFFEDCBA9876543210, 256'd0);
        wait_dma;
        check_eq(cap_rid == 8'h51,                                   "S5a DMA still fires");
        // pend 是寄存器, trigger 后下一个 posedge 才更新; 仅等 #1 读到旧值 0
        repeat (2) @(posedge clk); #1;
        check_eq(msix_pending[0] == 1'b1,                            "S5a pending[0]==1 (masked irq pending)");

        mmio_write(12'h308, 32'd0);
        repeat (3) @(posedge clk); #1;
        check_eq(msix_masked[0] == 1'b0,                             "S5b masked[0]==0 (unmasked)");
        submit_cmd(8'h52, 4'h0, 2'd0,
                   256'h0123456789ABCDEFFEDCBA9876543210,
                   256'h0123456789ABCDEFFEDCBA9876543210, 256'd0);
        wait_dma;
        check_eq(cap_rid == 8'h52,                                   "S5b DMA fires");
        wait_msix;
        check_eq(cap_irq_cnt == 6,                                    "S5b msix captured (#6)");
        check_eq(cap_irq_addr == 32'hDEAD,                            "S5b msix fires (unmasked)");
        check_eq(msix_pending[0] == 1'b0,                            "S5b pending[0]==0 (irq cleared)");

        // ---------------- S6 ----------------
        $display("");
        $display("-------- S6: Version/status read --------");
        mmio_read(12'h000, rd_val);
        check_eq(rd_val[31:16] == 16'h0002,                          "S6 VERSION.HW==0x0002");
        check_eq(rd_val[15:0]  == 16'h0800,                          "S6 VERSION.FW==0x0800");

        // ---------------- 汇总 ----------------
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
