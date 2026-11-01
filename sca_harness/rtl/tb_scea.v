`timescale 1ns / 1ps
// =============================================================================
// 模块名称 : tb_scea
// 用途     : 仿真侧信道评估 (SCEA) trace 采集 testbench -- 无外部设备时的
//            示波器替代方案。用 iverilog 仿真 SM4 引擎, 按 Hamming Weight
//            功耗模型逐周期提取中间值, 输出供 tvla_analyze.py / cpa_sm4.py
//            直接消费的数据集。
//
// 功耗模型 (标准 HW model, SCEA 文献通用):
//   每个采样周期记录 2 个监控节点 x 4 个字节的汉明权重 = 8 个样本
//     xors 字节 b: HW(cipher_xors[b*8+7 : b*8])  S 盒输入字节
//     tau  字节 b: HW(cipher_tau [b*8+7 : b*8])  S 盒输出字节 <- CPA 直接目标
//   采样点在时钟上升沿, 非阻塞赋值已在上一拍生效, 取到的是稳定组合值。
//   必须逐字节采而不是整字采: SM4 每轮 4 个 S-box 并联, 用整字 HW 会让
//   攻击 byte b 的信号被另外 3 字节稀释 3/4, 实测相关性 0.39->0.19 掉档
//   并可能让错误 guess 胜出 (见 docs/SCEA 报告)。
//
// 输出格式 (文本, 每行一条 trace):
//   T <idx> <label> <pt_hex32> <v0> <v1> ... <vNSAMP-1>
//   label      : 0 = 固定明文组, 1 = 随机明文组
//   pt_hex32   : 128-bit 明文, 大端 (与 tb_sm4_tvla / sm4_ref 一致)
//   v_i        : 十进制汉明权重 (0..8), i 从 0 递增 = 从最早周期到最新周期,
//                每周期 8 个样本, 顺序为
//                  [xors0, xors1, xors2, xors3, tau0, tau1, tau2, tau3]
//                即 sample[8k + b]    = HW(cipher_xors[b]) @ cycle k
//                     sample[8k + 4+b] = HW(cipher_tau [b]) @ cycle k
//                共 NSAMP = NSAMP_C*8 个样本。
//   注: 逐样本十进制而非整串 %h —— %h 在宽值含 X 位时会插入
//       'x'/'X' 填充字符, 导致解析失败。
//
// 编码     : Verilog-2005 (iverilog -g2005), 与项目其余 RTL 同规约
// =============================================================================

module tb_scea #(
    parameter [127:0] KEY     = 128'h0123456789ABCDEFFEDCBA9876543210,
    parameter [127:0] PT_FIX  = 128'h0123456789ABCDEFFEDCBA9876543210,
    parameter         N_FIX   = 500,
    parameter         N_RND   = 500,
    parameter         SEED    = 20261025,
    parameter         NSAMP_C = 72,
    parameter         OUTF    = "scea_dump.txt"
);

    localparam NBYTE  = 4;                        // 每个 32-bit 字拆 4 个字节
    localparam NNODE  = 2;                        // xors / tau
    localparam SH_W   = NNODE * NBYTE * 4;        // 每周期 8 个 HW 样本 x 4 bit
    localparam NSAMP  = NSAMP_C * NNODE * NBYTE;
    localparam TRACE_W = NSAMP * 4;
    localparam KEPT   = TRACE_W - SH_W;

    // ---- 时钟 / 复位 ----
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;              // 100 MHz, 与板卡 clk 一致

    // ---- DUT ----
    reg  [127:0] pt    = 128'h0;
    reg          start = 1'b0;
    wire [127:0] result;
    wire         done;
    wire         busy;

    sm4_engine u_eng (
        .clk(clk), .rst_n(rst_n),
        .start(start), .key(KEY), .plaintext(pt),
        .decrypt(1'b0), .ciphertext(128'h0),
        .result(result), .done(done), .busy(busy)
    );

    // ---- 节点 tap (层次引用, 仅 testbench 可见) ----
    wire [31:0] m_xors = u_eng.cipher_xors;
    wire [31:0] m_tau  = u_eng.cipher_tau;

    // ---- HW 函数 (先声明后使用) ----
    // 用 case 相等 (===) 判 1: X/Z 位按 0 计。物理上对应"未定义的中间值
    // 没有确定的开关活动", 且能让引擎尚未进入 S_DATA 的前几个填充周期
    // 输出确定值, 避免 trace 高位残留 X 导致解析失败。
    //
    // 逐字节采样 (hw8) 而非整字采样 (hw32): SM4 每轮 4 个 S-box 并联,
    // 攻击第 b 字节时若用整字 HW, 信号被另外 3 个字节的无关波动稀释 3/4,
    // 相关性从 ~1.0 掉到 ~0.4 并可能让错误 guess 胜出。
    function [3:0] hw8;
        input [7:0] x;
        integer i;
        begin
            hw8 = 4'd0;
            for (i = 0; i < 8; i = i + 1)
                hw8 = hw8 + (x[i] === 1'b1);
        end
    endfunction

    function [5:0] hw32;
        input [31:0] x;
        integer i;
        begin
            hw32 = 6'd0;
            for (i = 0; i < 32; i = i + 1)
                hw32 = hw32 + (x[i] === 1'b1);
        end
    endfunction

    // ---- 采样缓冲: 每周期左移 SH_W bit, 新样本进 LSB ----
    // 清零走 always 块的 clr 通路 (非阻塞), 避免 initial 块阻塞赋值与
    // always 块在宽寄存器上竞态残留 X 位。
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

    // ---- LFSR 伪随机源 (32-bit, 自同步; 替代 $srandom/$urandom 以兼容 -g2005) ----
    // 用 task 而非 function: iverilog -g2005 强制函数至少一个输入端口。
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
        lfsr = SEED[31:0] | 32'h00000001;   // 防零种子
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
            // 明文: 前 N_FIX 条用固定向量 (SM4 KAT), 其余用 $urandom
            if (bi < N_FIX) begin
                pt = PT_FIX;
                label = 2'd0;
            end else begin
                rnd32(r1); rnd32(r2); rnd32(r3); rnd32(r4);
                pt = {r1, r2, r3, r4};
                label = 2'd1;
            end

            // 清缓冲 (走 always 块 clr 通路) -> 拉 start 一拍 + 开始捕获 -> 等窗口填满
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

            // 逐样本以十进制输出。避免 %h 对宽值在含 X 位时
            // 插入 'x'/'X' 填充字符导致解析失败。
            // 必须用 $fwrite (带 fd); $write 不支持文件描述符, 会把 fd
            // 当成格式串里的一个整数值打印到 stdout。
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
