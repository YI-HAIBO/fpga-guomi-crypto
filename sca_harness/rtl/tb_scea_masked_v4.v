`timescale 1ns / 1ps
// =============================================================================
// 模块名称 : tb_scea_masked_v4
// 用途     : SCEA trace 采集 testbench -- v4 输出再掩码引擎版
//            (sm4_engine_masked_v4, masked_en = 1)。与 tb_scea.v /
//            tb_scea_masked.v 同构: 同功耗模型 / 同 8 节点布局 / 同输出格式,
//            以便 tvla_analyze.py / cpa_sm4.py 原样复用。
//
// 与 tb_scea_masked.v (v3 版) 的差异:
//   1. 实例化 sm4_engine_masked_v4 (端口: masked_en + mask_seed[63:0],
//      无 sbox_mask_ext_* / sbox_*_tap 端口)
//   2. 每条 trace 驱动**新鲜的 64-bit mask_seed** (rnd32 两次拼接),
//      对应 v4 微规格书 §3 "每条 trace 掩码一次性" 的攻击者模型
//   3. tap 改为 v4 的掩码域中间值:
//        节点 0..3 : HW(t_in[b])   S 盒输入字 (掩码域: tmp ^ min)
//        节点 4..7 : HW(tau_m[b])  S 盒输出字 (掩码域: tau ^ {4{mout8}})
//
// 科学目标:
//   v4 把 S 盒输入/输出都搬进掩码域。若一阶掩码成立, HW(t_in) / HW(tau_m)
//   应与 (明文, 密钥) 的任意函数统计独立:
//     TVLA  : max|t| < 4.5 (v3 实测 45.99, 未掩码 44.38)
//     CPA   : rk0 在 1000 条内不被恢复 (v3/未掩码 GE=1@N=25)
//
// 注意: mask_seed 在 start=1 的同一拍被 S_IDLE 采样, 故须在拉高 start
//   之前赋值。本 TB 在 clr 拍完成 seed 装载。
//
// 编码     : Verilog-2005 (iverilog -g2005)
// =============================================================================

module tb_scea_masked_v4 #(
    parameter [127:0] KEY     = 128'h0123456789ABCDEFFEDCBA9876543210,
    parameter [127:0] PT_FIX  = 128'h0123456789ABCDEFFEDCBA9876543210,
    parameter         N_FIX   = 500,
    parameter         N_RND   = 500,
    parameter         SEED    = 20261025,
    parameter         NSAMP_C = 72,
    parameter         OUTF    = "scea_dump_masked_v4.txt"
);

    localparam NBYTE  = 4;
    localparam NNODE  = 2;
    localparam SH_W   = NNODE * NBYTE * 4;
    localparam NSAMP  = NSAMP_C * NNODE * NBYTE;
    localparam TRACE_W = NSAMP * 4;
    localparam KEPT   = TRACE_W - SH_W;

    // ---- 时钟 / 复位 ----
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;              // 100 MHz

    // ---- DUT ----
    reg  [127:0] pt    = 128'h0;
    reg          start = 1'b0;
    reg  [63:0]  mask_seed = 64'd0;
    wire [127:0] result;
    wire         done;
    wire         busy;

    sm4_engine_masked_v4 u_eng (
        .clk(clk), .rst_n(rst_n),
        .start(start), .key(KEY), .plaintext(pt),
        .decrypt(1'b0), .ciphertext(128'h0),
        .result(result), .done(done), .busy(busy),
        .masked_en(1'b1),
        .mask_seed(mask_seed)
    );

    // ---- 节点 tap (层次引用, 均为掩码域) ----
    wire [31:0] m_xors = u_eng.t_in;
    wire [31:0] m_tau  = u_eng.tau_m;

    // ---- HW 函数 ----
    // 用 === 判 1: X/Z 位按 0 计。v4 的 t_in/tau_m 在 S_KEY 阶段尚未赋值 (X),
    // 按 0 处理对应"未定义中间值无确定开关活动", 且避免 trace 残留 X。
    function [3:0] hw8;
        input [7:0] x;
        integer i;
        begin
            hw8 = 4'd0;
            for (i = 0; i < 8; i = i + 1)
                hw8 = hw8 + (x[i] === 1'b1);
        end
    endfunction

    // ---- 采样缓冲 ----
    reg [TRACE_W-1:0] trace = {TRACE_W{1'b0}};
    reg [5:0]         cyc   = 6'd0;
    reg               cap_en = 1'b0;
    reg               clr = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            trace <= {TRACE_W{1'b0}};
            cyc   <= 6'd0;
        end else if (clr) begin
            trace <= {TRACE_W{1'b0}};
            cyc   <= 6'd0;
        end else if (cap_en) begin
            trace <= {trace[KEPT-1:0],
                      hw8(m_xors[31:24]), hw8(m_xors[23:16]),
                      hw8(m_xors[15:8]),  hw8(m_xors[7:0]),
                      hw8(m_tau[31:24]),  hw8(m_tau[23:16]),
                      hw8(m_tau[15:8]),   hw8(m_tau[7:0])};
            cyc   <= cyc + 6'd1;
        end
    end

    // ---- 驱动主循环 ----
    integer bi;
    integer ntot;
    integer fd;
    integer si;
    reg     label = 2'd0;
    reg [127:0] ct_fix;

    // ---- LFSR 伪随机源 (与 tb_scea.v 同种子, 两组 trace 明文完全一致) ----
    reg [31:0] lfsr = 32'd0;
    task rnd32;
        output [31:0] v;
        begin
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            v = lfsr;
        end
    endtask
    // ---- 掩码种子专用 LFSR: 与明文 LFSR 独立 (不同反馈抽头 + 不同种子)。
    //      若共用一条 LFSR, mask_seed 将是明文的确定性函数 —— 虽然攻击者仍
    //      无法利用, 但会在 CPA 的 GE 曲线上留下伪结构 (N<=500 时 true-byte
    //      偶尔 rank 1)。真实部署中掩码来自 TRNG, 与明文统计独立, 故这里
    //      用第二条 LFSR 显式建模该独立性。 ----
    reg [31:0] lfsr2 = 32'd0;
    task rnd32b;
        output [31:0] v;
        begin
            lfsr2 = {lfsr2[30:0], lfsr2[31] ^ lfsr2[19] ^ lfsr2[7] ^ lfsr2[2]};
            v = lfsr2;
        end
    endtask
    reg [31:0] r1, r2, r3, r4, s_lo, s_hi;

    initial begin
        ntot = N_FIX + N_RND;
        fd = $fopen(OUTF);
        if (fd == 0) begin
            $display("[ERR] cannot open %s", OUTF);
            $finish;
        end
        lfsr = SEED[31:0] | 32'h00000001;
        lfsr2 = ~SEED[31:0] ^ 32'h6C078965;      // 掩码 LFSR: 不同种子
        for (bi = 0; bi < 64; bi = bi + 1) begin
            rnd32(r1);
            rnd32b(s_lo);                          // warm up 两条 LFSR
        end
        $display("[INFO] KEY=%h", KEY);
        $display("[INFO] PT_FIX=%h N_FIX=%0d N_RND=%0d NSAMP_C=%0d TRACE_W=%0d",
                 PT_FIX, N_FIX, N_RND, NSAMP_C, TRACE_W);
        $display("[INFO] engine=sm4_engine_masked_v4 masked_en=1 fresh seed per trace");

        pt = 128'h0; start = 1'b0; cap_en = 1'b0; label = 2'd0;
        mask_seed = 64'd0;
        rst_n = 1'b0;
        repeat (12) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        for (bi = 0; bi < ntot; bi = bi + 1) begin
            if (bi < N_FIX) begin
                pt = PT_FIX;
                label = 2'd0;
            end else begin
                rnd32(r1); rnd32(r2); rnd32(r3); rnd32(r4);
                pt = {r1, r2, r3, r4};
                label = 2'd1;
            end
            // 每条 trace 新鲜掩码种子 (固定组也换, 模拟真实 RNG;
            //   独立 LFSR -> mask 与明文统计独立)
            rnd32b(s_lo); rnd32b(s_hi);
            mask_seed = {s_hi, s_lo};

            clr    = 1'b1;
            cap_en = 1'b0;
            start  = 1'b0;
            @(posedge clk);
            clr    = 1'b0;
            start  = 1'b1;
            cap_en = 1'b1;
            @(posedge clk);
            start  = 1'b0;
            repeat (NSAMP_C - 1) @(posedge clk);
            cap_en = 1'b0;
            repeat (3) @(posedge clk);

            if (bi == 0) ct_fix = result;

            $fwrite(fd, "T %0d %0d %032X", bi, label, pt);
            for (si = NSAMP - 1; si >= 0; si = si - 1)
                $fwrite(fd, " %0d", trace[si*4 +: 4]);
            $fwrite(fd, "\n");
            if (bi == 0 || bi == ntot - 1)
                $display("[DBG] bi=%0d pt=%h ct=%h seed=%h", bi, pt, result, mask_seed);
        end

        $fclose(fd);
        $display("[INFO] dumped %0d traces -> %s", ntot, OUTF);
        $display("[INFO] FIX pt=%h ct=%h", PT_FIX, ct_fix);
        $finish;
    end

    // ---- 全局超时 ----
    initial begin
        #80000000;
        $display("[ERR] TIMEOUT at bi=%0d", bi);
        $finish;
    end

endmodule
