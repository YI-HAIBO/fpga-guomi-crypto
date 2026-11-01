// =============================================================================
// trng_health_test_v2.v
//
// TRNG 健康测试 (v2.0) — NIST SP 800-90B 四组独立统计检验
//
// 相对 v1.0 (trng_health_test) 的两项关键改动：
//   [1] 去掉 flush 端口：累加器跨请求连续累积，窗口满 1024 bit 才判定一次。
//       v1.0 的 flush = (state == S_IDLE) 使 128-bit 单块请求每次都被清空，
//       判定永不触发（E1 遗留 L1）。本模块彻底解耦请求边界与健康测试。
//   [2] 检验项由 2 项扩到 4 项，且四项在统计上相互独立：
//
//     T1 Proportion  SP 800-90B §4.5.1.2  chi-square(1)   比特比
//     T2 Poker       SP 800-90B §4.5.1.1  chi-square(15)  4-bit 块分布
//     T3 Correlation SP 800-90B §4.5.1.4                相邻比特相关
//     T4 Long runs                              精确 DP 分位  最长游程
//
// 阈值全部由 .workbuddy/tmp/ht_thresholds.py 计算（scipy.stats.chi2 99% 双侧
// 置信区间；T4 用公平序列最长游程分布的精确动态规划 99.99% 分位），并经
// 同文件内 8 类流 × 300 窗口的 Monte Carlo 交叉验证：
//   fair 99.0% 通过；biased/frozen/corr0/corr1/period2/period3/blocks
//   7 类退化流 0.0% 通过，且每类均被至少一项独立检验抓住。
//
// 判定量全部为纯整数运算（无除法、无浮点）：
//   T2 用增量式 sum(freq^2)：freq[j] 由 f 增到 f+1 时 sum_sq += 2f+1
//   （避免窗口末组合扇出 16 个乘法器 + 加法树）
//
// 接口与 v1.0 保持兼容（clk/rst_n/bit_in/bit_vld/pass/fail），可直接替换。
// 新增 win_pulse (窗口完成 1 拍脉冲) 与 status[3:0] 组合输出用于调试
// （bit3=T1 bit2=T2 bit1=T3 bit0=T4，1 = 本窗口该项通过）。
// status_win[3:0] 为窗口末锁存的判定结果：status 是组合量，win_last 当拍后
// 累加器即被清零，status 随即失效，故另设寄存器快照供 TB/主机可靠读取。
// =============================================================================
`timescale 1ns / 1ps

module trng_health_test_v2 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bit_in,
    input  wire        bit_vld,
    output reg         pass,      // 当前窗口整体通过
    output reg         fail,      // 曾失败（粘滞到 rst_n）
    output reg         win_pulse, // 每个窗口判定完成时 1 拍脉冲 (调试/计数用)
    output wire [3:0]  status,    // [3]proportion [2]poker [1]corr [0]longruns
    output reg [3:0]   status_win // 窗口末锁存的 status 快照 (win_last 当拍有效)
);

    // -------------------------------------------------------------------------
    // 窗口参数
    // -------------------------------------------------------------------------
    localparam integer WIN = 1024;   // 窗口长度 (bit)
    localparam integer NB  = 256;    // WIN/4, 4-bit 块数

    // -------------------------------------------------------------------------
    // 判定常量
    // 来源: .workbuddy/tmp/ht_thresholds.py (scipy.stats.chi2, 99% 双侧 CI)
    // -------------------------------------------------------------------------
    // T1 Proportion: X^2 = 4*(ones - N/2)^2 / N, chi-square(1) 99% CI
    localparam [10:0] ONES_LO  = 11'd468;
    localparam [10:0] ONES_HI  = 11'd556;
    // T2 Poker: X^2 = (16/n_b)*sum(freq^2) - n_b, chi-square(15) 99% CI
    //   => sum(freq^2) = (n_b/16)*(X^2 + n_b), n_b = 256
    localparam [20:0] SQ_LO    = 21'd4170;
    localparam [20:0] SQ_HI    = 21'd4620;
    // T3 Correlation: s = sum(b_i XOR b_{i+1}), E = (N-1)/2, sd = sqrt(N-1)/2
    //   取 4.2 sigma (统计 99% 为 1.96 sigma; 健康测试取严)
    localparam [10:0] CORR_LO  = 11'd444;
    localparam [10:0] CORR_HI  = 11'd579;
    // T4 Long runs: 精确 DP, P(R <= 23) = 0.99994 (99.99%)
    localparam [10:0] RUN_HI   = 11'd23;

    // -------------------------------------------------------------------------
    // 状态
    // -------------------------------------------------------------------------
    reg [10:0] bit_cnt;        // 0..WIN-1
    reg [10:0] ones;           // 窗口内 1 计数
    reg [20:0] sum_sq;         // sum(freq[i]^2), 增量更新
    reg [10:0] corr;           // sum(b_i XOR b_{i+1})
    reg [10:0] run_len;        // 当前游程长度
    reg [10:0] max_run;        // 窗口内最长游程
    reg [9:0]  freq [0:15];    // 4-bit 块频次 (max 256)
    reg [3:0]  blk;            // 当前 4-bit 块累加器 (MSB-first)
    reg [1:0]  blk_cnt;        // 块内位序 0..3
    // 注: 历史缺陷 (D1 T1 poker 只过的真正根因) -- 此处曾声明为 reg[2:0],
    //   3 位可表示 0..7, 使 blk_cnt 实际走 0,1,2,3,4,5,6,7 而非 0,1,2,3,
    //   blk_cnt==3 每 8 拍才命中一次 -> 每窗口只累积 128 个块而非 256,
    //   sum(freq^2) 跌到 ~1110 (远低于 SQ_LO=4170), t2_ok 恒为 0。
    //   iverilog 实证: 3 位计数器 +1 到 3 后继续走 4/7 而不回绕到 0。
    //   必须用 2 位并配 2'd 字面量, 与位序范围 0..3 严格一致。
    reg        prev_bit;
    reg        ever_fail;      // fail 粘滞

    // -------------------------------------------------------------------------
    // 组合: 本拍比特处理后的累加器候选值 (供窗口末判定, 避开 NBA 时序)
    // -------------------------------------------------------------------------
    wire [3:0]  blk_new = {blk[2:0], bit_in};
    wire [9:0]  f_cur   = freq[blk_new];                 // 提交前频次 (旧值)
    // 2f+1: freq[j] 由 f 增到 f+1 时 (f+1)^2 - f^2 = 2f+1。
    // 历史缺陷: 旧写法 {1'b0,f_cur,1'b0} + {10'd0,f_cur} + 11'd1 多算了 f_cur,
    //   实际得 3f+1, 使累加值退化为 (3*SUM(F^2)-256)/2 (公平流约 6172 而非 4200),
    //   恒落在 SQ_HI=4620 之上 -> t2_ok 永久为 0 (D1 T1 只过 3 项的根因)。
    // 位宽: f_cur 在 11 位上下文中零扩展后左移, 2*255+1=511, 11 位足够。
    wire [10:0] d_sq    = (f_cur << 1) + 11'd1;          // 2f+1

    wire [10:0] ones_n   = ones + {10'd0, bit_in};
    wire [10:0] corr_n   = (bit_cnt == 11'd0) ? corr
                                               : (corr + {10'd0, (bit_in ^ prev_bit)});
    wire [20:0] sq_n     = (blk_cnt == 2'd3) ? (sum_sq + d_sq) : sum_sq;
    wire [10:0] run_n    = (bit_cnt == 11'd0 || bit_in != prev_bit) ? 11'd1
                                                                     : (run_len + 11'd1);
    wire [10:0] maxrun_n = (run_n > max_run) ? run_n : max_run;

    // 注: 11'd(WIN-1) 这种"宽度+常量算术"写法 iverilog -g2005 不支持,
    //     须直接写字面量 (WIN 是 localparam 固定 1024, 改动 WIN 须同步此值)
    wire        win_last = (bit_cnt == 11'd1023);

    // 四项子判定 (1 = 通过)
    wire t1_ok = (ones_n   >= ONES_LO)   && (ones_n   <= ONES_HI);
    wire t2_ok = (sq_n     >= SQ_LO)     && (sq_n     <= SQ_HI);
    wire t3_ok = (corr_n   >= CORR_LO)   && (corr_n   <= CORR_HI);
    wire t4_ok = (maxrun_n <= RUN_HI);

    wire        ht_fail = !(t1_ok && t2_ok && t3_ok && t4_ok);

    assign status = {t1_ok, t2_ok, t3_ok, t4_ok};

    // -------------------------------------------------------------------------
    // 时序逻辑
    // -------------------------------------------------------------------------
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt   <= 11'd0;
            ones      <= 11'd0;
            sum_sq    <= 21'd0;
            corr      <= 11'd0;
            run_len   <= 11'd0;
            max_run   <= 11'd0;
            blk       <= 4'd0;
            blk_cnt   <= 2'd0;
            prev_bit  <= 1'b0;
            pass      <= 1'b1;
            fail      <= 1'b0;
            win_pulse <= 1'b0;
            ever_fail <= 1'b0;
            status_win<= 4'd0;
            for (i = 0; i < 16; i = i + 1) freq[i] <= 10'd0;
        end else begin
            // win_pulse: 严格 1 拍脉冲 (bit_vld=0 时也必须清零, 否则卡死在 1)
            win_pulse <= bit_vld & win_last;

            if (bit_vld) begin
                ones    <= win_last ? 11'd0   : ones_n;
                sum_sq  <= win_last ? 21'd0   : sq_n;
                corr    <= win_last ? 11'd0   : corr_n;
                run_len <= win_last ? 11'd0   : run_n;
                max_run <= win_last ? 11'd0   : maxrun_n;
                blk     <= win_last ? 4'd0    : blk_new;
                blk_cnt <= win_last ? 2'd0    : (blk_cnt + 2'd1);
                prev_bit<= bit_in;
                bit_cnt <= win_last ? 11'd0   : (bit_cnt + 11'd1);

                // T2 频次累加 (窗口末与清零冲突时以清零为准; sum_sq 已独立捕获增量)
                if (blk_cnt == 2'd3 && !win_last) begin
                    freq[blk_new] <= f_cur + 10'd1;
                end
                if (win_last) begin
                    for (i = 0; i < 16; i = i + 1) freq[i] <= 10'd0;
                end

                // 窗口判定: fail 粘滞, pass 反映本窗口, status_win 锁存本窗口快照
                if (win_last) begin
                    status_win <= status;
                    if (ht_fail) begin
                        fail <= 1'b1;
                        pass <= 1'b0;
                        ever_fail <= 1'b1;
                    end else begin
                        pass <= 1'b1;
                        if (!ever_fail) fail <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
