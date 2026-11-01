`timescale 1ns / 1ps
// =============================================================================
// 模块名称 : tb_scea_masked_v4_det
// 用途     : SCEA trace 采集 testbench -- **板级真实掩码种子策略**版 (#157)
//
// 与 tb_scea_masked_v4.v 的唯一差异: mask_seed 的来源。
//   tb_scea_masked_v4.v  : 每条 trace 由独立 LFSR 生成"新鲜随机"种子
//                          (建模"掩码来自 TRNG, 与明文统计独立")
//   tb_scea_masked_v4_det: 种子来自 **板级实际通路** ——
//                          rtl/subsys/crypto_coord_subsys.v L214-220:
//                             复位值 = 64'h9E3779B97F4A7C15 (黄金分割常数)
//                             此后 **每拍** mask_seed_r <= xs64(mask_seed_r)
//                          引擎在 start 拍锁存 mask_seed 的当前值, 故第 k 次
//                          加密的种子 = xs64^(N0 + k*C)(const), 其中 C 为相邻
//                          两次加密之间的时钟周期数 —— **完全确定性、可计算**。
//
// 攻击者模型: 攻击者掌握公开 RTL, 已知 xs64 算法与复位常数, 只需知道
//   (或遍历) 相位 N0 与步长 C, 即可逐条 trace 算出 mask_seed, 进而算出
//   mout8 = mask_seed[55:48] —— 而 v4 的 S 盒输出唯一保护就是 mout8:
//       addr   = t_in ^ comp = (X1^X2^X3^rk0) ^ {4{K}}      (输入掩码抵消)
//       tau_m  = tbl[addr]   = S(X1^X2^X3^rk0) ^ {4{mout8}}
//   故"掩码已知"时, 一阶 CPA 的模型与未掩码完全相同:
//       h = HW( SBOX[byte_b(X1^X2^X3) ^ g] ^ mout8 )
//
// 输出: 与 tb_scea_masked_v4.v 完全相同的 trace dump 格式 (便于
//   gen_scea_traces.py / tvla_analyze.py 原样复用), 另加一个种子旁录文件
//   (每行 "S <idx> <64-bit hex>"), 供 cpa_sm4_knownmask.py 使用。
//
// 参数仅 N_FIX/N_RND/SEED/OUTF/SEEDF/CYC_PER_ENC 走 $value$plusargs
//   (vvp -G 覆写实测无效; OUTF 只能传相对文件名, %s 会吞含 ':' 的盘符)。
// NSAMP_C 为编译期参数 (决定位宽), 不参与运行时覆写。
//
// 编码     : Verilog-2005 (iverilog -g2005)
// =============================================================================

module tb_scea_masked_v4_det #(
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

    // ---- 板级 xs64 (与 crypto_coord_subsys.v L204-212 逐位一致) ----
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

    // ---- 明文伪随机源 (与 tb_scea_masked_v4.v 同一种子/抽头, 两组明文一致) ----
    reg [31:0] lfsr = 32'd0;
    task rnd32;
        output [31:0] v;
        begin
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            v = lfsr;
        end
    endtask
    reg [31:0] r1, r2, r3, r4;

    // ---- 板级自由运行种子状态 (确定性, 非随机) ----
    reg [63:0] seed_state = 64'h9E3779B97F4A7C15;

    initial begin
        // ---- plusargs ----
        N_FIX = 500; N_RND = 500; SEED = 20261025;
        // 相邻两次加密之间的时钟数: 本 TB 每条约 1(clr)+1(start)
        //   +(NSAMP_C-1)(采样)+3(收尾) = NSAMP_C + 4 拍
        CYC_PER_ENC = NSAMP_C + 4;
        OUTF  = "scea_dump_masked_v4_det.txt";
        SEEDF = "scea_dump_masked_v4_det.seed.txt";
        if ($value$plusargs("N_FIX=%d", N_FIX))    ;
        if ($value$plusargs("N_RND=%d", N_RND))    ;
        if ($value$plusargs("SEED=%d", SEED))      ;
        if ($value$plusargs("CYC_PER_ENC=%d", CYC_PER_ENC)) ;
        if ($value$plusargs("OUTF=%s", OUTF))      ;
        if ($value$plusargs("SEEDF=%s", SEEDF))    ;

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
        $display("[INFO] engine=sm4_engine_masked_v4 det-seed (board-accurate)");
        $display("[INFO] seed0=%h  CYC_PER_ENC=%0d", seed_state, CYC_PER_ENC);

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
            // ---- 板级种子推进: 每次加密前推进 CYC_PER_ENC 拍 ----
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
