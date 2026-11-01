`timescale 1ns / 1ps
// =============================================================================
// 模块名称 : tb_scea2_masked_v5
// 用途     : 二阶泄漏实验室验证专用采集 testbench -- v5.0 独立输出掩码引擎
//            (sm4_engine_masked_v4_indep, masked_en = 1, 每条 trace 新鲜 mask_seed)
//
// 与 tb_scea2_masked_v4 (v4.0) 的差异:
//   1. 引擎换为 sm4_engine_masked_v4_indep (v5.0: 逐字节独立输出掩码)
//   2. 探针节点完全相同 (t_in, tau_m), 保证 A/B 对照可比性
//   3. 预期结果: tau×tau 二阶通道关闭 (独立掩码 decorrelate 跨字节联合分布)
//
// 科学目标 (#156 二阶消除验证):
//   - v4.0: tau_m 字节间共享掩码 (实际为 0) -> tau×tau 二阶泄漏 (|t|=49.84, CPA 6/6)
//   - v5.0: tau_m 字节间独立掩码 -> 预期 tau×tau 二阶通道关闭
//   - 负对照: (t_in_i, t_in_j) / (t_in_i, tau_j) 应始终无泄漏 (掩码独立)
//
// 运行时配置 (plusargs, vvp -G 对 parameter 覆写实测无效):
//   +N_FIX=<n>  +N_RND=<n>  +SEED=<n>  +OUTF=<相对文件名, 写到 cwd>
//
// 编码     : Verilog-2005 (iverilog -g2005)
// =============================================================================

module tb_scea2_masked_v5 #(
    parameter [127:0] KEY     = 128'h0123456789ABCDEFFEDCBA9876543210,
    parameter [127:0] PT_FIX  = 128'h0123456789ABCDEFFEDCBA9876543210,
    parameter         N_FIX   = 20000,
    parameter         N_RND   = 20000,
    parameter         SEED    = 20261026,
    parameter         OUTF    = "scea2_dump_v5.txt"
);

    localparam S_IDLE  = 5'd0;
    localparam S_KEY   = 5'd1;
    localparam S_DATA  = 5'd2;

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

    sm4_engine_masked_v4_indep u_eng (
        .clk(clk), .rst_n(rst_n),
        .start(start), .key(KEY), .plaintext(pt),
        .decrypt(1'b0), .ciphertext(128'h0),
        .result(result), .done(done), .busy(busy),
        .masked_en(1'b1),
        .mask_seed(mask_seed)
    );

    // ---- 引擎状态 (定 round-0) ----
    wire [4:0]  fsm  = u_eng.fsm_state;
    wire [5:0]  blkc = u_eng.blk_cycle;
    wire is_round0 = (fsm == S_DATA) && (blkc == 6'd1);

    // ---- 节点 tap (掩码域, 与 v4.0 同节点定义, 保证 A/B 对照) ----
    wire [31:0] m_xors = u_eng.t_in;
    wire [31:0] m_tau  = u_eng.tau_m;

    // ---- HW 函数 (X/Z 按 0 计) ----
    function [3:0] hw8;
        input [7:0] x;
        integer i;
        begin
            hw8 = 4'd0;
            for (i = 0; i < 8; i = i + 1)
                hw8 = hw8 + (x[i] === 1'b1);
        end
    endfunction

    // ---- round-0 采样寄存器 (negedge 采样) ----
    reg [3:0] s00, s01, s02, s03;      // HW(t_in[31:24],[23:16],[15:8],[7:0])
    reg [3:0] s04, s05, s06, s07;      // HW(tau_m[31:24],...)
    reg       got_r0 = 1'b0;
    reg [7:0] n_r0   = 8'd0;

    always @(negedge clk) begin
        if (!rst_n) begin
            got_r0 <= 1'b0;
            n_r0   <= 8'd0;
        end else if (clr_trace) begin
            got_r0 <= 1'b0;
            n_r0   <= 8'd0;
        end else if (is_round0 && !got_r0) begin
            s00 <= hw8(m_xors[31:24]);  s01 <= hw8(m_xors[23:16]);
            s02 <= hw8(m_xors[15:8]);   s03 <= hw8(m_xors[7:0]);
            s04 <= hw8(m_tau[31:24]);   s05 <= hw8(m_tau[23:16]);
            s06 <= hw8(m_tau[15:8]);    s07 <= hw8(m_tau[7:0]);
            got_r0 <= 1'b1;
            n_r0   <= n_r0 + 8'd1;
        end
    end

    // ---- 驱动主循环 ----
    integer bi;
    integer ntot;
    integer fd;
    reg     label = 1'b0;
    reg     clr_trace = 1'b0;
    reg [127:0] ct_fix;
    integer n_err = 0;

    reg [255:0] outf;
    integer     nfix, nrnd, seedarg;

    // ---- 明文 LFSR ----
    reg [31:0] lfsr = 32'd0;
    task rnd32;
        output [31:0] v;
        begin
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            v = lfsr;
        end
    endtask
    // ---- 掩码种子专用 LFSR (独立) ----
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
        outf    = OUTF;
        nfix    = N_FIX;
        nrnd    = N_RND;
        seedarg = SEED;
        if ($value$plusargs("OUTF=%s",  outf)) ;
        if ($value$plusargs("N_FIX=%d", nfix)) ;
        if ($value$plusargs("N_RND=%d", nrnd)) ;
        if ($value$plusargs("SEED=%d",  seedarg)) ;
        ntot = nfix + nrnd;

        fd = $fopen(outf);
        if (fd == 0) begin
            $display("[ERR] cannot open %s", outf);
            $finish;
        end
        lfsr  = seedarg[31:0] | 32'h00000001;
        lfsr2 = ~seedarg[31:0] ^ 32'h6C078965;
        for (bi = 0; bi < 64; bi = bi + 1) begin
            rnd32(r1);  rnd32b(s_lo);
        end
        $display("[INFO] KEY=%h", KEY);
        $display("[INFO] PT_FIX=%h N_FIX=%0d N_RND=%0d", PT_FIX, nfix, nrnd);
        $display("[INFO] engine=sm4_engine_masked_v4_indep masked_en=1 round0-only capture");
        $display("[INFO] EXPECT: tau×tau 二阶通道关闭 (v5.0 独立逐字节掩码)");

        pt = 128'h0; start = 1'b0; mask_seed = 64'd0;
        clr_trace = 1'b0; label = 1'b0;
        rst_n = 1'b0;
        repeat (12) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        for (bi = 0; bi < ntot; bi = bi + 1) begin
            if (bi < nfix) begin
                pt = PT_FIX;
                label = 1'b0;
            end else begin
                rnd32(r1); rnd32(r2); rnd32(r3); rnd32(r4);
                pt = {r1, r2, r3, r4};
                label = 1'b1;
            end
            rnd32b(s_lo); rnd32b(s_hi);
            mask_seed = {s_hi, s_lo};

            clr_trace = 1'b1;
            start = 1'b0;
            @(posedge clk);
            clr_trace = 1'b0;
            start  = 1'b1;
            @(posedge clk);
            start  = 1'b0;
            repeat (64) @(posedge clk);

            if (!got_r0) begin
                $display("[ERR] bi=%0d: round0 not captured (fsm=%0d)", bi, fsm);
                n_err = n_err + 1;
            end else begin
                $fwrite(fd, "T %0d %0d %032X %0d %0d %0d %0d %0d %0d %0d %0d\n",
                        bi, label, pt,
                        s00, s01, s02, s03, s04, s05, s06, s07);
            end
            if (n_r0 !== 8'd1) begin
                $display("[ERR] bi=%0d: n_r0=%0d (expect 1)", bi, n_r0);
                n_err = n_err + 1;
            end
            if (bi == 0) ct_fix = result;
            if (bi == ntot - 1)
                $display("[DBG] last bi=%0d pt=%h ct=%h seed=%h",
                         bi, pt, result, mask_seed);
        end

        $fclose(fd);
        $display("[INFO] dumped %0d traces -> %s (errors=%0d)", ntot, outf, n_err);
        $display("[INFO] FIX pt=%h ct=%h expect=681EDF34D206965E86B3E94F536E4246",
                 PT_FIX, ct_fix);
        $finish;
    end

    // ---- 全局超时 ----
    initial begin
        #400000000;
        $display("[ERR] TIMEOUT at bi=%0d", bi);
        $finish;
    end

endmodule