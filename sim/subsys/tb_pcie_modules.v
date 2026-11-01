
`timescale 1ns / 1ps

module tb_pcie_modules;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = !clk;

    integer ntest = 0;
    integer npass = 0;
    integer npfail = 0;

    task check(input cond, input [255:0] msg);
        begin
            ntest = ntest + 1;
            if (cond) npass = npass + 1;
            else begin
                npfail = npfail + 1;
                $display("FAIL #%0d t=%0t: %s", ntest, $time, msg);
            end
        end
    endtask

    task wait_beats(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
            #1;
        end
    endtask

    // ---- cmd_queue_buf ----
    reg             q_wr_en = 0;
    reg  [7:0]      q_rid   = 0;
    reg  [3:0]      q_op    = 0;
    reg  [1:0]      q_prio  = 0;
    reg  [511:0]    q_ia    = 0;
    reg  [511:0]    q_ib    = 0;
    reg  [255:0]    q_ic    = 0;
    wire            q_vld;
    reg             q_rdy   = 0;
    wire [7:0]      q_o_rid;
    wire [3:0]      q_o_op;
    wire [1:0]      q_o_prio;
    wire [511:0]    q_o_ia;
    wire [511:0]    q_o_ib;
    wire [255:0]    q_o_ic;
    wire [8:0]      q_lvl;
    wire            q_empty;
    wire            q_full;
    reg             q_flush = 0;

    cmd_queue_buf #(.DEPTH(8),.PTR_W(8),.CNT_W(9),.IA_W(512),.IB_W(512),.IC_W(256)) u_cq (
        .clk(clk),.rst_n(rst_n),
        .i_wr_en(q_wr_en),.i_rid(q_rid),.i_op(q_op),.i_prio(q_prio),
        .i_ia(q_ia),.i_ib(q_ib),.i_ic(q_ic),
        .o_vld(q_vld),.i_rdy(q_rdy),
        .o_rid(q_o_rid),.o_op(q_o_op),.o_prio(q_o_prio),
        .o_ia(q_o_ia),.o_ib(q_o_ib),.o_ic(q_o_ic),
        .o_lvl(q_lvl),.o_empty(q_empty),.o_full(q_full),
        .o_head_ptr(),.o_tail_ptr(),.i_flush(q_flush)
    );

    // ---- bar_ctrl ----
    reg  [11:0]     b_addr = 0;
    reg  [31:0]     b_wr_data = 0;
    reg             b_wr_en = 0;
    wire [31:0]     b_rd_data;
    wire            b_rd_vld;
    wire            b_cmd_wr_en;
    wire [7:0]      b_cmd_rid;
    wire [3:0]      b_cmd_op;
    wire [1:0]      b_cmd_prio;
    wire [255:0]    b_cmd_ia;
    wire [255:0]    b_cmd_ib;
    wire [255:0]    b_cmd_ic;
    wire [8:0]      b_cmd_lvl;
    wire            b_cmd_full;
    wire [8:0]      b_done_lvl;
    wire            b_done_full;
    reg  [7:0]      b_err_rid = 0;
    reg  [7:0]      b_err_code = 0;
    reg             b_err_vld = 0;
    wire            b_ctrl_start;
    wire            b_ctrl_flush;
    wire            b_ctrl_reset;

    bar_ctrl u_bar (
        .clk(clk),.rst_n(rst_n),
        .mmio_addr(b_addr),.mmio_wr_data(b_wr_data),.mmio_wr_en(b_wr_en),
        .mmio_rd_data(b_rd_data),.mmio_rd_vld(b_rd_vld),
        .cmd_wr_en(b_cmd_wr_en),.cmd_rid(b_cmd_rid),.cmd_op(b_cmd_op),
        .cmd_prio(b_cmd_prio),.cmd_ia(b_cmd_ia),.cmd_ib(b_cmd_ib),
        .cmd_ic(b_cmd_ic),.cmd_lvl(b_cmd_lvl),.cmd_full(b_cmd_full),
        .done_lvl(b_done_lvl),.done_full(b_done_full),
        .err_src_rid(b_err_rid),.err_src_code(b_err_code),.err_src_vld(b_err_vld),
        .ctrl_start(b_ctrl_start),.ctrl_flush(b_ctrl_flush),.ctrl_reset(b_ctrl_reset)
    );

    // 驱动悬空端口 (bar_ctrl 的队列状态输入, TB 中无真实队列连接)
    assign b_cmd_lvl = 9'd0;
    assign b_cmd_full = 1'b0;
    assign b_done_lvl = 9'd0;
    assign b_done_full = 1'b0;

    // ---- dma_desc_engine ----
    reg             d_res_vld = 0;
    wire            d_res_rdy;
    reg  [7:0]      d_res_rid = 0;
    reg  [7:0]      d_res_err = 0;
    reg             d_res_ok  = 0;
    reg  [255:0]    d_res_ra  = 0;
    reg  [255:0]    d_res_rb  = 0;
    wire            d_dma_wr_vld;
    reg             d_dma_wr_rdy = 0;
    wire [63:0]     d_dma_wr_desc;
    wire [511:0]    d_dma_wr_data;
    wire [7:0]      d_dma_wr_rid;
    wire [7:0]      d_dma_wr_err;
    wire            d_dma_wr_ok;
    wire [8:0]      d_cq_lvl;
    wire            d_cq_empty;
    wire            d_cq_full;
    reg             d_flush = 0;

    dma_desc_engine #(.CQ_DEPTH(16),.PTR_W(8),.CNT_W(9)) u_dma (
        .clk(clk),.rst_n(rst_n),
        .res_vld(d_res_vld),.res_rdy(d_res_rdy),
        .res_rid(d_res_rid),.res_err(d_res_err),.res_ok(d_res_ok),
        .res_ra(d_res_ra),.res_rb(d_res_rb),
        .dma_wr_vld(d_dma_wr_vld),.dma_wr_rdy(d_dma_wr_rdy),
        .dma_wr_desc(d_dma_wr_desc),.dma_wr_data(d_dma_wr_data),
        .dma_wr_rid(d_dma_wr_rid),.dma_wr_err(d_dma_wr_err),
        .dma_wr_ok(d_dma_wr_ok),
        .cq_lvl(d_cq_lvl),.cq_empty(d_cq_empty),.cq_full(d_cq_full),
        .cq_head_ptr(),.cq_tail_ptr(),.i_flush(d_flush)
    );

    // ---- msix_ctrl ----
    reg             m_tbl_wr_en = 0;
    reg  [2:0]      m_tbl_wr_vec = 0;
    reg  [31:0]     m_tbl_wr_addr = 0;
    reg  [31:0]     m_tbl_wr_data = 0;
    reg             m_tbl_wr_mask = 1;
    reg             m_irq_trigger = 0;
    reg  [2:0]      m_irq_vec = 0;
    wire            m_irq_vld;
    wire [31:0]     m_irq_addr;
    wire [31:0]     m_irq_data;
    wire [2:0]      m_irq_vec_out;
    wire [7:0]      m_pending;
    wire [7:0]      m_masked;
    wire            m_any_pending;

    msix_ctrl #(.NVECT(8),.VEC_ADR_W(32),.VEC_DAT_W(32)) u_msix (
        .clk(clk),.rst_n(rst_n),
        .tbl_wr_en(m_tbl_wr_en),.tbl_wr_vec(m_tbl_wr_vec),
        .tbl_wr_addr(m_tbl_wr_addr),.tbl_wr_data(m_tbl_wr_data),
        .tbl_wr_mask(m_tbl_wr_mask),
        .irq_trigger(m_irq_trigger),.irq_vec(m_irq_vec),
        .irq_vld(m_irq_vld),.irq_addr(m_irq_addr),.irq_data(m_irq_data),
        .irq_vec_out(m_irq_vec_out),
        .pending(m_pending),.masked(m_masked),.any_pending(m_any_pending)
    );

    initial begin
        # 10000000;
        $display("TB GLOBAL TIMEOUT t=%0t", $time);
        $finish;
    end

    initial begin
        rst_n=0;
        q_wr_en=0;q_rid=0;q_op=0;q_prio=0;q_ia=0;q_ib=0;q_ic=0;q_rdy=0;q_flush=0;
        b_addr=0;b_wr_data=0;b_wr_en=0;b_err_rid=0;b_err_code=0;b_err_vld=0;
        d_res_vld=0;d_res_rid=0;d_res_err=0;d_res_ok=0;d_res_ra=0;d_res_rb=0;d_dma_wr_rdy=0;d_flush=0;
        m_tbl_wr_en=0;m_tbl_wr_vec=0;m_tbl_wr_addr=0;m_tbl_wr_data=0;m_tbl_wr_mask=1;
        m_irq_trigger=0;m_irq_vec=0;
        repeat(4) @(posedge clk); #1; rst_n=1; wait_beats(3);

        // ============================================================
        // S1: cmd_queue_buf 基本 FIFO
        // ============================================================
        $display("[S1] start t=%0t", $time);
        @(negedge clk); q_wr_en=1;q_rid=8'h01;q_op=4'h0;q_prio=2'd1;
        q_ia=512'hDEAD;q_ib=512'hBEEF;q_ic=256'hCAFE;
        @(posedge clk); #1; q_wr_en=0;

        @(negedge clk); q_wr_en=1;q_rid=8'h02;q_op=4'h1;q_prio=2'd2;
        q_ia=512'h1111;q_ib=512'h2222;q_ic=256'h3333;
        @(posedge clk); #1; q_wr_en=0;

        @(negedge clk); q_wr_en=1;q_rid=8'h03;q_op=4'h2;q_prio=2'd0;
        q_ia=512'hAAAA;q_ib=512'hBBBB;q_ic=256'hCCCC;
        @(posedge clk); #1; q_wr_en=0;
        wait_beats(2);

        check(q_lvl==9'd3, "S1: lvl=3");
        check(q_empty==0, "S1: not empty");

        // 弹出: 先读输出(q_rdy=0, head 不推进), 再 pop
        check(q_o_rid==8'h01, "S1: rid[0]=01");
        check(q_o_op==4'h0, "S1: op[0]=0");
        check(q_o_prio==2'd1, "S1: prio[0]=1");

        @(negedge clk); q_rdy=1;
        @(posedge clk); #1; q_rdy=0;
        wait_beats(1);
        check(q_lvl==9'd2, "S1: lvl after pop=2");

        check(q_o_rid==8'h02, "S1: rid[1]=02");
        @(negedge clk); q_rdy=1;
        @(posedge clk); #1; q_rdy=0;
        wait_beats(1);
        check(q_lvl==9'd1, "S1: lvl after 2nd pop=1");

        check(q_o_rid==8'h03, "S1: rid[2]=03");
        @(negedge clk); q_rdy=1;
        @(posedge clk); #1; q_rdy=0;
        wait_beats(1);
        check(q_empty==1, "S1: empty after 3rd pop");
        check(q_lvl==0, "S1: lvl=0");
        wait_beats(3);
        $display("[S1] done t=%0t", $time);

        // ============================================================
        // S2: cmd_queue_buf 满检测 + 清空
        // ============================================================
        $display("[S2] start t=%0t", $time);
        begin : fill_q
            integer i;
            for (i=0;i<8;i=i+1) begin
                @(negedge clk);
                q_wr_en=1;q_rid=i[7:0];q_op=4'h0;q_prio=2'd0;
                q_ia=512'd0;q_ib=512'd0;q_ic=256'd0;
                @(posedge clk); #1; q_wr_en=0;
            end
        end
        wait_beats(2);
        check(q_full==1, "S2: full after 8 writes");
        check(q_lvl==9'd8, "S2: lvl=8");

        @(negedge clk); q_flush=1;
        @(posedge clk); #1; q_flush=0;
        wait_beats(2);
        check(q_empty==1, "S2: empty after flush");
        check(q_lvl==0, "S2: lvl=0 after flush");
        wait_beats(3);
        $display("[S2] done t=%0t", $time);

        // ============================================================
        // S3: bar_ctrl MMIO 寄存器读写
        // ============================================================
        $display("[S3] start t=%0t", $time);
        @(negedge clk); b_addr=12'h000; b_wr_en=0;
        @(posedge clk); #1;
        wait_beats(1);
        check(b_rd_data[31:16]==16'h0002, "S3: VERSION_HW=0x0002");
        check(b_rd_data[15:0]==16'h0800, "S3: VERSION_FW=0x0800");

        @(negedge clk); b_addr=12'h004;
        @(posedge clk); #1;
        wait_beats(1);
        check(b_rd_data[0]==1, "S3: STATUS.ready=1");

        @(negedge clk); b_addr=12'h008;
        @(posedge clk); #1;
        wait_beats(1);
        check(b_rd_data[8:0]==0, "S3: CMD_QUEUE_DEPTH=0");
        wait_beats(3);
        $display("[S3] done t=%0t", $time);

        // ============================================================
        // S4: bar_ctrl Doorbell 命令入队
        // ============================================================
        $display("[S4] start t=%0t", $time);
        @(negedge clk);
        // 两步协议: 先写 BAR1 0x000 命令 head shadow, 再写 0x100 CTRL_START 打门铃。
        // 0x100 分支只产生 doorbell 脉冲, 不写 shadow_head —— 一次写入两者都做完是错的。
        // (旧值 0x010 是 BAR0 shadow ia[127:96] 的地址, 根本打不到 doorbell)
        b_addr=12'h000;
        // head word 布局 (bar_ctrl v1.1): [3:0]=op [11:4]=rid [21:20]=prio [31:22]=保留
        b_wr_data={10'd0, 2'd0, 8'h00, 8'h01, 4'h0};
        b_wr_en=1;
        @(posedge clk); #1; b_wr_en=0;
        wait_beats(1);

        @(negedge clk); b_addr=12'h100; b_wr_data=32'd0; b_wr_en=1;
        @(posedge clk); #1; b_wr_en=0;
        // cmd_wr_en 是 1 拍寄存器脉冲, posedge 后 #1 已越过 NBA 区
        check(b_cmd_wr_en==1, "S4: cmd_wr_en pulse");
        check(b_cmd_rid==8'h01, "S4: cmd_rid=0x01");
        check(b_cmd_op==4'h0, "S4: cmd_op=0");
        wait_beats(3);
        $display("[S4] done t=%0t", $time);

        // ============================================================
        // S5: bar_ctrl 错误日志
        // ============================================================
        $display("[S5] start t=%0t", $time);
        @(negedge clk);
        b_err_rid=8'hAA; b_err_code=8'h02; b_err_vld=1;
        @(posedge clk); #1; b_err_vld=0;
        wait_beats(2);

        @(negedge clk); b_addr=12'h200;
        @(posedge clk); #1;
        wait_beats(1);
        check(b_rd_data[31:24]==8'hAA, "S5: err_log[0].rid=0xAA");
        check(b_rd_data[23:16]==8'h02, "S5: err_log[0].err=0x02");

        @(negedge clk); b_addr=12'h004;
        @(posedge clk); #1;
        wait_beats(1);
        check(b_rd_data[2]==1, "S5: STATUS.err=1");
        wait_beats(3);
        $display("[S5] done t=%0t", $time);

        // ============================================================
        // S6: dma_desc_engine 结果收集
        // ============================================================
        $display("[S6] start t=%0t", $time);
        @(negedge clk);
        d_res_vld=1;d_res_rid=8'h10;d_res_err=8'h00;d_res_ok=1;
        d_res_ra=256'hDEADBEEF;d_res_rb=256'hCAFEBABE;
        @(posedge clk); #1; d_res_vld=0;
        wait_beats(3);

        check(d_dma_wr_vld==1, "S6: dma_wr_vld");
        check(d_dma_wr_rid==8'h10, "S6: dma_wr_rid=0x10");
        check(d_dma_wr_ok==1, "S6: dma_wr_ok=1");
        check(d_dma_wr_data[511:256]==256'hDEADBEEF, "S6: data.ra(511:256)");
        check(d_dma_wr_data[255:0]==256'hCAFEBABE, "S6: data.rb(255:0)");

        @(negedge clk); d_dma_wr_rdy=1;
        @(posedge clk); #1; d_dma_wr_rdy=0;
        wait_beats(3);
        $display("[S6] done t=%0t", $time);

        // ============================================================
        // S7: msix_ctrl 中断触发
        // ============================================================
        $display("[S7] start t=%0t", $time);
        @(negedge clk);
        m_tbl_wr_en=1;m_tbl_wr_vec=3'd0;
        m_tbl_wr_addr=32'h0000_1000;m_tbl_wr_data=32'h0000_0001;
        m_tbl_wr_mask=0;
        @(posedge clk); #1; m_tbl_wr_en=0;
        wait_beats(2);

        @(negedge clk);
        m_irq_trigger=1;m_irq_vec=3'd0;
        @(posedge clk); #1; m_irq_trigger=0;
        // 立即检查 irq_vld 脉冲 (1 拍)
        check(m_irq_vld==1, "S7: irq_vld pulse");
        check(m_irq_addr==32'h0000_1000, "S7: irq_addr=0x1000");
        check(m_irq_data==32'h0000_0001, "S7: irq_data=0x01");
        check(m_irq_vec_out==3'd0, "S7: irq_vec_out=0");

        wait_beats(3);
        // 屏蔽测试
        @(negedge clk);
        m_tbl_wr_en=1;m_tbl_wr_vec=3'd0;m_tbl_wr_mask=1;
        @(posedge clk); #1; m_tbl_wr_en=0;
        wait_beats(2);

        @(negedge clk);
        m_irq_trigger=1;m_irq_vec=3'd0;
        @(posedge clk); #1; m_irq_trigger=0;
        check(m_irq_vld==0, "S7: no irq when masked");
        wait_beats(2);
        check(m_pending[0]==1, "S7: pending[0]=1 when masked");
        wait_beats(3);
        $display("[S7] done t=%0t", $time);

        $display("");
        $display("==========================================");
        $display("PCIE MODULES TB: ntest=%0d npass=%0d npfail=%0d",
                 ntest,npass,npfail);
        if(npfail==0) $display("RESULT: PASS");
        else          $display("RESULT: FAIL");
        $display("==========================================");
        $display("");
        $finish;
    end

endmodule
