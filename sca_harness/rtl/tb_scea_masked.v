`timescale 1ns / 1ps
// =============================================================================
// 模块名称 : tb_scea_masked
// 用途     : SCEA trace 采集 testbench -- 掩码引擎版 (sm4_engine_masked_v3,
//            masked_en = 1)。与 tb_scea.v 同构: 同功耗模型 / 同 8 节点布局 /
//            同输出格式, 以便 tvla_analyze.py / cpa_sm4.py 原样复用。
//
// 为什么单独一份而不用参数化 tb_scea.v:
//   两个引擎的端口集不同 (v3 多出 masked_en / sbox_mask_ext_* / sbox_*_tap /
//   sbox_*_valid), 且 S-box 抽头信号名不同:
//     未掩码 sm4_engine        : cipher_xors / cipher_tau
//     掩码   sm4_engine_masked : tmp / tau   (v3 的 tmp = X1^X2^X3^rk, tau = S(tmp))
//   两者语义等价 (tmp/cipher_xors 同为 S 盒输入字, tau/cipher_tau 同为输出字),
//   故 CPA 假设模型可完全复用。
//
// 科学目标:
//   v3 的"掩码表重计算"把掩码加在**查表地址**上:
//       tbl_src[i] = S(i ^ c)         (表内预存)
//       sbox_v2(x)  = tbl_src[x ^ c]  = S(x ^ c ^ c) = S(x)
//   即 S 盒**输出 tau 仍是未掩码的 S(x)**。掩码只扰乱地址域 (对抗总线/地址
//   泄漏), 未扰乱值域。若 HW(tau) 仍相关于明文+密钥, 则一阶 DPA 依然可攻破。
//   本 TB 采集 tau 与 tmp 的逐字节 HW, 交由 CPA 判定该防护是否真的生效。
//
// 功耗模型 (标准 HW model, 与 tb_scea.v 一致):
//   每周期 8 个样本 = 2 节点 x 4 字节:
//     节点 0..3 : HW(tmp[b])    S 盒输入字节
//     节点 4..7 : HW(tau[b])    S 盒输出字节  <- CPA 直接目标
//   逐字节采样而非整字: SM4 每轮 4 S-box 并联, 整字 HW 会把攻击字节 b 的信号
//   被另外 3 字节稀释 3/4 (实测相关性 0.39->0.19 掉档, 可能让错误 guess 胜出)。
//
// 输出格式 (文本, 每行一条 trace):
//   T <idx> <label> <pt_hex32> <v0> <v1> ... <vNSAMP-1>
//   label      : 0 = 固定明文组, 1 = 随机明文组
//   pt_hex32   : 128-bit 明文, 大端
//   v_i        : 十进制汉明权重 (0..8), 每周期 8 样本, 顺序
//                  [tmp0, tmp1, tmp2, tmp3, tau0, tau1, tau2, tau3]
//
// 注意: v3 引擎在 S_DATA 前有 S_KEY 阶段 (16 周期: 表刷新 + 密钥扩展),
//   未掩码引擎无此阶段, 故两者的轮 1 S-box 落在不同的采样偏移。CPA 全
//   采样点搜索, 不需预先对齐。
//
// 编码     : Verilog-2005 (iverilog -g2005)
// =============================================================================

module tb_scea_masked #(
    parameter [127:0] KEY     = 128'h0123456789ABCDEFFEDCBA9876543210,
    parameter [127:0] PT_FIX  = 128'h0123456789ABCDEFFEDCBA9876543210,
    parameter         N_FIX   = 500,
    parameter         N_RND   = 500,
    parameter         SEED    = 20261025,
    parameter         NSAMP_C = 72,
    parameter         OUTF    = "scea_dump_masked.txt"
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
    wire [127:0] result;
    wire         done;
    wire         busy;
    wire [7:0]   tap_addr;
    wire [7:0]   tap_c;

    sm4_engine_masked_v3 u_eng (
        .clk(clk), .rst_n(rst_n),
        .start(start), .key(KEY), .plaintext(pt),
        .decrypt(1'b0), .ciphertext(128'h0),
        .result(result), .done(done), .busy(busy),
        .masked_en(1'b1),
        .sbox_mask_ext_en(1'b0),
        .sbox_mask_c_ext(8'h00),
        .sbox_mask_tbl_ext({2048{1'b0}}),
        .sbox_addr_tap(tap_addr),
        .sbox_mask_c_tap(tap_c),
        .sbox_mask_valid(),
        .sbox_tbl_valid()
    );

    // ---- 节点 tap (层次引用) ----
    wire [31:0] m_xors = u_eng.tmp;
    wire [31:0] m_tau  = u_eng.tau;

    // ---- HW 函数 ----
    // 用 === 判 1: X/Z 位按 0 计。v3 的 tmp/tau 在 S_KEY 阶段尚未赋值 (X),
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
    reg [31:0] r1, r2, r3, r4;

    initial begin
        ntot = N_FIX + N_RND;
        fd = $fopen(OUTF);
        if (fd == 0) begin
            $display("[ERR] cannot open %s", OUTF);
            $finish;
        end
        lfsr = SEED[31:0] | 32'h00000001;
        for (bi = 0; bi < 64; bi = bi + 1) rnd32(r1);        // warm up
        $display("[INFO] KEY=%h", KEY);
        $display("[INFO] PT_FIX=%h N_FIX=%0d N_RND=%0d NSAMP_C=%0d TRACE_W=%0d",
                 PT_FIX, N_FIX, N_RND, NSAMP_C, TRACE_W);

        pt = 128'h0; start = 1'b0; cap_en = 1'b0; label = 2'd0;
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
                $display("[DBG] bi=%0d pt=%h ct=%h", bi, pt, result);
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
