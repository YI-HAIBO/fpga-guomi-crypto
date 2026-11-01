// =============================================================================
// trng_monitor.v
//
// TRNG 健康监视前端 (free-running)
//
// 为什么需要这个模块
// ------------------
//   bar_ctrl.v 的 STATUS_TRNG / TRNG_ENTROPY_CNT 两个寄存器在 v1.5 已经定义好
//   接口, 但 pcie_front_subsys_v15.v 一直把 ht_status / entropy_cnt / trng_running
//   三个输入硬接常数 (7'd0 / 64'd0 / 1'b0), 而 trng_sm3 在整个板级网表里从未被
//   实例化。结果是:
//
//     STATUS_TRNG[7:1] = ~0 = 7'h7F  (七项检验全部 "FAIL")
//     TRNG_ENTROPY_CNT  = 0
//
//   即板级 all_ok / trng_ok 在结构上永远不可能置位, 绿灯不可达。
//
// 本模块做的事
// -------------
//   trng_entropy (trng_sm3.v:331)  ---1 bit/cycle-->  trng_health_test_v3
//                                                    (7 项 NIST SP 800-90B 检验,
//                                                     WIN = 1024 bit = 20.48 us @50MHz)
//
//   熵源 free-run (running 复位后默认 1), 因此健康测试从 rst_n 释放的那一刻起
//   就在跑, 不依赖主机先写 CTRL_TRNG:
//     - 首个窗口完成      = rst_n 释放后 1024 x 20 ns = 20.48 us
//     - probe 第一次读 0x044 = rst_n 释放后 ~82.6 us
//       (POR 65534x20ns + boot 4096x20ns + probe_step 3 步 x 8 拍 x 20ns)
//       => 读 0x044 之前已约完成 4 个窗口 (82.6/20.48), STATUS_TRNG 是"真实"读回。
//
//   CTRL_TRNG 的三条控制输出仍然接进来并生效:
//     i_start -> running = 1
//     i_stop  -> running = 0        (熵源停采, HT 窗口冻结在半窗)
//     i_flush -> 仅清 entropy_cnt  (trng_health_test_v3 无 flush 端口,
//                                    其累加器按设计跨请求连续累积)
//
// 熵比特选择
// -----------
//   trng_entropy 输出 4 位 mixed_bit = {lfsr[22], lfsr[15], timestamp[26],
//   jitter_reg[15]}, HT 只吃 bit_in = mixed_bit[0] = jitter_reg[15]
//   = lfsr[1] ^ timestamp[1]。
//
//   这不是随手选的: .workbuddy/tmp/entropy_ht_check.py 用 bit-exact Python 复刻
//   了 LFSR/timestamp/jitter 递推, 统计 2000 个连续 1024-bit 窗口的 7 项检验,
//   结果是 ALL 7 PASS = 1817/2000 = 90.850%, 且第 1 个窗口即 7/7 全通过。
//   结论: 熵源本身统计质量合格, 接线即可, 无需改熵源。
//
//   副作用与已记录的取舍: WIN=1024 下单项检验是 97.5%/95% 置信度, 健康源约 9%
//   的窗口会正常失败 (理论 1 - 0.975^5 x 0.95 = 8.84%, 实测 9.15%)。因此
//   STATUS_TRNG[7:1] 只能表达"上一个窗口"的瞬时状态, 不能当故障标志用;
//   板级判据必须用"曾经通过过完整窗口"这种单调语义 (见 gm_crypto_board_v15.v
//   step 3 注释)。这是数据, 不是本模块能修的。
//
// 面积预估
// ---------
//   trng_entropy        ~14 FF + 少量 LUT
//   trng_health_test_v3 <270 LUT (见该文件面积预算)
//   entropy_cnt         64 FF
//   合计增量 < 300 LUT, 相对 57026 Slice LUT 约 +0.5%。
//
// 编码铁律遵守
// ------------
//   - 无 wire 初值 (避免隐式连续驱动 -> 双驱动 -> X)
//   - 所有 always 块显式 (posedge clk or negedge rst_n)
//   - 字面量宽度精确 (7'd / 64'd)
//   - 不用 variable part-select, 不用 ^ 无括号优先级陷阱
//
// 接口
// ----
//   i_start / i_stop / i_flush : 来自 bar_ctrl 的 CTRL_TRNG (1 拍脉冲)
//   o_ht_status [6:0]          : ht_status_win, 与 trng_health_test_v3 位序一致
//                                 bit[0]=T4 LR  bit[1]=T3 Corr  bit[2]=T2 Poker
//                                 bit[3]=T1 Prop bit[4]=T5 Runs bit[5]=T6 CumSum
//                                 bit[6]=T7 BitDistBlk   (1 = 本窗口通过)
//                                 注意: 复位值 7'd0 => 首个窗口前 bar_ctrl 会把
//                                 STATUS_TRNG[7:1] 读成 7'h7F (全 FAIL), 这是
//                                 设计语义, 板级判据已避开该窗口。
//   o_trng_running             : running (STATUS_TRNG[0])
//   o_entropy_cnt [63:0]       : 已采样熵比特计数 (STATUS_TRNG 0x058/0x05C)
// =============================================================================
`timescale 1ns / 1ps

module trng_monitor (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 来自 bar_ctrl 的 CTRL_TRNG (0x030) 控制脉冲 ----
    input  wire        i_start,
    input  wire        i_stop,
    input  wire        i_flush,

    // ---- 健康回读 -> bar_ctrl ----
    output wire [6:0]  o_ht_status,
    output wire        o_trng_running,
    output wire [63:0] o_entropy_cnt
);

    // -------------------------------------------------------------------------
    // 运行使能
    // -------------------------------------------------------------------------
    // 复位后默认 1: 板子一上电熵源就跑, 不等主机下 CTRL_TRNG。这是 free-running
    // 监视器, 不是按需引擎 —— 见文件头"为什么需要这个模块"。
    reg running = 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            running <= 1'b1;
        else if (i_stop)
            running <= 1'b0;
        else if (i_start)
            running <= 1'b1;
    end

    // -------------------------------------------------------------------------
    // 熵源
    // -------------------------------------------------------------------------
    wire [3:0] ent_bit;
    wire       ent_vld;

    // req 由 running 门控, 而不是无条件 1'b1:
    //   running=0 时熵源停采, bit_vld 掉 0, HT 窗口冻结在半窗而不是继续用旧值
    //   凑满 1024 bit 去判一个"混合"窗口。
    trng_entropy u_entropy (
        .clk      (clk),
        .rst_n    (rst_n),
        .req      (running),
        .bit_out  (ent_bit),
        .bit_vld  (ent_vld)
    );

    // -------------------------------------------------------------------------
    // 健康测试 (NIST SP 800-90B 七检验, WIN = 1024)
    // -------------------------------------------------------------------------
    wire       ht_pass;
    wire       ht_fail;
    wire       ht_win_pulse;
    wire [6:0] ht_status_win;

    // bit_vld 也门控 running: 与 req 一致, 保证停采期间 HT 不前进。
    trng_health_test_v3 u_ht (
        .clk        (clk),
        .rst_n      (rst_n),
        .bit_in     (ent_bit[0]),
        .bit_vld    (ent_vld & running),
        .pass       (ht_pass),
        .fail       (ht_fail),
        .win_pulse  (ht_win_pulse),
        .status     (),          // 组合瞬时值, 不上报告 (含噪), 只取 status_win
        .status_win (ht_status_win)
    );

    // -------------------------------------------------------------------------
    // 熵比特计数 -> TRNG_ENTROPY_CNT (0x058 / 0x05C)
    // -------------------------------------------------------------------------
    reg [63:0] entropy_cnt = 64'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            entropy_cnt <= 64'd0;
        else if (i_flush)
            entropy_cnt <= 64'd0;
        else if (ent_vld)
            entropy_cnt <= entropy_cnt + 64'd1;
    end

    // -------------------------------------------------------------------------
    // 输出
    // -------------------------------------------------------------------------
    // 只接 status_win, 不接组合 status: status 是窗口中途的组合噪声, 上寄存器
    // 读到的是随机中间态; status_win 是窗口末锁存的快照, 才有诊断意义。
    assign o_ht_status    = ht_status_win;
    assign o_trng_running = running;
    assign o_entropy_cnt  = entropy_cnt;

    // 防止 lint 抱怨未用输出 (ht_pass/ht_fail/ht_win_pulse 保留给将来扩展,
    // 例如接一个"曾通过"粘滞灯)。
    wire _unused = ht_pass | ht_fail | ht_win_pulse;

endmodule
