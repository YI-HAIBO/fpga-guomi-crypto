`timescale 1ns / 1ps
// =============================================================================
// 模块名称 : tb_scea_masked_v4_det_conf
// 用途     : SCEA trace 采集 testbench -- **保密初值掩码种子策略**版 (P0-6 修复后)
//
// 与 tb_scea_masked_v4_det.v 的唯一差异: seed_state 初值。
//   tb_scea_masked_v4_det.v : seed_state = 64'h9E3779B97F4A7C15 (公开常数,
//                             攻击者可从 RTL 推算 -> 一阶 CPA 4/4 恢复)
//   tb_scea_masked_v4_det_conf: seed_state = 由 SEED 参数派生的"设备保密"初值
//                             (攻击者无法从公开 RTL 推算 -> 相位穷举失效)
//
// 板级模型 (P0-6 修复后):
//   crypto_coord_subsys.v: mask_seed_init 由顶层注入 (每设备保密),
//   复位后 mask_seed_r = mask_seed_init (非零时), 此后每拍 xs64 推进。
//   本 TB 建模: seed_state 初始 = 派生保密值, 每次加密前推进 CYC_PER_ENC 拍。
//
// 攻击者模型: 攻击者掌握公开 RTL + xs64 算法, 但不知道 mask_seed_init。
//   phase-scan 只能从公开常数 SEED0 出发穷举相位 -> 无法命中真实种子序列。
//
// 输出: 与 tb_scea_masked_v4_det.v 完全相同的 trace dump 格式 + 种子旁录。
// =============================================================================
module tb_scea_masked_v4_det_conf #(
    parameter [127:0] KEY     = 128'h0123456789ABCDEFFEDCBA9876543210,
    parameter [127:0] PT_FIX  = 128'h0123456789ABCDEFFEDCBA9876543210,
    parameter         NSAMP_C = 72
);

    localparam NBYTE  = 4;
    localparam NNODE  = 2;
    localparam SH_W   = NNODE * NBYTE * 4;
    localparam NSAMP  = NSAMP_C * NNODE * NBYTE;
    localparam TRACE_W = NSAMP * 4;
    localparam KEPT   = TRACE_W - SH_W;

    // ---- 运行时参数 (plusargs 覆写) ----
    integer N_FIX, N_RND, SEED, CYC_PER_ENC;
    reg [128*8:1] OUTF;
    reg [128*8:1] SEEDF;

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
    function [63:0] xs64;
        input [63:0] x;
        reg   [63:0] t;
        begin
            t    = x ^ (x << 13);
            t    = t ^ (t >> 7);
            xs64 = t ^ (t << 17);
        end
    endfunction

    // ---- HW 函数 ----
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
    integer fd2;
    integer si;
    integer ci;
    reg     label = 2'd0;
    reg [127:0] ct_fix;

    // ---- 明文伪随机源 (与 tb_scea_masked_v4.v 同一种子/抽头) ----
    reg [31:0] lfsr = 32'd0;
    task rnd32;
        output [31:0] v;
        begin
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            v = lfsr;
        end
    endtask
    reg [31:0] r1, r2, r3, r4;

    // ---- 保密初值掩码种子状态 (P0-6 修复: 非公开常数) ----
    // 由 SEED 参数派生, 仿真 TB 注入; 攻击者无法从公开 RTL 推算。
    // 派生式: SEED 与固定异或量组合, 保证非零且与 SEED 相关但不可从
    // 公开常数 0x9E3779B97F4A7C15 直接推出。
    reg [63:0] seed_state = 64'h0;

    initial begin
        // ---- plusargs ----
        N_FIX = 500; N_RND = 500; SEED = 20261027;
        CYC_PER_ENC = NSAMP_C + 4;
        OUTF  = "scea_dump_masked_v4_det_conf.txt";
        SEEDF = "scea_dump_masked_v4_det_conf.seed.txt";
        if ($value$plusargs("N_FIX=%d", N_FIX))    ;
        if ($value$plusargs("N_RND=%d", N_RND))    ;
        if ($value$plusargs("SEED=%d", SEED))      ;
        if ($value$plusargs("CYC_PER_ENC=%d", CYC_PER_ENC)) ;
        if ($value$plusargs("OUTF=%s", OUTF))      ;
        if ($value$plusargs("SEEDF=%s", SEEDF))    ;

        // ---- 保密初值派生 (与公开常数无关) ----
        // 由 SEED 参数与固定异或量组合, 保证非零且与 SEED 相关,
        // 但攻击者无法从公开常数 0x9E3779B97F4A7C15 直接推出。
        seed_state = (64'hA5A5A5A5A5A5A5A5 ^ {32'd0, SEED[31:0]}
                      ^ 64'h9E3779B97F4A7C15) | 64'h1;

        ntot = N_FIX + N_RND;
        fd  = $fopen(OUTF);
        fd2 = $fopen(SEEDF);
        if (fd == 0 || fd2 == 0) begin
            $display("[ERR] cannot open %s / %s", OUTF, SEEDF);
            $finish;
        end
        lfsr = SEED[31:0] | 32'h00000001;
        for (bi = 0; bi < 64; bi = bi + 1) begin
            rnd32(r1);                              // warm up
        end
        $display("[INFO] KEY=%h", KEY);
        $display("[INFO] PT_FIX=%h N_FIX=%0d N_RND=%0d NSAMP_C=%0d TRACE_W=%0d",
                 PT_FIX, N_FIX, N_RND, NSAMP_C, TRACE_W);
        $display("[INFO] engine=sm4_engine_masked_v4 det-conf-seed (P0-6 fixed)");
        $display("[INFO] seed0=%h (confidential, NOT public)  CYC_PER_ENC=%0d",
                 seed_state, CYC_PER_ENC);

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
            // ---- 保密种子推进: 每次加密前推进 CYC_PER_ENC 拍 ----
            for (ci = 0; ci < CYC_PER_ENC; ci = ci + 1)
                seed_state = xs64(seed_state);
            mask_seed = seed_state;

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
            $fwrite(fd2, "S %0d %016X\n", bi, mask_seed);
            if (bi == 0 || bi == ntot - 1)
                $display("[DBG] bi=%0d pt=%h ct=%h seed=%h", bi, pt, result, mask_seed);
        end

        $fclose(fd);
        $fclose(fd2);
        $display("[INFO] dumped %0d traces -> %s (seeds -> %s)", ntot, OUTF, SEEDF);
        $display("[INFO] FIX pt=%h ct=%h", PT_FIX, ct_fix);
        if (ct_fix === 128'h681EDF34D206965E86B3E94F536E4246)
            $display("[xcheck] KAT PASS expect=681EDF34D206965E86B3E94F536E4246");
        else
            $display("[xcheck] KAT FAIL expect=681EDF34D206965E86B3E94F536E4246 got=%h",
                     ct_fix);
        $finish;
    end

    // ---- 全局超时 ----
    initial begin
        #80000000;
        $display("[ERR] TIMEOUT at bi=%0d", bi);
        $finish;
    end

endmodule