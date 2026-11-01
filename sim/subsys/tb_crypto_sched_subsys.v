
`timescale 1ns / 1ps

module tb_crypto_sched_subsys;

    // ---- 时钟与复位 ----
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = !clk;  // 100 MHz (仿真加速)

    // ---- DUT 接口 ----
    reg         cmd_vld = 0;
    wire        cmd_rdy;
    reg  [7:0]  cmd_rid  = 0;
    reg  [3:0]  cmd_op   = 0;
    reg  [1:0]  cmd_prio = 0;
    reg  [511:0] cmd_ia  = 0;
    reg  [511:0] cmd_ib  = 0;
    reg  [255:0] cmd_ic  = 0;

    wire        res_vld;
    reg         res_rdy = 1;
    wire [7:0]  res_rid;
    wire [7:0]  res_err;
    wire        res_ok;
    wire [255:0] res_ra;
    wire [255:0] res_rb;

    crypto_sched_subsys u_dut (
        .clk(clk), .rst_n(rst_n),
        .cmd_vld(cmd_vld), .cmd_rdy(cmd_rdy),
        .cmd_rid(cmd_rid), .cmd_op(cmd_op), .cmd_prio(cmd_prio),
        .cmd_ia(cmd_ia), .cmd_ib(cmd_ib), .cmd_ic(cmd_ic),
        .res_vld(res_vld), .res_rdy(res_rdy),
        .res_rid(res_rid), .res_err(res_err), .res_ok(res_ok),
        .res_ra(res_ra), .res_rb(res_rb)
    );

    // ---- 计数器 ----
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

    // ---- 结果监控 (环形缓冲) ----
    localparam RES_BUF_SZ = 16;
    integer res_count = 0;
    reg [7:0]  res_buf_rid [0:RES_BUF_SZ-1];
    reg [7:0]  res_buf_err [0:RES_BUF_SZ-1];
    reg        res_buf_ok  [0:RES_BUF_SZ-1];
    reg [255:0] res_buf_ra [0:RES_BUF_SZ-1];
    reg [255:0] res_buf_rb [0:RES_BUF_SZ-1];

    always @(posedge clk) begin
        if (res_vld && res_rdy) begin
            res_buf_rid[res_count % RES_BUF_SZ] = res_rid;
            res_buf_err[res_count % RES_BUF_SZ] = res_err;
            res_buf_ok[res_count % RES_BUF_SZ]  = res_ok;
            res_buf_ra[res_count % RES_BUF_SZ]  = res_ra;
            res_buf_rb[res_count % RES_BUF_SZ]  = res_rb;
            res_count = res_count + 1;
        end
    end

    // ---- 复位 ----
    task reset_dut;
        begin
            cmd_vld = 0; cmd_op = 0; cmd_rid = 0; cmd_prio = 0;
            cmd_ia = 0; cmd_ib = 0; cmd_ic = 0;
            res_rdy = 1;
            rst_n = 0;
            repeat (4) @(posedge clk);
            #1;
            rst_n = 1;
            wait_beats(2);
        end
    endtask

    task wait_beats(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
            #1;
        end
    endtask

    task send_cmd(input [3:0] op, input [7:0] rid, input [1:0] prio,
                  input [511:0] ia, input [511:0] ib, input [255:0] ic);
        begin
            @(negedge clk);
            cmd_vld = 1; cmd_op = op; cmd_rid = rid; cmd_prio = prio;
            cmd_ia = ia; cmd_ib = ib; cmd_ic = ic;
            @(posedge clk);
            #1;
            cmd_vld = 0;
        end
    endtask

    task wait_res(input integer nth, input [7:0] expect_rid,
                  input [7:0] expect_err, input expect_ok);
        integer cnt;
        begin
            cnt = 0;
            while (res_count <= nth) begin
                @(posedge clk);
                cnt = cnt + 1;
                if (cnt > 50000) begin
                    $display("TIMEOUT wait_res #%0d at t=%0t seen=%0d",
                             nth, $time, res_count);
                    npfail = npfail + 1;
                    ntest = ntest + 1;
                    disable wait_res;
                end
            end
            ntest = ntest + 1;
            if (res_buf_rid[nth % RES_BUF_SZ] === expect_rid &&
                res_buf_err[nth % RES_BUF_SZ] === expect_err &&
                res_buf_ok[nth % RES_BUF_SZ] === expect_ok) begin
                npass = npass + 1;
            end else begin
                npfail = npfail + 1;
                $display("FAIL res #%0d: rid=%0h/%0h err=%0h/%0h ok=%b/%b at t=%0t",
                         nth, res_buf_rid[nth % RES_BUF_SZ], expect_rid,
                         res_buf_err[nth % RES_BUF_SZ], expect_err,
                         res_buf_ok[nth % RES_BUF_SZ], expect_ok, $time);
            end
        end
    endtask

    task clear_res_monitor;
        begin
            res_count = 0;
        end
    endtask

    // ---- 全局超时守护 ----
    initial begin
        # 5000000;
        $display("TB GLOBAL TIMEOUT t=%0t", $time);
        $finish;
    end

    // =================================================================
    //  主测试流程
    // =================================================================
    initial begin
        reset_dut;

        // =================================================================
        //  S1: 非法 op 快速返回
        // =================================================================
        $display("[S1] start t=%0t", $time);
        clear_res_monitor;
        send_cmd(4'd7, 8'hFF, 2'd0, 512'd0, 512'd0, 256'd0);
        wait_res(0, 8'hFF, 8'h02, 1'b0);
        wait_beats(3);
        $display("[S1] done t=%0t", $time);

        // =================================================================
        //  S2: SM4_ENC 基础功能 (GB/T 32907-2016 标准向量)
        //   key=pt=0x0123456789ABCDEFFEDCBA9876543210
        //   ct=0x681EDF34D206965E86B3E94F536E4246
        // =================================================================
        $display("[S2] start t=%0t", $time);
        clear_res_monitor;
        send_cmd(4'h0, 8'h01, 2'd1,
                 {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                 {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                 256'd0);
        wait_res(0, 8'h01, 8'h00, 1'b1);
        // 检查 SM4 加密结果 (低 128 位 = ct)
        ntest = ntest + 1;
        if (res_buf_ra[0][127:0] === 128'h681EDF34D206965E86B3E94F536E4246)
            npass = npass + 1;
        else begin
            npfail = npfail + 1;
            $display("FAIL S2 SM4 ct mismatch: %h at t=%0t",
                     res_buf_ra[0][127:0], $time);
        end
        wait_beats(3);
        $display("[S2] done t=%0t", $time);

        // =================================================================
        //  S3: 混合优先级 (rid=02 prio=2, rid=03 prio=1)
        //  注: 两条背靠背发送, arbiter 在第二条入队前已弹出第一条,
        //      因此结果顺序取决于到达时序, 不强制校验先后。
        //      仅验证两条命令都正确返回 (rid 集合 = {02,03}, err=0, ok=1)。
        // =================================================================
        $display("[S3] start t=%0t", $time);
        clear_res_monitor;
        send_cmd(4'h0, 8'h02, 2'd2,
                 {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                 {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                 256'd0);
        send_cmd(4'h0, 8'h03, 2'd1,
                 {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                 {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                 256'd0);
        // 等 2 条都回来 (不校验顺序)
        begin : wait_s3
            integer wc;
            wc = 0;
            while (res_count < 2) begin
                @(posedge clk);
                wc = wc + 1;
                if (wc > 50000) begin
                    $display("TIMEOUT S3 at t=%0t seen=%0d", $time, res_count);
                    npfail = npfail + 1;
                    ntest = ntest + 1;
                    disable wait_s3;
                end
            end
        end
        ntest = ntest + 1;
        if (((res_buf_rid[0] === 8'h02 && res_buf_rid[1] === 8'h03) ||
             (res_buf_rid[0] === 8'h03 && res_buf_rid[1] === 8'h02)) &&
            (res_buf_err[0] === 8'h00 && res_buf_err[1] === 8'h00) &&
            (res_buf_ok[0] === 1'b1 && res_buf_ok[1] === 1'b1))
            npass = npass + 1;
        else begin
            npfail = npfail + 1;
            $display("FAIL S3: rids=%h %h errs=%h %h oks=%b %b at t=%0t",
                     res_buf_rid[0], res_buf_rid[1],
                     res_buf_err[0], res_buf_err[1],
                     res_buf_ok[0], res_buf_ok[1], $time);
        end
        wait_beats(3);
        $display("[S3] done t=%0t", $time);

        // =================================================================
        //  S4: 连续命令串行执行 (v1.2: 单引擎降配)
        //    crypto_sched_subsys v1.2 删除 u_eng1 后只有 1 个引擎,
        //    两条命令必然排队串行服务 (先到先得), 不再可能并行。
        //    判据不变: 两条都正确返回, rid/err/ok 全对。
        // =================================================================
        $display("[S4] start t=%0t", $time);
        clear_res_monitor;
        // 发 2 条命令, 由单引擎依次处理
        send_cmd(4'h0, 8'h04, 2'd0,
                 {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                 {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                 256'd0);
        send_cmd(4'h0, 8'h05, 2'd0,
                 {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                 {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                 256'd0);
        // 2 条都完成 (单引擎下严格先 04 后 05, 但判据不依赖顺序)
        wait_res(0, 8'h04, 8'h00, 1'b1);
        wait_res(1, 8'h05, 8'h00, 1'b1);
        wait_beats(3);
        $display("[S4] done t=%0t", $time);

        // =================================================================
        //  S5: rid 乱序匹配 (SM4_ENC + SM3_CMP 混合)
        // =================================================================
        $display("[S5] start t=%0t", $time);
        clear_res_monitor;
        // SM4_ENC (rid=0x10)
        send_cmd(4'h0, 8'h10, 2'd0,
                 {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                 {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                 256'd0);
        // SM3_CMP "abc" -> H = 0x66c7f0f4...e30328e9
        // msg_block = "abc" = 0x616263... (512-bit, 前 24 位有效)
        send_cmd(4'h2, 8'h11, 2'd0,
                 {488'd0, 24'h616263},
                 {256'd0},
                 256'd0);
        // 2 条都完成 (顺序不保证, 但 rid 必须正确)
        wait_res(0, 8'h10, 8'h00, 1'b1);
        wait_res(1, 8'h11, 8'h00, 1'b1);
        wait_beats(3);
        $display("[S5] done t=%0t", $time);

        // =================================================================
        //  S6: 队列满反压 (强化: 必须显式断言 cmd_rdy 拉低)
        //   旧 bug: cmd_parser 的 i_rdy (output, 恒为 1) 被连到 cmd_rdy, 与
        //   pq_all_not_full 双驱动。队列满时 cmd_rdy 在仿真里变 X、在综合里被
        //   Vivado 按 Synth 8-6858 取常数端 -> 恒为 1, 反压彻底失效。
        //   强化后必须看到 cmd_rdy === 0 才算反压生效, 且恢复后要回到 1。
        // =================================================================
        $display("[S6] start t=%0t", $time);
        clear_res_monitor;
        // 连发命令直到 cmd_rdy=0
        begin : fill_queue
            integer i;
            i = 0;
            while (cmd_rdy && i < 20) begin
                send_cmd(4'h0, {8'd0, i[3:0]}, 2'd0,
                         {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                         {192'd0, 128'h0123456789ABCDEFFEDCBA9876543210},
                         256'd0);
                i = i + 1;
            end
            $display("[S6] stopped after %0d commands, cmd_rdy=%b", i, cmd_rdy);
            // 断言 1: 反压必须真正拉低 (不是 X, 也不是恒 1)
            ntest = ntest + 1;
            if (cmd_rdy === 1'b0)
                npass = npass + 1;
            else begin
                npfail = npfail + 1;
                $display("FAIL S6 backpressure: cmd_rdy=%b (expect 0) after %0d cmds t=%0t",
                         cmd_rdy, i, $time);
            end
            // 断言 2: 接受的命令数有上限 (反压确实拦住了后续发送)
            // PQ_DEPTH=8, 管线残余最多 2~3 拍, 绝不该把 20 条全吃掉
            ntest = ntest + 1;
            if (i <= 12 && i >= 4)
                npass = npass + 1;
            else begin
                npfail = npfail + 1;
                $display("FAIL S6: accepted %0d cmds (expect 4..12) t=%0t", i, $time);
            end
        end
        // 等所有命令完成
        wait_beats(1000);
        // 断言 3: 队列排空后反压必须解除
        ntest = ntest + 1;
        if (cmd_rdy === 1'b1)
            npass = npass + 1;
        else begin
            npfail = npfail + 1;
            $display("FAIL S6 recovery: cmd_rdy=%b (expect 1 after drain) t=%0t",
                     cmd_rdy, $time);
        end
        // 检查所有命令都有结果
        ntest = ntest + 1;
        if (res_count >= 4)
            npass = npass + 1;
        else begin
            npfail = npfail + 1;
            $display("FAIL S6: expected >=4 results, got %0d at t=%0t",
                     res_count, $time);
        end
        wait_beats(3);
        $display("[S6] done t=%0t", $time);

        // =================================================================
        //  汇总
        // =================================================================
        $display("");
        $display("==========================================");
        $display("SCHED SUBSYS TB: ntest=%0d npass=%0d npfail=%0d",
                 ntest, npass, npfail);
        if (npfail == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $display("==========================================");
        $display("");
        $finish;
    end

endmodule
