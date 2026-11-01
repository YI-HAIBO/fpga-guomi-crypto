// =============================================================================
// 文件 : tb_sm3_sm2_pipe_b2.v
// 项目 : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 阶段 : Phase 0.5.4 B2 - SM3+SM2 签名流水线 (内部 TRNG 生成 k)
// 版本 : v1.0
// 日期 : 2026-10-04
// 视角 : sim-verifier
// 说明 : USE_INTERNAL_TRNG=1, k 由内部 trng_sm3 v2.0 生成
//        验证策略: e 确定性匹配, r/s 非零且 < n, err==0
// 运行 : iverilog -g2005 -Wall -I sim/sm2 -s tb_sm3_sm2_pipe_b2 \
//            rtl/trng/trng_sm3.v rtl/sm3/sm3_engine.v \
//            rtl/sm2/sm2_sign.v rtl/subsys/sm3_sm2_pipe.v \
//            sim/sm2/tb_sm3_sm2_pipe_b2.v -o /tmp/tb_sm3_sm2_pipe_b2.vvp
// =============================================================================

`timescale 1ns / 1ps

module tb_sm3_sm2_pipe_b2;

    // =========================================================================
    // 时钟与复位
    // =========================================================================
    reg clk;
    reg rst_n;

    always #5 clk = ~clk;   // 20ns period

    // =========================================================================
    // DUT 信号
    // =========================================================================
    reg          start;
    reg  [31:0]  msg_len;
    reg  [255:0] d_in;
    reg  [255:0] k_in;        // B2: 被忽略 (内部 TRNG 生成 k)
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
    // 引入测试向量 (复用 B1 的 E 值, SM3 哈希确定性)
    // =========================================================================
    `include "sm3_sm2_pipe_vectors.vh"

    // =========================================================================
    // SM2 曲线素数 n (用于 r/s 有效性检查)
    // =========================================================================
    localparam [255:0] NN = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123;

    // =========================================================================
    // DUT 实例化 (USE_INTERNAL_TRNG=1, K_MAX_RETRY=4)
    // =========================================================================
    sm3_sm2_pipe #(
        .K_MAX_RETRY       (4),
        .USE_INTERNAL_TRNG (1)
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
    // 任务辅助变量
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
    reg    [255:0] e_arg;
    reg    [7:0]   b8;
    reg    [255:0] k_gen;     // 内部生成的 k (通过层次引用读取)

    // =========================================================================
    // 任务: B2 端到端签名 (内部 TRNG 生成 k)
    // 验证: e 匹配, r/s 非零且 < n, err==0
    // =========================================================================
    task check_b2_sign;
        begin
            // 复位脉冲
            start    = 1'b0;
            msg_vld  = 1'b0;
            msg_data = 8'h00;
            rst_n    = 1'b0;
            @(posedge clk); @(posedge clk);
            rst_n    = 1'b1;
            @(posedge clk);

            // 启动
            @(posedge clk); #1;
            start    = 1'b1;
            @(posedge clk); #1;
            start    = 1'b0;

            cyc_start_t = $time;

            // 发送消息字节 (如果 L!=0)
            if (L_val_r != 0) begin
                for (i = 0; i < L_val_r; i = i + 1) begin
                    while (!msg_rdy) @(posedge clk);
                    #1;
                    b8       = (i * 7 + L_val_r * 3 + 0) & 8'hFF;
                    msg_data = b8;
                    msg_vld  = 1'b1;
                    @(posedge clk); #1;
                    msg_vld  = 1'b0;
                end
            end

            // 等待 done (带超时保护)
            timeout_cnt = 0;
            while (!done && timeout_cnt < 8000000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end

            #1;
            cyc_end_t = $time;
            cyc_total = (cyc_end_t - cyc_start_t) / 10;

            // 读取内部生成的 k (用于调试)
            k_gen = u_dut.k_buf;

            ntest = ntest + 1;

            if (timeout_cnt >= 8000000) begin
                $display("[FAIL] L=%0d TIMEOUT waiting for done", L_val_r);
                nfail = nfail + 1;
            end else if (err !== 8'h00) begin
                $display("[FAIL] L=%0d err=%h (expected 0)", L_val_r, err);
                nfail = nfail + 1;
            end else if (e_out !== e_arg) begin
                $display("[FAIL] L=%0d e mismatch\n  exp=%h\n  got=%h",
                         L_val_r, e_arg, e_out);
                nfail = nfail + 1;
            end else if (r_out == 256'd0 || r_out >= NN) begin
                $display("[FAIL] L=%0d r invalid r=%h", L_val_r, r_out);
                nfail = nfail + 1;
            end else if (s_out == 256'd0 || s_out >= NN) begin
                $display("[FAIL] L=%0d s invalid s=%h", L_val_r, s_out);
                nfail = nfail + 1;
            end else begin
                $display("[PASS] L=%0d cyc=%0d e=%h.. r=%h.. s=%h.. k=%h..",
                         L_val_r, cyc_total,
                         e_out[255:224], r_out[255:224], s_out[255:224],
                         k_gen[255:224]);
                npass = npass + 1;
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
        k_in     = 256'd0;   // B2: 被忽略

        ntest = 0;
        npass = 0;
        nfail = 0;

        $display("=============================================================");
        $display("SM3 + SM2 Pipeline Testbench (Phase 0.5.4 B2)");
        $display("USE_INTERNAL_TRNG=1, K_MAX_RETRY=4");
        $display("=============================================================");

        // =====================================================================
        // T1: 空消息 (msg_len=0)
        // =====================================================================
        $display("\n--- T1: Empty message (L=0) ---");
        msg_len = `VC_SIGN_L0000_LEN;
        d_in    = `VC_SIGN_L0000_D;
        e_arg   = `VC_SIGN_L0000_E;
        L_val_r = `VC_SIGN_L0000_LEN;
        check_b2_sign;

        // =====================================================================
        // T2: 单字节 (L=1)
        // =====================================================================
        $display("\n--- T2: Single byte (L=1) ---");
        msg_len = `VC_SIGN_L0001_LEN;
        d_in    = `VC_SIGN_L0001_D;
        e_arg   = `VC_SIGN_L0001_E;
        L_val_r = `VC_SIGN_L0001_LEN;
        check_b2_sign;

        // =====================================================================
        // T3: L=55 (1 块上边界)
        // =====================================================================
        $display("\n--- T3: L=55 (1 block, same-block end) ---");
        msg_len = `VC_SIGN_L0055_LEN;
        d_in    = `VC_SIGN_L0055_D;
        e_arg   = `VC_SIGN_L0055_E;
        L_val_r = `VC_SIGN_L0055_LEN;
        check_b2_sign;

        // =====================================================================
        // T4: L=56 (2 块下边界, 跨块填充)
        // =====================================================================
        $display("\n--- T4: L=56 (2 blocks, cross-block end) ---");
        msg_len = `VC_SIGN_L0056_LEN;
        d_in    = `VC_SIGN_L0056_D;
        e_arg   = `VC_SIGN_L0056_E;
        L_val_r = `VC_SIGN_L0056_LEN;
        check_b2_sign;

        // =====================================================================
        // T5: L=447 (8 块, byte_off==55 边界)
        // =====================================================================
        $display("\n--- T5: L=447 (8 blocks, byte_off==55) ---");
        msg_len = `VC_SIGN_L0447_LEN;
        d_in    = `VC_SIGN_L0447_D;
        e_arg   = `VC_SIGN_L0447_E;
        L_val_r = `VC_SIGN_L0447_LEN;
        check_b2_sign;

        // =====================================================================
        // T6: L=512 (8 块整)
        // =====================================================================
        $display("\n--- T6: L=512 (8 blocks exact) ---");
        msg_len = `VC_SIGN_L0512_LEN;
        d_in    = `VC_SIGN_L0512_D;
        e_arg   = `VC_SIGN_L0512_E;
        L_val_r = `VC_SIGN_L0512_LEN;
        check_b2_sign;

        // =====================================================================
        // T7: L=1024 (16 块整)
        // =====================================================================
        $display("\n--- T7: L=1024 (16 blocks exact) ---");
        msg_len = `VC_SIGN_L1024_LEN;
        d_in    = `VC_SIGN_L1024_D;
        e_arg   = `VC_SIGN_L1024_E;
        L_val_r = `VC_SIGN_L1024_LEN;
        check_b2_sign;

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
        #150_000_000;   // 150ms 模拟时间 (B2 含 TRNG 延迟, 预留余量)
        $display("[WATCHDOG] Global timeout - simulation exceeded 150ms");
        $finish;
    end

endmodule
