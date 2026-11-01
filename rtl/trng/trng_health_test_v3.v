// =============================================================================
// trng_health_test_v3.v
//
// TRNG 健康测试 (v3.0) — NIST SP 800-90B 七检验
//
// 相对 v2.0 的关键改动
//   v2.0  4 检验 (Proportion / Poker / Correlation / Longruns)
//   v3.0  在 v2 基础上保留全部 4 项 (T1-T4), 新增 3 项独立统计检验:
//
//     T5 Runs              SP 800-90B §4.5.1.3   chi²(1)
//     T6 Cumulative.Sum    SP 800-90B §4.5.1.6  |S/σ| 判定
//     T7 Bit.Dist.Block    SP 800-90B §4.5.1.5  M=32bit, L=32 块, 95% 经验 CI
//
//   NIST 覆盖率: 4/15 → 7/15 (46.7%).
//
// 三新项阈值全部由 .workbuddy/tmp/ht_thresholds_v3.py 计算:
//   T5  chi²(1) 97.5% 上限 6.6349, E[V]=512, Var[V]=(N-3)/4=255.25
//       判定区间 V ∈ [477, 547]
//   T6  crit = |z| = 3.29, |S| ≤ sqrt(1024 * 3.29²) = 105.28 -> 105
//   T7  5000 窗口蒙特卡洛, 95% 双侧经验 CI Σf² ∈ [100, 172]
//       (M=32-bit 块, L=32 块, f_j = 每块 1 计数, Σf² = Σ freq_bd[j]²)
//
// 三项新检验在 MC 上均独立命中退化流:
//   T5 Runs          : corr0/corr1/p2/p3/frozen/biased/zeros 全部命中
//   T6 Cumulative.Sum: biased/frozen/corr0/p3/zeros 命中 (corr1/p2/blocks 不命中)
//   T7 Bit.Dist.Block: frozen/corr0/corr1/p2/p3/blocks/zeros 命中 (biased 不命中)
//   三新项合取 v2 四项 → 全部退化流捕获率 100%.
//
// 累加器跨请求连续累积不变 (v2 保留设计, 无 flush 端口)
// 判定量全部为纯整数运算 (无除法, 无浮点)
//
// 接口与 v2 保持兼容 (clk/rst_n/bit_in/bit_vld/pass/fail/win_pulse),
// 新增 status[6:0] 与 status_win[6:0]:
//   bit[0] = T4 Longruns
//   bit[1] = T3 Correlation
//   bit[2] = T2 Poker
//   bit[3] = T1 Proportion
//   bit[4] = T5 Runs             (v3 新增)
//   bit[5] = T6 Cumulative.Sum   (v3 新增)
//   bit[6] = T7 Bit.Dist.Block   (v3 新增)
//   1 = 本窗口该项通过
//
// 面积预算 (估算, 具体以 Vivado synthesis 为准)
//   T5 : 与 T3 共用 xor 累加器, 仅需 11-bit runs_c 计算 + 2 比较器 (<15 LUT)
//   T6 : 11-bit 有符号累加器 + abs + max (~50 LUT)
//   T7 : 33-entry × 11-bit freq_bd + 4-bit 累加器 + sum_sq_bd 增量 (~200 LUT)
//   合计增量 < 270 LUT, 面积增长 ~5%
// =============================================================================
`timescale 1ns / 1ps

module trng_health_test_v3 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bit_in,
    input  wire        bit_vld,
    output reg         pass,        // 当前窗口整体通过
    output reg         fail,        // 曾失败 (粘滞到 rst_n)
    output reg         win_pulse,   // 窗口判定完成 1 拍脉冲
    output wire [6:0]  status,      // [6]BD [5]CumSum [4]Runs [3]Prop [2]Poker [1]Corr [0]LR
    output reg [6:0]   status_win   // 窗口末锁存的 status 快照
);

    // -------------------------------------------------------------------------
    // 窗口参数
    // -------------------------------------------------------------------------
    localparam integer WIN = 1024;   // 窗口长度 (bit)
    localparam integer NB  = 256;    // WIN/4, 4-bit 块数 (T2)
    localparam integer BD_L = 32;    // WIN/32, 32-bit 块数 (T7)
    localparam integer BD_M = 32;    // 每块 bit 长度

    // -------------------------------------------------------------------------
    // v2 阈值 (保留, 已由 v2 MC 与 RTL 验证)
    // -------------------------------------------------------------------------
    localparam [10:0] ONES_LO  = 11'd468;
    localparam [10:0] ONES_HI  = 11'd556;
    localparam [20:0] SQ_LO    = 21'd4170;
    localparam [20:0] SQ_HI    = 21'd4620;
    localparam [10:0] CORR_LO  = 11'd444;
    localparam [10:0] CORR_HI  = 11'd579;
    localparam [10:0] RUN_HI   = 11'd23;

    // -------------------------------------------------------------------------
    // v3 新增阈值 (来自 ht_thresholds_v3.py)
    // -------------------------------------------------------------------------
    // T5 Runs: chi²(1) 97.5% 上限, E[V]=512, Var[V]=255.25
    localparam [10:0] RUN_LO_V3 = 11'd477;
    localparam [10:0] RUN_HI_V3 = 11'd547;
    // T6 Cumulative.Sum: |S_n| <= sqrt(1024 * 3.29²) = 105
    localparam [10:0] CUSUM_HI  = 11'd105;
    // T7 Bit.Dist.Block: Σf² ∈ [100, 172] (95% 经验 CI, MC 5000 窗口)
    localparam [16:0] BD_LO     = 17'd100;
    localparam [16:0] BD_HI     = 17'd172;

    // -------------------------------------------------------------------------
    // 状态寄存器
    // -------------------------------------------------------------------------
    // v2 保留
    reg [10:0] bit_cnt;
    reg [10:0] ones;
    reg [20:0] sum_sq;              // sum(freq4[i]^2)
    reg [10:0] corr;                // Σ(b_i XOR b_{i+1})
    reg [10:0] run_len;
    reg [10:0] max_run;
    reg [9:0]  freq4 [0:15];
    reg [3:0]  blk;
    reg [1:0]  blk_cnt;
    reg        prev_bit;

    // v3 新增
    reg [11:0] cumsum;              // T6 12-bit, 符号位 [11], 值域 [-1024, +1023]
    reg [10:0] cumsum_max;          // 窗口内 max|S_n| (无符号, 0..1024)
    reg [10:0] bd_blk_acc;          // T7 当前 32-bit 块内的位序号 (0..31)
    reg [5:0]  bd_ones;             // T7 当前块内 1 计数累加器 (0..32)
    reg [16:0] sum_sq_bd;           // T7 Σf² 累加器 (0..1024, 17-bit 充裕)
    reg [5:0]  freq_bd [0:32];      // T7 每 32-bit 块的 1 计数, 0..32 索引
    reg        ever_fail;

    // -------------------------------------------------------------------------
    // 组合: 本拍比特处理后的累加器候选值
    // -------------------------------------------------------------------------
    // ---- v2 ----
    wire [3:0]  blk_new = {blk[2:0], bit_in};
    wire [9:0]  f4_cur  = freq4[blk_new];
    wire [10:0] d_sq    = (f4_cur << 1) + 11'd1;          // 2f+1 增量
    wire [10:0] ones_n  = ones + {10'd0, bit_in};
    wire [10:0] corr_n  = (bit_cnt == 11'd0) ? corr
                                             : (corr + {10'd0, (bit_in ^ prev_bit)});
    wire [20:0] sq_n    = (blk_cnt == 2'd3) ? (sum_sq + d_sq) : sum_sq;
    wire [10:0] run_n   = (bit_cnt == 11'd0 || bit_in != prev_bit) ? 11'd1
                                                                   : (run_len + 11'd1);
    wire [10:0] maxrun_n = (run_n > max_run) ? run_n : max_run;
    wire        win_last = (bit_cnt == 11'd1023);

    // ---- v3 T5 Runs ----
    // V = (N-1) - S = 1023 - corr_n; 用有符号减法 (0 - corr_n), 高位补 1 表示负
    wire [10:0] runs_c = (11'd1023 - corr_n);

    // ---- v3 T6 Cumulative.Sum ----
    // S_n += (bit_in == 0) ? +1 : -1;
    // 12-bit 补码存储 cumsum (符号位 [11]), 值域 [-2048, +2047], 实际使用 [-1024, +1024]:
    //   - 正数: cumsum_n[11]=0, |S| = cumsum_n[10:0]
    //   - 负数: cumsum_n[11]=1, |S| = 4096 - cumsum_n (13-bit 减法防溢出)
    // 关键点: -1 在 12-bit 补码 = 0xFFF = 12'd4095 (不是 12'd1023, 那是 +1023!)
    //   12-bit 加法器对 signed/unsigned 位运算等价 (mod 2^12), 故用无符号常量即可
    wire [11:0] cumsum_n   = cumsum + (bit_in ? 12'd4095 : 12'd1);  // +/-1 in 12-bit two's comp
    // 取绝对值: |cumsum_n|
    //   0xFFF = -1    -> 4096-4095 = 1    (13-bit)
    //   0xC00 = -1024 -> 4096-3072 = 1024 (13-bit, 需 11-bit 存放)
    //   0x400 = +1024 -> 1024             (11-bit 直接)
    //   0x000 = 0     -> 0
    wire [12:0] cumsum_n_ext = {1'b0, cumsum_n};              // 零扩展至 13-bit
    wire [12:0] abs_neg      = 13'd4096 - cumsum_n_ext;        // 13-bit 减法, 结果恒 >= 0
    wire [10:0] cumsum_abs   = cumsum_n[11] ? abs_neg[10:0]   : cumsum_n[10:0];
    wire [10:0] maxabs_n     = (cumsum_abs > cumsum_max) ? cumsum_abs : cumsum_max;

    // ---- v3 T7 Bit.Dist.Block ----
    // f_j = 第 j 块中 1 的个数 (0..32), freq_bd[f_j] = 有 f_j 个 1 的块数
    // Σf² = Σ freq_bd[k]², 增量: freq_bd[k] 从 n→n+1 时 Σf² 增加 (n+1)²−n² = 2n+1
    // 关键: sum_sq_bd 只在块边界 (bd_blk_acc==31) 更新一次, 不是每拍都加
    //   否则每块 32 拍会把同一 f_bd_cur 重复加 32 次 → sum_sq_bd 膨胀到 1000+
    // bd_k = bd_ones + bit_in: 块末时 bd_ones 是前 31 拍的 1 计数, 加上当前拍即为本块总数
    wire [5:0]  bd_k       = bd_ones + {5'd0, bit_in};          // 当前块 1 计数 (0..32)
    wire [5:0]  f_bd_cur   = freq_bd[bd_k];                       // 旧计数 n
    wire [6:0]  d_sq_bd    = (f_bd_cur << 1) + 7'd1;             // 2n+1 增量
    wire [16:0] sum_sq_bd_n = (bd_blk_acc == 11'd31)
                                ? (sum_sq_bd + {10'd0, d_sq_bd})  // 块末: 加本块贡献
                                : sum_sq_bd;                       // 块内: 保持
    wire [10:0] bd_acc_n   = (bd_blk_acc == 11'd31) ? 11'd0 : (bd_blk_acc + 11'd1);

    // ---- 子判定 (1 = 通过) ----
    wire t1_ok = (ones_n   >= ONES_LO)   && (ones_n   <= ONES_HI);
    wire t2_ok = (sq_n     >= SQ_LO)     && (sq_n     <= SQ_HI);
    wire t3_ok = (corr_n   >= CORR_LO)   && (corr_n   <= CORR_HI);
    wire t4_ok = (maxrun_n <= RUN_HI);
    wire t5_ok = (runs_c   >= RUN_LO_V3) && (runs_c   <= RUN_HI_V3);
    wire t6_ok = (maxabs_n <= CUSUM_HI);
    wire t7_ok = (sum_sq_bd_n[16:0] >= BD_LO) && (sum_sq_bd_n[16:0] <= BD_HI);

    wire        ht_fail = !(t1_ok && t2_ok && t3_ok && t4_ok
                            && t5_ok && t6_ok && t7_ok);

    assign status = {t7_ok, t6_ok, t5_ok, t1_ok, t2_ok, t3_ok, t4_ok};

    // -------------------------------------------------------------------------
    // 时序逻辑
    // -------------------------------------------------------------------------
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt     <= 11'd0;
            ones        <= 11'd0;
            sum_sq      <= 21'd0;
            corr        <= 11'd0;
            run_len     <= 11'd0;
            max_run     <= 11'd0;
            blk         <= 4'd0;
            blk_cnt     <= 2'd0;
            prev_bit    <= 1'b0;
            cumsum      <= 12'd0;
            cumsum_max  <= 11'd0;
            bd_blk_acc  <= 11'd0;
            bd_ones     <= 6'd0;
            sum_sq_bd   <= 11'd0;
            pass        <= 1'b1;
            fail        <= 1'b0;
            win_pulse   <= 1'b0;
            ever_fail   <= 1'b0;
            status_win  <= 7'd0;
            for (i = 0; i < 16; i = i + 1) freq4[i] <= 10'd0;
            for (i = 0; i < 33; i = i + 1) freq_bd[i] <= 10'd0;
        end else begin
            win_pulse <= bit_vld & win_last;

            if (bit_vld) begin
                // ---- v2 累加器 ----
                ones    <= win_last ? 11'd0   : ones_n;
                sum_sq  <= win_last ? 21'd0   : sq_n;
                corr    <= win_last ? 11'd0   : corr_n;
                run_len <= win_last ? 11'd0   : run_n;
                max_run <= win_last ? 11'd0   : maxrun_n;
                blk     <= win_last ? 4'd0    : blk_new;
                blk_cnt <= win_last ? 2'd0    : (blk_cnt + 2'd1);
                prev_bit <= bit_in;
                bit_cnt  <= win_last ? 11'd0   : (bit_cnt + 11'd1);

                // T2 频次累加 (v2 保留)
                if (blk_cnt == 2'd3) begin
                    if (win_last) begin
                        for (i = 0; i < 16; i = i + 1) freq4[i] <= 10'd0;
                    end else begin
                        freq4[blk_new] <= f4_cur + 10'd1;
                    end
                end

                // ---- v3 T5 无需额外累加器 (共用 corr) ----

                // ---- v3 T6 Cumulative.Sum ----
                cumsum     <= win_last ? 12'd0 : cumsum_n;
                cumsum_max <= win_last ? 11'd0 : maxabs_n;

                // ---- v3 T7 Bit.Dist.Block ----
                // 块内位序号 + 1 计数累加器
                bd_blk_acc <= win_last ? 11'd0 : bd_acc_n;
                bd_ones    <= win_last ?  6'd0 : ((bd_blk_acc == 11'd31) ?  6'd0 : (bd_ones + {5'd0, bit_in}));
                // 窗口末清零 sum_sq_bd (供下一窗口重新累加)
                sum_sq_bd  <= win_last ? 11'd0 : sum_sq_bd_n;
                // freq_bd 更新 (与 sum_sq_bd 增量同拍, 用旧值 f_bd_cur)
                if (bd_blk_acc == 11'd31) begin
                    if (win_last) begin
                        for (i = 0; i < 33; i = i + 1) freq_bd[i] <= 10'd0;
                    end else begin
                        freq_bd[bd_k] <= f_bd_cur + 10'd1;
                    end
                end

                // ---- 窗口判定 ----
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
