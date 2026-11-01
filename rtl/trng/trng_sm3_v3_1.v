// =============================================================================
// 模块名称 : trng
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v3.1 (物理熵源 + NIST SP 800-90B 健康测试, L5 修复: RO 参数重选)
// 日期     : 2026-10-04
// 视角     : rtl-designer
// 功能     : 硬件真随机数发生器, 符合 GB/T 32905-2016 简化版本
//           包含: 熵源 (三路自由运行环形振荡器)、健康测试、SM3 哈希 DRBG 后处理
// 时钟     : clk = 100 MHz (功能仿真)
// 输出接口 : vld/rdy 握手, 128-bit 随机数数据
//
// v3.0 变更 (修复 v2.0 阻断性缺陷 E1):
//   - trng_entropy 由「固定种子 23 位 LFSR + 时间戳 + jitter 寄存器」替换为
//     「三路自由运行环形振荡器 (ro13 / ro9 / ro3) + clk 相位采样 + 三路异或」
//   - v2.0 缺陷机理: 熵源全部状态由复位值初始化 (LFSR 23'h001_C001 /
//     timestamp 27'd0 / jitter_reg 16'h0000), 无物理熵源, 输出完全由
//     「复位到首次采样的周期数」决定 -> 同一复位必然得到同一 k, 同一私钥下
//     两次 k 重复可由 (s1-s2)/(r1-r2) mod n 恢复私钥
//   - v3.0 修复: 环形振荡器不受 rst_n 复位, 相位是绝对时间 (上电以来) 的
//     函数, 硅上由工艺/电压/温度决定, 无法通过复位复现
//   - 熵源接口 (clk/rst_n/req/bit_out[3:0]/bit_vld) 与 v2.0 完全一致,
//     原位替换; 顶层 trng 端口、状态机、SM3 DRBG、健康测试均与 v2.0 一致
//   - RO 组参数 (已 60000 样本仿真验收): ro13 DELAY=785 / ro9 DELAY=1133 /
//     ro3 DELAY=3399, 环长 T_L = 10205 / 10197 / 10197 ps, alpha 约 0.49;
//     max_run=3, ones4096=2026..2058, 无 256-bit 重复, anti-E1 8/8 互异,
//     相位鲁棒性 20/20 通过
//   - RO 延迟写法必须是 `s1 <= #DELAY ~s0` (非阻塞+后置延迟); `#DELAY s1=~s0`
//     会因到期求值导致跃迁栅格错开, `c0=s0; #DELAY s1=~c0` 会因模块级捕获
//     寄存器竞争而完全死锁。详见 entropy 模块头部注释
//
//
// v3.1 变更 (路线图 D1: TRNG 健康测试强化, 收口 E1 遗留 L1):
//   - 健康测试由 trng_health_test (v1: 2 项, flush=S_IDLE) 替换为
//     trng_health_test_v2 (NIST SP 800-90B 四组独立检验, 无 flush)
//   - L1 根因: v1 的 flush = (state == S_IDLE) 使累加器每个空闲拍都被清空,
//     128-bit 单块请求一次仅累积 128 位, 窗口 4096 永不满足 -> 判定永不触发,
//     max_run<=10 无法由片上测试证明。v2 去掉 flush 端口, 累加器跨请求连续
//     累积, 窗口满 1024 bit 才判定一次, 与请求边界彻底解耦
//   - 检验项 2 -> 4, 且统计独立:
//       T1 Proportion  (SP 800-90B 4.5.1.2, chi-square 1)  比特比
//       T2 Poker       (SP 800-90B 4.5.1.1, chi-square 15) 4-bit 块分布
//       T3 Correlation (SP 800-90B 4.5.1.4)                相邻比特相关
//       T4 Long runs                                   最长游程
//   - 阈值由 .workbuddy/tmp/ht_thresholds.py 计算 (scipy.stats.chi2 99% 双侧
//     置信区间; T4 用公平序列最长游程分布的精确动态规划 99.99% 分位), 并经
//     8 类流 x 300 窗口 Monte Carlo 交叉验证: fair 99.0% 通过, 7 类退化流
//     (偏置/冻结/正相关/反相关/周期2/周期3/定值块) 0.0% 通过
//   - 顶层端口、状态机、RO 熵源、SM3 DRBG 与 v3.0 完全一致
//
// 健康测试契约:
//   pass  - 当前窗口四项全部通过
//   fail  - 曾失败, 粘滞到 rst_n (fail 一旦置 1 不再清零)
//   status[3:0] - [3]proportion [2]poker [1]correlation [0]longruns, 1=通过
//   窗口 1024 bit; 阈值见 trng_health_test_v2.v 头部
//   注: fail 粘滞意味着一次退化流即可锁定 fail, 生产环境应在 err_code 上报后
//       复位整个 TRNG 而非仅清 fail
//
// 与 v2.0 的关系: 模块名同为 trng, 编译期二选一, 不可同编译
//   基线: rtl/trng/trng_sm3.v      (v2.0, 回归对照)
//   物理熵源: rtl/trng/trng_sm3_v3.v   (v3.0)
//   新版: rtl/trng/trng_sm3_v3_1.v     (v3.1 = v3.0 + D1 健康测试, 默认)
//   签核: docs/Phase0_5_4_E1_物理熵源模块级签核_v1.md
//         docs/Phase0_5_D1_TRNG健康测试强化模块级签核_v1.md
//
// 状态机:
//   S_IDLE -> S_REQUEST -> S_SAMPLE -> S_HT -> S_PROCESS -> S_HASH_WAIT
//          -> S_OUTPUT -> S_DONE -> S_IDLE
//          -> S_ERROR -> S_IDLE
// =============================================================================
`timescale 1ns / 1ps

module trng (
    // 时钟与复位
    input  wire         clk,
    input  wire         rst_n,

    // 请求接口
    input  wire         req_vld,
    output wire         req_rdy,
    input  wire [7:0]   req_bytes,

    // 响应接口
    output wire         data_vld,
    input  wire         data_rdy,
    output wire [127:0] data_out,
    output wire         data_last,

    // 状态与错误
    output wire         busy,
    output wire         done,
    output wire [7:0]   err_code
);

    // =========================================================================
    // 内部状态机
    // =========================================================================
    localparam [3:0] S_IDLE      = 4'd0;
    localparam [3:0] S_REQUEST   = 4'd1;
    localparam [3:0] S_SAMPLE    = 4'd2;
    localparam [3:0] S_HT        = 4'd3;
    localparam [3:0] S_PROCESS   = 4'd4;
    localparam [3:0] S_HASH_WAIT = 4'd5;   // v2.0 新增: 等待 SM3 DRBG
    localparam [3:0] S_OUTPUT    = 4'd6;
    localparam [3:0] S_DONE      = 4'd7;
    localparam [3:0] S_ERROR     = 4'd8;

    reg  [3:0] state;
    reg  [3:0] next_state;

    // 请求参数
    reg  [7:0]  bytes_req;
    reg  [7:0]  bytes_done;

    // 熵源采样
    reg  [127:0] entropy_buf;
    reg  [6:0]   bit_cnt;

    // 健康测试寄存器
    reg          ht_pass;

    // =========================================================================
    // 子模块实例化
    // =========================================================================

    // --- 熵源 ---
    wire [3:0]  entropy_bit;
    wire        entropy_vld;

    trng_entropy u_entropy (
        .clk       (clk),
        .rst_n     (rst_n),
        .req       (state == S_SAMPLE),
        .bit_out   (entropy_bit),
        .bit_vld   (entropy_vld)
    );

    // --- 健康测试 (v2: NIST SP 800-90B 四组检验, 跨请求连续累积) ---
    wire        ht_ok;
    wire        ht_fail;
    wire [3:0]  ht_status;

    trng_health_test_v2 u_ht (
        .clk       (clk),
        .rst_n     (rst_n),
        .bit_in    (entropy_bit[0]),
        .bit_vld   (entropy_vld),
        .pass      (ht_ok),
        .fail      (ht_fail),
        .status    (ht_status)
    );

    // --- SM3 哈希 DRBG (v2.0: 替换原 trng_drbg) ---
    wire [127:0] drbg_out;
    wire         drbg_out_vld;

    sm3_drbg u_drbg (
        .clk       (clk),
        .rst_n     (rst_n),
        .seed_vld  (state == S_PROCESS && bit_cnt == 7'd0),
        .seed_in   (entropy_buf),
        .req       (1'b0),
        .out       (drbg_out),
        .out_vld   (drbg_out_vld)
    );

    // =========================================================================
    // 状态机主逻辑
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            bytes_req  <= 8'd0;
            bytes_done <= 8'd0;
            entropy_buf<= 128'd0;
            bit_cnt    <= 7'd0;
            ht_pass    <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (req_vld) begin
                        state      <= S_REQUEST;
                        bytes_req  <= req_bytes;
                        bytes_done <= 8'd0;
                        bit_cnt    <= 7'd0;
                    end
                end

                S_REQUEST: begin
                    bit_cnt     <= 7'd0;
                    entropy_buf <= 128'd0;
                    state       <= S_SAMPLE;
                end

                S_SAMPLE: begin
                    if (entropy_vld) begin
                        entropy_buf <= {entropy_buf[126:0], entropy_bit[0]};
                        bit_cnt     <= bit_cnt + 7'd1;
                        if (bit_cnt == 7'd127) begin
                            state <= S_HT;
                        end
                    end
                end

                S_HT: begin
                    if (ht_fail) begin
                        state   <= S_ERROR;
                        ht_pass <= 1'b0;
                    end else begin
                        ht_pass <= 1'b1;
                        state   <= S_PROCESS;
                    end
                end

                S_PROCESS: begin
                    // 触发 DRBG 种子 (seed_vld 组合逻辑已断言)
                    state <= S_HASH_WAIT;
                end

                S_HASH_WAIT: begin
                    // 等待 SM3 DRBG 输出就绪 (v2.0 新增)
                    if (drbg_out_vld) begin
                        state <= S_OUTPUT;
                    end
                end

                S_OUTPUT: begin
                    // v2.0: 单块交付, 1 cycle 后自动完成 (简化握手)
                    state <= S_DONE;
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                S_ERROR: begin
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

    // =========================================================================
    // 输出逻辑
    // =========================================================================
    assign req_rdy   = (state == S_IDLE);
    assign busy      = (state != S_IDLE) && (state != S_DONE);
    assign done      = (state == S_DONE);
    assign err_code  = (state == S_ERROR) ? 8'h01 : 8'h00;

    assign data_vld  = (state == S_OUTPUT);
    assign data_out  = drbg_out;
    assign data_last = data_vld && (bytes_done + 8'd1 >= bytes_req);

endmodule


// =============================================================================
// 子模块: SM3 哈希 DRBG (v2.0 新增)
// 基于 SP 800-90A 计数器模式, 使用 SM3 哈希作为 PRF
// 修复 v1.0 trng_drbg 的"前 3 字重复"缺陷
// =============================================================================
module sm3_drbg (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        seed_vld,
    input  wire [127:0] seed_in,
    input  wire        req,       // 保留接口兼容, v2.0 不使用
    output wire [127:0] out,
    output wire        out_vld
);

    // =========================================================================
    // SM3 IV (GB/T 32905-2016)
    // =========================================================================
    localparam [255:0] IV = 256'h7380166f4914b2b9172442d7da8a0600a96f30bc163138aae38dee4db0fb0e4e;

    // =========================================================================
    // SM3 引擎实例
    // =========================================================================
    wire         sm3_start;
    wire [511:0] sm3_msg;
    wire [255:0] sm3_prev;
    wire [255:0] sm3_out;
    wire         sm3_done;
    wire         sm3_busy;

    sm3_engine u_sm3 (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (sm3_start),
        .msg_block   (sm3_msg),
        .prev_state  (sm3_prev),
        .out_state   (sm3_out),
        .done        (sm3_done),
        .busy        (sm3_busy)
    );

    // =========================================================================
    // 内部状态
    // =========================================================================
    reg  [255:0] v_state;    // DRBG 状态 V (256-bit)
    reg  [127:0] seed_buf;   // 种子缓冲
    reg  [31:0]  counter;    // 计数器 C
    reg  [127:0] out_reg;    // 输出寄存器
    reg          out_vld_reg;
    reg          has_seed;   // 已初始化标志
    reg  [1:0]   state;

    localparam S_IDLE = 2'd0;
    localparam S_HASH = 2'd1;

    // =========================================================================
    // 消息块构造
    // 种子模式: {seed_buf(128), counter(32), 352'd0}
    // 后续模式: {v_state(256), counter(32), 224'd0}
    // =========================================================================
    wire [511:0] msg_seed  = {seed_buf, counter, 352'd0};
    wire [511:0] msg_state = {v_state, counter, 224'd0};
    assign sm3_msg  = has_seed ? msg_state : msg_seed;
    assign sm3_prev = has_seed ? v_state : IV;

    // SM3 启动: 仅在 S_HASH 且 SM3 空闲时
    assign sm3_start = (state == S_HASH) && !sm3_busy;

    // =========================================================================
    // FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            v_state    <= IV;
            seed_buf   <= 128'd0;
            counter    <= 32'd0;
            out_reg    <= 128'd0;
            out_vld_reg<= 1'b0;
            has_seed   <= 1'b0;
        end else begin
            out_vld_reg <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (seed_vld) begin
                        seed_buf <= seed_in;
                        counter  <= 32'd0;
                        has_seed <= 1'b0;
                        state    <= S_HASH;
                    end
                end

                S_HASH: begin
                    if (sm3_done) begin
                        v_state     <= sm3_out;
                        out_reg     <= sm3_out[255:128];
                        out_vld_reg <= 1'b1;
                        has_seed    <= 1'b1;
                        state       <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign out     = out_reg;
    assign out_vld = out_vld_reg;

endmodule


// =============================================================================
// 子模块: 环形振荡器 ro3 / ro9 / ro13 —— 自由运行, 异步时钟域 (v3.0 新增)
//
// #DELAY 是门延迟的仿真模型 (单位 ps), 综合时忽略; 硅上周期由实际门+布线延迟
// 决定。RO 不受 rst_n 复位, 其相位是绝对时间的函数, 硅上则是工艺/电压/温度
// 相关的不可复现量。这是 v3.0 与 v2.0 的根本区别:
//   v2.0 的熵全部由复位值决定 (LFSR 23'h001_C001 / timestamp 从 0 /
//        jitter_reg 从 0), 输出仅是「复位后周期数」的函数 -> 同一复位必然
//        得到同一 k, 两次 k 重复可由 (s1-s2)/(r1-r2) mod n 恢复私钥 (E1)。
//   v3.0 的熵来自异步振荡器相位, 是「上电后绝对时间」的函数, 复位不改变
//        相位, 因此同一复位序列在不同绝对时刻执行会得到不同熵流。
//
// -----------------------------------------------------------------------------
// 【建模正确性: 关键, 已经 tb_delay_construct.v 三路对照验证】
//
//   错误 A: always @(s0) begin #DELAY; s1 = ~s0; end
//     阻塞赋值带前置延迟, RHS 在到期时刻求值。同一时刻多路更新时读到已被
//     更新的值, 跃迁栅格整体错开一个 DELAY (实测 N=3/d=3399 得 3399/13596/
//     23793, 即 D/4D/7D, 与闭式解 2D/5D/8D 不符)。
//
//   错误 B: always @(s0) begin c0=s0; #DELAY; s1=~c0; end
//     模块级捕获寄存器被并发的 always 线程共享, 上电三阶段同时触发时互相
//     覆盖 -> 环完全死锁 (实测 q 恒为 1, 零跃迁, XOR 流全 1, max_run=60000)。
//
//   正确 C (本文件采用): always @(s0) s1 <= #DELAY ~s0;
//     非阻塞赋值带后置延迟: RHS 在触发时刻求值, 结果在 DELAY 后生效。语义
//     等价于同步移位环 s[i]' = 1 - s[(i-1)%N], 故与闭式解
//         q_closed(N,d,t) = u[(t//d)%N] ^ (((t//d)//N)&1)
//         u_vec(N) = [1 if (i==0 or i&1) else 0]
//     完全一致。tb_ro_phys.v + iverilog 逐位比对: ro13 0/60000, ro3 6/60000,
//     ro9 41/60000, 且全部残差均落在 t % DELAY == 0 的跃迁瞬时上 (NBA 读写
//     竞争, 两种取值均可接受), 无任何真模型错误。
//
// -----------------------------------------------------------------------------
// 【种子必须恰为 (1, 0, 0, ..., 0)】
//   u_vec(N) 即该种子对应的前 N 个采样值 (N=3 -> [1,1,0], N=9 -> [1,1,0,1,
//   0,1,0,1,0])。其它种子要么死锁 (全 0 时各级同相, q=(t/d)&1 假象), 要么
//   序列与闭式解不符。
//
// -----------------------------------------------------------------------------
// 【参数选择与验收 (clk 周期 T_clk = 10 ns = 10000 ps, 100 MHz)】
//
//   ro11 DELAY=3511 ps -> T_L = 11*3511 = 38621 ps -> P = 2*T_L = 77242 ps
//   ro9  DELAY=1975 ps -> T_L = 9*1975  = 17775 ps -> P = 2*T_L = 35550 ps
//   ro7  DELAY=2585 ps -> T_L = 7*2585  = 18095 ps -> P = 2*T_L = 36190 ps
//   alpha = Tclk/P = 0.1295 / 0.2813 / 0.2763
//           必须远离 0 (冻结) 与 0.5 (逐拍翻转 -> 周期-2 混叠)。alpha≈0.5
//           正是 L5 的根因, 旧参数为 0.4903。
//   P 两两: gcd(77242,35550)=2, gcd(77242,36190)=22, gcd(35550,36190)=10
//         -> lcm(P) = 451709284950 ps = 45170928 clk = 451.7 ms @100MHz
//   P 比展宽 max/min = 2.173  (旧参数为 1.0008: 三路同周期是 L5 的另一半根因)
//
//   三路 XOR 采样流验收 (NIST SP 800-90B, WIN=1024, 99% 双侧 CI;
//   工具 .workbuddy/tmp/ro_nist_admit.py, 4 相位 x 16 窗口 = 64 窗口真环实测):
//     ones    475..556    阈值 [468, 556]   PASS
//     sumsq  4158..4612   阈值 [4170, 4620] 63/64 窗口在内 (见下注)
//     corr   453..495     阈值 [444, 579]   PASS
//     maxrun    8..18     阈值 <=23         PASS
//     DELAY 扰动 +/-20% 与 +/-35%: 5/5 配置 x 32 窗口 = 160 窗口全部 PASS
//   注: 99% CI 的期望越界率本就是 1%, 64 窗口出现 1 个越界
//       (P(>=1) = 1-0.99^64 = 47%) 是真随机流的正常行为而非缺陷; 旧参数的
//       失败是系统性的 (corr≈1000, sumsq≈4400+, 4/4 窗口全失败), 性质不同。
//
//   L5 根因与本次修复 (2026-10-04):
//     旧参数 ro3/ro9/ro13 的 T_L 全部约 10200 ps -> P ≈ 2.02*TCLK,
//     alpha = TCLK/P = 0.4903 ≈ 0.5, 采样序列近乎逐拍翻转 (周期-2 残留);
//     D1 四检验实测 corr 713..743 (上限 579)、sumsq 6102..6838 (上限 4620)
//     双检验必失败, 而 v1 健康测试 (仅 ones 比 + max_run<=10) 漏检。
//     另 ro3 与 ro9 环周期完全相同 (均 20394 ps), 是 L2 的另一半根因。
//   本次筛选: ro_param_search.py Part C 给出 6 组闭式模型候选, 但闭式模型与
//     真环在跃迁瞬时存在 NBA 读写竞争 (78/96 点失配), 故 4/6 组在 iverilog
//     真环实测被否; 唯本组 ro11/ro9/ro7 在 名义 + 4 相位 + DELAY ±20%/±35%
//     下全部通过, 且闭式模型与 iverilog 实测零失配 (closed_form_mismatch=0)。
//
//   历史教训: 早期版本用 DELAY=1667/713 的双 RO + 4 级相位移位 + snap 快照,
//   在真环模型下实测出现 256-bit 重复 (0/19514 命中), anti-E1 窗口退化为
//   0x55/0xAA 交替的周期-2 混叠伪像, 完全不合格。v3.0 的 ro3/ro9/ro13 亦在
//   同一教训后选出, 但当时只以 ones 比 + max_run 验收, 未纳入 correlation
//   与 poker 两项检验, 因而留下 L5。
// -----------------------------------------------------------------------------
// 【综合注意】
//   `always @(s0) s1 <= #DELAY ~s0;` 在综合时忽略 #DELAY, 形成纯组合反相环。
//   必须阻止综合工具优化掉反馈环, 否则熵源被折叠成常值。Vivado 下对本模块
//   的 reg 加 (* KEEP = "TRUE" *) (* OPTIMIZE = "0" *) (* DONT_TOUCH =
//   "TRUE" *) 属性, 或在约束里指定 LUT 反相实例化; 实际硅上周期由布线延迟
//   决定, 与仿真 DELAY 无关。仿真 DELAY 只用于离线统计特性验收。
// =============================================================================

// -----------------------------------------------------------------------------
// 【timescale 必须为 1ps/1ps, 不能沿用宿主文件的 1ns/1ps】
//   本块被 spliced 进 trng_sm3_v3.v / trng_sm3_v3_1.v, 两者文件头都是
//   `timescale 1ns / 1ps. `timescale 是文件作用域指令, 持续作用于其后
//   声明的所有模块, 直到再次出现 `timescale 为止。RO 模块若不显式覆盖,
//   `#DELAY` 会被按 ns 解释 (DELAY=3511 -> 3511 ns), 环周期慢 1000 倍,
//   clk 采样序列退化为长游程近常值流 (实测 maxrun 191..258, corr 5..12,
//   sumsq 30632..32642, ones 仍 490..643 看似正常), NIST 四项全灭。
//   RO 参数以 ps 为单位筛选, 故必须在此显式覆盖; RO 之后的模块再用
//   下面的 restore 指令回到宿主精度, 避免 1ps 精度泄漏到无关模块。
//   本条已由 .workbuddy/tmp/tb_ro_ts.v 三方对照验证 (同文件并排 ro_ps /
//   ro_ns: 周期 20394 ps vs 20394000 ps, 实测差 1000 倍)。
//   附带教训: 1 ns 精度下环周期只能是 2000 ps 的整数倍, 而 TCLK = 10000 ps,
//   gcd >= 2000 -> 采样序列周期 k = P/gcd <= 10 clk, 属致命混叠, 无法靠调参
//   规避; 故 ps 级精度不是可选项。E1 阶段实测的症状是 xor_bit 连续 96 拍全
//   1、128-bit 熵种子全 0, 熵源完全失效。
// -----------------------------------------------------------------------------
`timescale 1ps / 1ps

module ro11 #(parameter DELAY = 3511) (
    output wire q
);
    (* KEEP = "TRUE" *) (* OPTIMIZE = "0" *) (* DONT_TOUCH = "TRUE" *)
    reg s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10;

    initial begin
        s0 = 1'b1;
        s1 = 1'b0;
        s2 = 1'b0;
        s3 = 1'b0;
        s4 = 1'b0;
        s5 = 1'b0;
        s6 = 1'b0;
        s7 = 1'b0;
        s8 = 1'b0;
        s9 = 1'b0;
        s10 = 1'b0;
    end

    always @(s0) s1 <= #DELAY ~s0;
    always @(s1) s2 <= #DELAY ~s1;
    always @(s2) s3 <= #DELAY ~s2;
    always @(s3) s4 <= #DELAY ~s3;
    always @(s4) s5 <= #DELAY ~s4;
    always @(s5) s6 <= #DELAY ~s5;
    always @(s6) s7 <= #DELAY ~s6;
    always @(s7) s8 <= #DELAY ~s7;
    always @(s8) s9 <= #DELAY ~s8;
    always @(s9) s10 <= #DELAY ~s9;
    always @(s10) s0 <= #DELAY ~s10;

    assign q = s0;
endmodule


module ro9 #(parameter DELAY = 1975) (
    output wire q
);
    (* KEEP = "TRUE" *) (* OPTIMIZE = "0" *) (* DONT_TOUCH = "TRUE" *)
    reg s0, s1, s2, s3, s4, s5, s6, s7, s8;

    initial begin
        s0 = 1'b1;
        s1 = 1'b0;
        s2 = 1'b0;
        s3 = 1'b0;
        s4 = 1'b0;
        s5 = 1'b0;
        s6 = 1'b0;
        s7 = 1'b0;
        s8 = 1'b0;
    end

    always @(s0) s1 <= #DELAY ~s0;
    always @(s1) s2 <= #DELAY ~s1;
    always @(s2) s3 <= #DELAY ~s2;
    always @(s3) s4 <= #DELAY ~s3;
    always @(s4) s5 <= #DELAY ~s4;
    always @(s5) s6 <= #DELAY ~s5;
    always @(s6) s7 <= #DELAY ~s6;
    always @(s7) s8 <= #DELAY ~s7;
    always @(s8) s0 <= #DELAY ~s8;

    assign q = s0;
endmodule


module ro7 #(parameter DELAY = 2585) (
    output wire q
);
    (* KEEP = "TRUE" *) (* OPTIMIZE = "0" *) (* DONT_TOUCH = "TRUE" *)
    reg s0, s1, s2, s3, s4, s5, s6;

    initial begin
        s0 = 1'b1;
        s1 = 1'b0;
        s2 = 1'b0;
        s3 = 1'b0;
        s4 = 1'b0;
        s5 = 1'b0;
        s6 = 1'b0;
    end

    always @(s0) s1 <= #DELAY ~s0;
    always @(s1) s2 <= #DELAY ~s1;
    always @(s2) s3 <= #DELAY ~s2;
    always @(s3) s4 <= #DELAY ~s3;
    always @(s4) s5 <= #DELAY ~s4;
    always @(s5) s6 <= #DELAY ~s5;
    always @(s6) s0 <= #DELAY ~s6;

    assign q = s0;
endmodule



// =============================================================================
// 子模块: 熵源 v3.0 (物理熵) —— 原位替换 v2.0 文件的固定种子 LFSR 版本
//
// 结构: 三路自由运行环形振荡器 -> clk 相位采样 -> 三路异或 -> 4 级相位移位
//       -> bit_out
//
// 接口与 v1.0 / v2.0 的 trng_entropy 完全一致 (bit_out 仅 [0] 被消费,
// [1:3] 保留为多样性位), 可直接原位替换。
//
// 抗确定性的两个关键:
//   1. RO 跨复位存活: rst_n 不进入 RO, 复位不改变 RO 相位, 因此熵不是
//      「复位后周期数」的函数, 而是「上电后绝对时间」的函数
//   2. 三路异或 + 互素环长: 单路 RO 的 clk 采样序列周期为 4991 / 3333 /
//      5103 clk, 三路异或后拉到 lcm(T_L) 对应的 104060385 clk (~1.04 s),
//      避免短周期重复模式 (已实测 60000 样本内无 256-bit 重复)
//
// 注意: 本模块刻意不含任何「复位后首拍快照」之类的掩码。旧版草案里的
// snap 逻辑经分析恒等于复位值 4'b0001 (因为 ph 总是先被复位再被采样),
// 是一个无信息的常值异或, 已移除。
// =============================================================================
// 恢复宿主文件精度: RO 模块之后的模块与本文件头部保持一致
// (RO 是唯一的 ps 域模块, 不恢复会让 1ps 精度泄漏到无关模块)。
`timescale 1ns / 1ps

module trng_entropy (
    input  wire    clk,
    input  wire    rst_n,
    input  wire    req,
    output reg  [3:0] bit_out,
    output reg       bit_vld
);

    wire ro1_q;
    wire ro2_q;
    wire ro3_q;

    ro11 u_ro1 (.q(ro1_q));
    ro9  u_ro2 (.q(ro2_q));
    ro7  u_ro3 (.q(ro3_q));

    wire xor_bit = ro1_q ^ ro2_q ^ ro3_q;

    reg [3:0] ph;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph      <= 4'b0001;
            bit_out <= 4'd0;
            bit_vld <= 1'b0;
        end else begin
            ph <= {ph[2:0], xor_bit};

            if (req) begin
                bit_out <= ph;
                bit_vld <= 1'b1;
            end else begin
                bit_vld <= 1'b0;
            end
        end
    end

endmodule



// (trng_health_test v1 定义已剔除: v3.1 改用 trng_health_test_v2,
//  见 rtl/trng/trng_health_test_v2.v; v1 保留在 trng_sm3_v3.v)
