// =============================================================================
// 文件 : tb_sm3_sm2_pipe.v
// 项目 : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 阶段 : Phase 0.5.4 B1 - SM3+SM2 签名流水线模块级验证
// 版本 : v1.0
// 日期 : 2026-10-04
// 视角 : sim-verifier
// 说明 : 严格 Verilog-2005 合规
//        - 无 begin 块内声明, 所有变量在 module 作用域
//        - 无端口数组, 用 packed reg
//        - 任务参数只用标量/packed
//        - 消息由 msg[i]=(i*7+L*3+seed)&0xFF 确定性重建
// 运行 : iverilog -g2005 -Wall -I sim/sm2 -s tb_sm3_sm2_pipe \
//            rtl/sm3/sm3_engine.v rtl/sm2/sm2_sign.v rtl/subsys/sm3_sm2_pipe.v \
//            sim/sm2/tb_sm3_sm2_pipe.v -o /tmp/sm3_sm2_pipe.vvp
// =============================================================================

`timescale 1ns / 1ps

module tb_sm3_sm2_pipe;

    // =========================================================================
    // 时钟与复位
    // =========================================================================
    reg clk;
    reg rst_n;

    always #5 clk = ~clk;   // 20ns period = 50MHz; 与 100MHz 等价 (周期无关)

    // =========================================================================
    // DUT 信号
    // =========================================================================
    reg          start;
    reg  [31:0]  msg_len;
    reg  [255:0] d_in;
    reg  [255:0] k_in;
    reg  [7:0]   msg_data;
    reg          msg_vld;

    wire [255:0] e_out;
    wire [255:0] r_out;
    wire [255:0] s_out;
    wire         sig_ok;
    wire [7:0]   err;
    wire         done;
    wire         msg_rdy;

    // =========================================================================
    // 引入测试向量 (include 文件已在 module 体内)
    // =========================================================================
    `include "sm3_sm2_pipe_vectors.vh"

    // =========================================================================
    // DUT 实例化
    // =========================================================================
    sm3_sm2_pipe #(
        .K_MAX_RETRY (4)
    ) u_dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start),
        .msg_len  (msg_len),
        .d_in     (d_in),
        .k_in     (k_in),
        .msg_data (msg_data),
        .msg_vld  (msg_vld),
        .msg_rdy  (msg_rdy),
        .e_out    (e_out),
        .r_out    (r_out),
        .s_out    (s_out),
        .sig_ok   (sig_ok),
        .err      (err),
        .done     (done)
    );

    // =========================================================================
    // 任务辅助变量 (全部 module 作用域)
    // =========================================================================
    integer        i;
    integer        ntest;
    integer        npass;
    integer        nfail;
    integer        cyc_start_t;
    integer        cyc_end_t;
    integer        cyc_total;
    integer        timeout_cnt;
    reg    [31:0]  L_val_r;
    reg    [31:0]  L_arg;
    reg    [255:0] d_arg;
    reg    [255:0] k_arg;
    reg    [255:0] e_arg;
    reg    [255:0] r_arg;
    reg    [255:0] s_arg;
    reg    [7:0]   seed_arg;
    reg    [7:0]   b8;
    reg    [7:0]   err_arg;

    // =========================================================================
    // 任务: 完整端到端 SM3+SM2 签名 (发送消息, 等待 done, 检查 e/r/s)
    // =========================================================================
    task check_sm3_sign;
        begin
            // 参数已由 initial 块设置:
            //   msg_len/d_in/k_in  -> 直接驱动 DUT 输入
            //   e_arg/r_arg/s_arg  -> 预期输出 (在任务内比较时使用)
            //   L_val_r            -> 循环次数 (发送字节数)

            // 复位脉冲
            start    = 1'b0;
            msg_vld  = 1'b0;
            msg_data = 8'h00;
            rst_n    = 1'b0;
            @(posedge clk); @(posedge clk);
            rst_n    = 1'b1;
            @(posedge clk);

            // 启动 (参数已在模块级 wire 上)
            @(posedge clk); #1;
            start    = 1'b1;
            @(posedge clk); #1;
            start    = 1'b0;

            cyc_start_t = $time;

            // 发送消息字节 (如果 L!=0)
            if (L_val_r != 0) begin
                for (i = 0; i < L_val_r; i = i + 1) begin
                    // 等待 msg_rdy (在 msg_rdy 变高后的 NBA 区采样)
                    while (!msg_rdy) @(posedge clk);
                    #1;
                    // 确定性生成消息字节: msg[i] = (i*7 + L*3 + seed) & 0xFF
                    b8       = (i * 7 + L_val_r * 3 + 0) & 8'hFF;
                    msg_data = b8;
                    msg_vld  = 1'b1;
                    @(posedge clk); #1;
                    msg_vld  = 1'b0;
                end
            end

            // 等待 done (带超时保护)
            timeout_cnt = 0;
            while (!done && timeout_cnt < 5000000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end

            #1;
            cyc_end_t = $time;
            cyc_total = (cyc_end_t - cyc_start_t) / 10;   // 10ns per cycle

            // DEBUG: print blk_buf when done
            if (L_val_r == 0 || L_val_r == 56 || L_val_r == 447) begin
                $display("[DEBUG] L=%0d blk_buf=%h", L_val_r, u_dut.blk_buf);
            end

            ntest = ntest + 1;
            if (timeout_cnt >= 5000000) begin
                $display("[FAIL] L=%0d TIMEOUT waiting for done", L_val_r);
                nfail = nfail + 1;
            end else if (e_out !== e_arg) begin
                $display("[FAIL] L=%0d e mismatch\n  exp=%h\n  got=%h",
                         L_val_r, e_arg, e_out);
                nfail = nfail + 1;
            end else if (r_out !== r_arg) begin
                $display("[FAIL] L=%0d r mismatch\n  exp=%h\n  got=%h",
                         L_val_r, r_arg, r_out);
                nfail = nfail + 1;
            end else if (s_out !== s_arg) begin
                $display("[FAIL] L=%0d s mismatch\n  exp=%h\n  got=%h",
                         L_val_r, s_arg, s_out);
                nfail = nfail + 1;
            end else begin
                $display("[PASS] L=%0d cyc=%0d e=%h.. r=%h.. s=%h..",
                         L_val_r, cyc_total,
                         e_out[255:224], r_out[255:224], s_out[255:224]);
                npass = npass + 1;
            end
        end
    endtask

    // =========================================================================
    // 任务: k 越界错误 (msg_len=0, 触发 k_invalid 分支)
    // =========================================================================
    task check_k_invalid;
        begin
            start   = 1'b0;
            msg_vld = 1'b0;
            rst_n   = 1'b0;
            @(posedge clk); @(posedge clk);
            rst_n   = 1'b1;
            @(posedge clk);

            // 参数在模块级 wire 上
            msg_len = 32'd0;
            // d_in/k_in 已经在驱动

            @(posedge clk); #1;
            start = 1'b1;
            @(posedge clk); #1;
            start = 1'b0;

            timeout_cnt = 0;
            while (!done && timeout_cnt < 100000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end

            #1;
            ntest = ntest + 1;
            if (timeout_cnt >= 100000) begin
                $display("[FAIL] TIMEOUT on k_invalid test");
                nfail = nfail + 1;
            end else if (err === err_arg) begin
                $display("[PASS] k=%h err=%h (expected %h)",
                         k_in[255:224], err, err_arg);
                npass = npass + 1;
            end else begin
                $display("[FAIL] k=%h err exp=%h got=%h",
                         k_in[255:224], err_arg, err);
                nfail = nfail + 1;
            end
        end
    endtask

    // =========================================================================
    // 主测试序列
    // =========================================================================
    initial begin
        // 初始状态
        clk      = 1'b0;
        rst_n    = 1'b0;
        start    = 1'b0;
        msg_vld  = 1'b0;
        msg_data = 8'h00;
        msg_len  = 32'd0;
        d_in     = 256'd0;
        k_in     = 256'd0;

        ntest = 0;
        npass = 0;
        nfail = 0;

        $display("=============================================================");
        $display("SM3 + SM2 Pipeline Testbench (Phase 0.5.4 B1)");
        $display("=============================================================");

        // =====================================================================
        // T1: 空消息 (msg_len=0)
        // =====================================================================
        $display("\n--- T1: Empty message (L=0) ---");
        msg_len = `VC_SIGN_L0000_LEN;
        d_in    = `VC_SIGN_L0000_D;
        k_in    = `VC_SIGN_L0000_K;
        e_arg   = `VC_SIGN_L0000_E;
        r_arg   = `VC_SIGN_L0000_R;
        s_arg   = `VC_SIGN_L0000_S;
        L_val_r = `VC_SIGN_L0000_LEN;
        check_sm3_sign;

        // =====================================================================
        // T2: 单字节 (L=1)
        // =====================================================================
        $display("\n--- T2: Single byte (L=1) ---");
        msg_len = `VC_SIGN_L0001_LEN;
        d_in    = `VC_SIGN_L0001_D;
        k_in    = `VC_SIGN_L0001_K;
        e_arg   = `VC_SIGN_L0001_E;
        r_arg   = `VC_SIGN_L0001_R;
        s_arg   = `VC_SIGN_L0001_S;
        L_val_r = `VC_SIGN_L0001_LEN;
        check_sm3_sign;

        // =====================================================================
        // T3: L=55 (1 块上边界, pad_k1=0, pad_k2=0)
        // =====================================================================
        $display("\n--- T3: L=55 (1 block, same-block end) ---");
        msg_len = `VC_SIGN_L0055_LEN;
        d_in    = `VC_SIGN_L0055_D;
        k_in    = `VC_SIGN_L0055_K;
        e_arg   = `VC_SIGN_L0055_E;
        r_arg   = `VC_SIGN_L0055_R;
        s_arg   = `VC_SIGN_L0055_S;
        L_val_r = `VC_SIGN_L0055_LEN;
        check_sm3_sign;

        // =====================================================================
        // T4: L=56 (2 块下边界, pad_k1=7, pad_k2=56)
        // =====================================================================
        $display("\n--- T4: L=56 (2 blocks, cross-block end) ---");
        msg_len = `VC_SIGN_L0056_LEN;
        d_in    = `VC_SIGN_L0056_D;
        k_in    = `VC_SIGN_L0056_K;
        e_arg   = `VC_SIGN_L0056_E;
        r_arg   = `VC_SIGN_L0056_R;
        s_arg   = `VC_SIGN_L0056_S;
        L_val_r = `VC_SIGN_L0056_LEN;
        check_sm3_sign;

        // =====================================================================
        // T5: L=447 (8 块, byte_off==55 边界)
        // =====================================================================
        $display("\n--- T5: L=447 (8 blocks, byte_off==55) ---");
        msg_len = `VC_SIGN_L0447_LEN;
        d_in    = `VC_SIGN_L0447_D;
        k_in    = `VC_SIGN_L0447_K;
        e_arg   = `VC_SIGN_L0447_E;
        r_arg   = `VC_SIGN_L0447_R;
        s_arg   = `VC_SIGN_L0447_S;
        L_val_r = `VC_SIGN_L0447_LEN;
        check_sm3_sign;

        // =====================================================================
        // T6: L=512 (8 块整, byte_off==0 走 S_HASH_RECV 分支)
        // =====================================================================
        $display("\n--- T6: L=512 (8 blocks exact, S_HASH_RECV branch) ---");
        msg_len = `VC_SIGN_L0512_LEN;
        d_in    = `VC_SIGN_L0512_D;
        k_in    = `VC_SIGN_L0512_K;
        e_arg   = `VC_SIGN_L0512_E;
        r_arg   = `VC_SIGN_L0512_R;
        s_arg   = `VC_SIGN_L0512_S;
        L_val_r = `VC_SIGN_L0512_LEN;
        check_sm3_sign;

        // =====================================================================
        // T7: L=1024 (16 块整)
        // =====================================================================
        $display("\n--- T7: L=1024 (16 blocks exact) ---");
        msg_len = `VC_SIGN_L1024_LEN;
        d_in    = `VC_SIGN_L1024_D;
        k_in    = `VC_SIGN_L1024_K;
        e_arg   = `VC_SIGN_L1024_E;
        r_arg   = `VC_SIGN_L1024_R;
        s_arg   = `VC_SIGN_L1024_S;
        L_val_r = `VC_SIGN_L1024_LEN;
        check_sm3_sign;

        // =====================================================================
        // T8: k=0 错误
        // =====================================================================
        $display("\n--- T8: k=0 -> err=0x01 ---");
        d_in    = 256'h1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        k_in    = 256'd0;
        err_arg = 8'h01;
        check_k_invalid;

        // =====================================================================
        // T9: k=n 错误 (k 必须 < n)
        // =====================================================================
        $display("\n--- T9: k=n -> err=0x01 ---");
        k_in    = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123;
        err_arg = 8'h01;
        check_k_invalid;

        // =====================================================================
        // T10: k=n-1 有效 (边界, 应正常签名)
        //   签名模式 (op=0) 下 sig_ok 恒为 0 (那是验签指示),
        //   签名成功的判定条件是 err==0 (即未触发 r=0/r+k=n/s=0 拒绝)。
        // =====================================================================
        $display("\n--- T10: k=n-1 valid boundary ---");
        msg_len = 32'd0;
        d_in    = 256'ha9aa4026022809eefe9c27ba5935c64e795c83923a1e9668cf1bac6cf858c4d7;
        k_in    = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54122;
        L_val_r = 32'd0;

        start   = 1'b0;
        msg_vld = 1'b0;
        rst_n   = 1'b0;
        @(posedge clk); @(posedge clk);
        rst_n   = 1'b1;
        @(posedge clk);

        @(posedge clk); #1;
        start = 1'b1;
        @(posedge clk); #1;
        start = 1'b0;

        timeout_cnt = 0;
        while (!done && timeout_cnt < 5000000) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
        end
        if (timeout_cnt >= 5000000) begin
            $display("[FAIL] T10 TIMEOUT");
            nfail = nfail + 1;
            ntest = ntest + 1;
        end else begin
            #1;
            ntest = ntest + 1;
            if (err === 8'h00) begin
                $display("[PASS] T10 k=n-1 err=0 r=%h.. s=%h..",
                         r_out[255:224], s_out[255:224]);
                npass = npass + 1;
            end else begin
                $display("[FAIL] T10 k=n-1 err=%h", err);
                nfail = nfail + 1;
            end
        end

        // =====================================================================
        // 汇总
        // =====================================================================
        $display("");
        $display("=============================================================");
        $display("Test Summary: ntest=%0d npass=%0d nfail=%0d",
                 ntest, npass, nfail);
        if (nfail == 0 && npass == ntest) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("SOME TESTS FAILED");
        end
        $display("=============================================================");
        $finish;
    end

    // =========================================================================
    // 看门狗: 全局超时保护
    // =========================================================================
    initial begin
        #100_000_000;   // 100ms 模拟时间
        $display("[WATCHDOG] Global timeout - simulation exceeded 100ms");
        $finish;
    end

endmodule
