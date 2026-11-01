// =============================================================================
// 模块名称 : crypto_coord_subsys
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.4
// 日期     : 2026-10-24
// 变更记录 :
//   v1.0 2026-10-02 首版
//   v1.1 - 命令分类改用当前端口 op (is_*_i), 修 op_r 跨事务残留导致误分类挂死
//         - 新增 S_TDONE, 修 TRNG_256 第二笔请求丢拍
//         - 修 SM2 公钥接入 (qx_in=la[511:256] / qy_in=la[255:0])
//   v1.2 2026-10-03 - t_hi/t_lo 由 256 位改 128 位, 修 TRNG_256 高 128 位被截断为 0
//                      (IEEE 1364 §6.5: RHS 比 LHS 宽时丢弃最高位)
//         - busy 语义改为 (state != S_IDLE), 含 S_TDONE / S_OUT / S_ERR,
//           修 busy 轮询型上层在 S_TDONE 插桩导致命令静默丢失
//         - err 改为纯锁存 (err = err_b), 撤掉 (busy && start) 组合式忙时告警:
//           该式在 FSM 离开 S_IDLE 的那拍会产生 1 拍 delta 窗口的假告警, 污染 err
//   v1.3 2026-10-08 - 新增模块参数 USE_SM4_MASKED (默认 0=baseline, 1=sm4_engine_masked_v3)
//                      通过 generate-if 静态选择 SM4 引擎实例, 端口 100% 兼容
//                     (masked_en=1 走内部 LFSR, 观测端口板级悬空, 调度器接口契约不变)
//                      用途: 生产路径默认 baseline, 需要掩码防护的部署用
//                     -Pcrypto_coord_subsys.USE_SM4_MASKED=1 启用 v3
//   v1.4 2026-10-24 - 新增模块参数 USE_SM2 (默认 0, 板级出片裁剪)
//                      USE_SM2=0: 不实例化 sm2_sign (省 40,520 LUT / 68% 面积),
//                        SM2 op 落到非法 op 路径 (err=0x02), 端口 100% 兼容。
//                      USE_SM2=1: 完整 SM2 签名 (v3.0 SIGN-ONLY), 与 v1.3 行为一致。
//                      用途: board15 路由拥塞突破 (68.57% slice + 16K overlaps),
//                      裁掉 sm2_sign 后预计 ~19K LUT / 14% slice, 路由轻松收敛。
//                      用法: synth 时 -Pcrypto_coord_subsys.USE_SM2=0 (board 级)
//                            或不设参数 (子系统级回归, 默认 USE_SM2=1 保持兼容)
//                      注意: 本文件默认 USE_SM2=0 (与 v1.3 不同), 因为板级出片
//                            是主线; 子系统级 TB 需显式传 USE_SM2=1。
//   v1.5 2026-10-25 - USE_SM4_MASKED 新增取值 2 = sm4_engine_masked_v4
//                     (S 盒输出域共享, 真一阶 DPA 防护, SCEA 签核:
//                      TVLA max|t|=3.02 / 一阶 CPA rk0 0-4 / GE=119 不收敛)。
//                     v4 需要 64-bit 每加密新鲜掩码种子: 内部自由运行
//                     xorshift64 (双射, 周期 2^64-1) 供给, 外部端口不变。
//                     取值 1 (sm4_engine_masked_v3) 保留, 但已由 SCEA 证伪为
//                     "仅防 ROM 提取的表混淆", 新设计应使用 2。
// 视角     : rtl-designer (葛逻辑)
// 功能     : 国密多算法协调子系统 (子系统级集成)
//            把 SM4 / SM3 / TRNG / SM2 四个引擎收进一个统一命令接口,
//            由本模块负责: 命令译码 -> 参数锁存 -> 引擎调度 -> 结果捕获 -> 错误聚合
//
// 命令接口 (对齐 phase1/接口表_v1.md §4.1 cmd_router -> 引擎通道的 eng_task_* 语义,
//           子系统级只保留单实例非流水线形式, 多实例并发与优先级仲裁属 SS2 调度器职责):
//     start  : 单周期启动脉冲
//     op[3:0]: 操作码 (见下表)
//     ia[511:0] / ib[511:0] / ic[255:0] : 三路参数 (按 op 语义复用, 见下表)
//
// 操作码表 :
//   op  名称         ia                       ib                 ic
//   ----------------------------------------------------------------------
//   0   SM4_ENC      {192'd0, key[127:0]}     {192'd0, pt[127:0]}   -
//   1   SM4_DEC      {192'd0, key[127:0]}     {192'd0, ct[127:0]}   -
//   2   SM3_CMP      msg_block[511:0]         {256'd0, prev[255:0]}  -
//      (SM3 的 prev 在 ib 的【低】半字: 与 SM4 key 低对齐、SM2 d/e/k 低对齐同一套约定)
//   3   TRNG_128     -                        -                     -
//   4   TRNG_256     -                        -                     -
//   5   SM2_SIGN     d                        e                     k     (USE_SM2=1)
//   6   SM2_VER      {qx, qy}                 {e, r}                s     (已删除)
//   others (非法)    -                        -                     -
//
// 结果接口 :
//     ra[255:0] / rb[255:0] : 结果 (按 op 语义截位; 未用高位填 0)
//     ok                    : 本次操作成功标志 (SM2 验签时为 sig_ok, 其余为 1)
//     done                  : 完成脉冲 (1 cycle, 合法/非法 op 都会发)
//     busy                  : 处理中 (busy 期间 start 被忽略)
//     err[7:0]              : 0x00 正常 / 0x02 非法 op
//                              / 透传子模块错误码 (TRNG 健康测试失败 0x01)
//     注: err 为锁存值, done 之后保持不变直到下一次 start; busy 期间再拉 start
//         属于调用方协议错误, 该命令被静默忽略 (S_IDLE 之外不采样 start),
//         本模块不回错误码 (v1.2 撤掉了组合式忙时告警, 理由见 assign err 处注释)。
//
// 时序 (以 400 MHz 计, 功能仿真同频) :
//     SM4_ENC/DEC ~68c, SM3_CMP ~118c, TRNG_128 ~280c, TRNG_256 ~560c,
//     SM2_SIGN ~2.5e5 c (USE_SM2=1 时)
//
// 依赖     : sm4_engine (v1.0), sm3_engine (v2.0), trng/trng_sm3.v (v2.0),
//            sm2_sign (v3.0, USE_SM2=1 时), sm2_pmul, sm2_nmul, sm2_ninv,
//            sm2_jacaffx, sm2_point_add, sm2_montmul, sm2_modinv, sm2_modarith,
//            sm2_mm_arb, sm2_nm_arb
//
// 编译     : iverilog -g2005 -o tb.vvp tb.v crypto_coord_subsys.v \
//                        sm2_sign.v sm2_pmul.v sm2_nmul.v sm2_ninv.v \
//                        sm2_jacaffx.v sm2_point_add.v sm2_montmul.v \
//                        sm2_modinv.v sm2_modarith.v sm3_engine.v \
//                        sm4_engine.v trng_sm3.v
//
// 设计说明 :
//   - 非抢占式单命令: 一次 start 对应一次完整 op, busy 期间不接受新命令。
//   - 所有输入参数在 S_IDLE 锁存, 避免跨 10^5 拍时端口值漂移 (SM2 尤其关键)。
//   - 子系统内所有引擎同源时钟, 无 CDC; TRNG 取 v2.0 (SM3 DRBG) 修掉 v1.0
//     前 3 字重复的密钥模式缺陷。
//   - TRNG_256 连续取两块 128-bit 拼成 256-bit, 供 SM2_SIGN 的 k 直接使用。
//     不做 k < n 拒绝采样: 2^256 - n ≈ 2^32, 落在 [n, 2^256) 概率 ≈ 2^-224。
//   - USE_SM2=0 时 (v1.4 默认): sm2_sign 不实例化, SM2 op (5) 落入非法 op 路径
//     (err=0x02, ok=0, done=1), 上层可通过 err 判断功能不可用。
// =============================================================================

`timescale 1ns / 1ps

module crypto_coord_subsys #(
    // 0 = sm4_engine (v1.0 baseline, 生产默认)
    // 1 = sm4_engine_masked_v3 (表混淆, 仅防 S 盒 ROM 提取 — SCEA 证伪, 保留兼容)
    // 2 = sm4_engine_masked_v4_indep (逐字节独立输出掩码, 二阶消除 |t| 49.84->1.12, F4 决策 2026-11-01)
    parameter USE_SM4_MASKED = 0,
    // 0 = 不实例化 sm2_sign (v1.4 默认, 板级出片裁剪, 省 40K LUT)
    // 1 = 完整 SM2 签名 (v3.0 SIGN-ONLY), 子系统级回归用
    parameter USE_SM2 = 0
) (
    // 时钟与复位
    input  wire         clk,
    input  wire         rst_n,

    // 命令接口
    input  wire         start,          // 单周期启动脉冲
    input  wire [3:0]   op,             // 操作码 (见操作码表)
    input  wire [511:0] ia,             // 参数 A (最大 512-bit)
    input  wire [511:0] ib,             // 参数 B (最大 512-bit)
    input  wire [255:0] ic,             // 参数 C (最大 256-bit)
    input  wire [63:0]  mask_seed_init,  // v4 掩码种子初值 (每设备保密, P0-6 修复)

    // 结果接口
    output wire [255:0] ra,             // 结果 A
    output wire [255:0] rb,             // 结果 B
    output wire         ok,             // 成功标志
    output wire         done,           // 完成脉冲 (1 cycle)
    output wire         busy,           // 处理中
    output wire [7:0]   err             // 错误码
);

    // =========================================================================
    // 操作码
    // =========================================================================
    localparam OP_SM4_ENC = 4'h0;
    localparam OP_SM4_DEC = 4'h1;
    localparam OP_SM3_CMP = 4'h2;
    localparam OP_TRNG128 = 4'h3;
    localparam OP_TRNG256 = 4'h4;
    localparam OP_SM2_SGN = 4'h5;
    localparam OP_SM2_VER = 4'h6;

    // =========================================================================
    // FSM 状态
    // =========================================================================
    localparam S_IDLE  = 3'd0;   // 空闲 / 采样命令与参数
    localparam S_RUN   = 3'd1;   // 向目标引擎发启动脉冲
    localparam S_WAIT  = 3'd2;   // 等待目标引擎 done
    localparam S_SREQ  = 3'd3;   // 向 TRNG 发请求脉冲
    localparam S_SWAIT = 3'd4;   // 等待 TRNG 数据 (握手)
    localparam S_OUT   = 3'd5;   // done 脉冲
    localparam S_ERR   = 3'd6;   // 错误返回 (发 done 脉冲, ok=0)
    localparam S_TDONE = 3'd7;   // 等 TRNG 自 ferr 端收尾 (v1.1 新增, 防第二次请求丢拍)

    // =========================================================================
    // 状态与寄存器
    // =========================================================================
    reg  [2:0]    state;
    reg  [3:0]    op_r;          // 锁存的操作码
    reg  [511:0]  la;            // 锁存参数 A
    reg  [511:0]  lb;            // 锁存参数 B
    reg  [255:0]  lc;            // 锁存参数 C

    reg  [255:0]  ra_b;
    reg  [255:0]  rb_b;
    reg           ok_b;
    reg  [7:0]    err_b;

    reg           t_cnt;         // TRNG_256 的第二块计数 (0=收第 1 块)
    reg  [127:0]  t_hi;          // TRNG_256 高块 (第二块)
    reg  [127:0]  t_lo;          // TRNG_256 低块 (第一块)

    reg           mask_seed_pending;  // SM4 前置 TRNG 取种标志 (P0-6 方案2, 真随机掩码种子)

    // =========================================================================
    // 子模块端口
    // =========================================================================
    wire [127:0]  sm4_result;
    wire          sm4_done;
    wire          sm4_busy;

    wire [255:0]  sm3_state;
    wire          sm3_done;
    wire          sm3_busy;

    wire [255:0]  sm2_r;
    wire [255:0]  sm2_s;
    wire          sm2_err;
    wire          sm2_done;

    wire          trng_req_rdy;
    wire          trng_data_vld;
    wire [127:0]  trng_data_out;
    wire          trng_data_last;
    wire          trng_busy;
    wire          trng_done;
    wire [7:0]    trng_err_code;

    // =========================================================================
    // v4 掩码种子 (USE_SM4_MASKED=2 时供给 sm4_engine_masked_v4)
    //   **P0-6 修复 (2026-10-27)**: 种子初值由外部 mask_seed_init 注入, 不再写死
    //   公开常数 0x9E3779B97F4A7C15 (该常数为黄金分割常数, 一旦写入 RTL 即公开,
    //   攻击者可逐条 trace 算出 mout8 -> 一阶 CPA 4/4 恢复 rk0)。mask_seed_init
    //   在板级由每设备唯一的 Device DNA 派生 (seed_dna.v), 每次上电不同;
    //   仿真 TB 由测试台注入"设备保密"的随机初值。
    //   **P0-6 方案2 (2026-11-01) 已完成**: 掩码种子改为每次 SM4 事务前置从
    //   trng_sm3_v3 真随机熵源取 64-bit (S_SREQ/S_SWAIT 握手), 不再使用
    //   xorshift64 自由运行。mask_seed_r 由 FSM 在 S_SWAIT 状态锁存
    //   trng_data_out[63:0] 后写入, 确保每次加密掩码真随机且新鲜。
    //   复位初值 = mask_seed_init (每设备保密, POR 上电抖动捕获); TRNG 故障时该值兜底。
    //   **安全前提**: 掩码安全性依赖 trng_sm3_v3 物理熵源 (三路 RO + SP 800-90B DRBG),
    //   攻击者无法从公开 RTL 推算每次事务的掩码种子。
    // =========================================================================
    // P0-6 方案2 (2026-11-01): mask_seed_r 改由 FSM 管理。SM4 事务前置 S_SWAIT
    // 从 TRNG 真随机输出锁存 trng_data_out[63:0] 作为该块掩码种子。
    // 复位初值 = mask_seed_init (每设备保密, POR 上电抖动捕获); TRNG 故障时该值兜底。
    reg [63:0] mask_seed_r;

    // =========================================================================
    // 操作分类 (基于锁存后的 op_r, 保证整个事务内一致)
    // =========================================================================
    wire is_sm4   = ((op_r == OP_SM4_ENC) || (op_r == OP_SM4_DEC));
    wire is_sm3   = (op_r == OP_SM3_CMP);
    // v1.4: USE_SM2=0 时 is_sm2 恒 0, SM2 op 落到非法路径
    wire is_sm2   = USE_SM2 && (op_r == OP_SM2_SGN);
    wire is_trng  = ((op_r == OP_TRNG128) || (op_r == OP_TRNG256));

    // 命令分类(*)在 S_IDLE 里必须基于【当前端口 op】, 不能用 op_r ——
    // op_r 与本拍的 state 是同一个非阻塞赋值, 本拍读到的 op_r 还是上一事务的旧值,
    // 于是 op=3(TRNG) 会被误判成 op=0(SM4) 分支, 子系统永远等 SM4 的 done 而挂死。
    // (v1.0 缺陷, Phase 2.6 首跑暴露)
    wire is_sm4_i   = ((op == OP_SM4_ENC) || (op == OP_SM4_DEC));
    wire is_sm3_i   = (op == OP_SM3_CMP);
    // v1.4: USE_SM2=0 时 is_sm2_i 恒 0
    wire is_sm2_i   = USE_SM2 && (op == OP_SM2_SGN);
    wire is_trng_i  = ((op == OP_TRNG128) || (op == OP_TRNG256));

    // =========================================================================
    // 组合控制脉冲
    // =========================================================================
    // 三个引擎的启动脉冲只在 S_RUN 这一拍有效 (1 cycle)
    wire sm4_start = (state == S_RUN) && is_sm4;
    wire sm3_start = (state == S_RUN) && is_sm3;
    wire sm2_start = (state == S_RUN) && is_sm2;

    // TRNG 请求脉冲 / 数据接收就绪 (握手)
    wire trng_req_vld = (state == S_SREQ);
    wire trng_data_rdy = (state == S_SWAIT);

    // 引擎完成: 只在当前 op 对应的引擎上判, 避免读到别的引擎的残留 done
    wire eng_done = (is_sm4 && sm4_done) ||
                    (is_sm3 && sm3_done) ||
                    (is_sm2 && sm2_done);

    // =========================================================================
    // 子模块实例化
    // =========================================================================
    // =========================================================================
    // SM4 引擎实例化 (v1.5: generate-if 三选)
    // =========================================================================
    // USE_SM4_MASKED = 0 → sm4_engine         (v1.0 baseline, 生产默认, 64 cycles/block)
    // USE_SM4_MASKED = 1 → sm4_engine_masked_v3 (表混淆, 仅防 S 盒 ROM 提取, 34 cycles/block)
    // USE_SM4_MASKED = 2 → sm4_engine_masked_v4 (S 盒输出域共享, 一阶 DPA 防护, ~50 cycles/block)
    // generate 静态选择, 无运行时开销; v3/v4 的掩码控制全部由本模块内部驱动
    // (v3: masked_en=1 走内部 LFSR; v4: masked_en=1 + 内部 xorshift64 种子),
    // 调度器接口契约 (start/done/busy/result) 不变。
    generate
        if (USE_SM4_MASKED == 1) begin : gen_sm4_masked_v3
            sm4_engine_masked_v3 u_sm4 (
                .clk               (clk),
                .rst_n             (rst_n),
                .start             (sm4_start),
                .key               (la[127:0]),
                .plaintext         (lb[127:0]),
                .decrypt           (op_r == OP_SM4_DEC),
                .ciphertext        (lb[127:0]),
                .result            (sm4_result),
                .done              (sm4_done),
                .busy              (sm4_busy),
                // 掩码控制: 内部 LFSR 通路 (外部注入关闭)
                .masked_en         (1'b1),
                .sbox_mask_ext_en  (1'b0),
                .sbox_mask_c_ext   (8'h00),
                .sbox_mask_tbl_ext (2048'h0),
                // 观测端口 (子系统级不需要, 悬空)
                .sbox_addr_tap     (),
                .sbox_mask_c_tap   (),
                .sbox_mask_valid   (),
                .sbox_tbl_valid    ()
            );
        end else if (USE_SM4_MASKED == 2) begin : gen_sm4_masked_v4
            // F4 决策 2026-11-01 路径 A: v4 (共享输出掩码, 二阶 tau×tau 泄漏 |t|=49.84)
            //   -> v4_indep (逐字节独立输出掩码, 二阶消除 |t|=1.12, CPA 6/6->0/6)
            //   端口 12 个完全一致 (drop-in), 仅模块名替换; 面积 +12 LUT (+0.26%)
            sm4_engine_masked_v4_indep u_sm4 (
                .clk               (clk),
                .rst_n             (rst_n),
                .start             (sm4_start),
                .key               (la[127:0]),
                .plaintext         (lb[127:0]),
                .decrypt           (op_r == OP_SM4_DEC),
                .ciphertext        (lb[127:0]),
                .result            (sm4_result),
                .done              (sm4_done),
                .busy              (sm4_busy),
                // 掩码: 始终启用; 种子来自内部自由运行 xorshift64,
                // 每次 start 拍在引擎内部锁存 -> 每块新鲜
                .masked_en         (1'b1),
                .mask_seed         (mask_seed_r)
            );
        end else begin : gen_sm4_baseline
            sm4_engine u_sm4 (
                .clk       (clk),
                .rst_n     (rst_n),
                .start     (sm4_start),
                .key       (la[127:0]),
                .plaintext (lb[127:0]),
                .decrypt   (op_r == OP_SM4_DEC),
                .ciphertext(lb[127:0]),
                .result    (sm4_result),
                .done      (sm4_done),
                .busy      (sm4_busy)
            );
        end
    endgenerate

    sm3_engine u_sm3 (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (sm3_start),
        .msg_block  (la[511:0]),
        .prev_state (lb[255:0]),
        .out_state  (sm3_state),
        .done       (sm3_done),
        .busy       (sm3_busy)
    );

    // TRNG: trng_sm3.v 的模块名同样是 trng (v2.0 可 drop-in 替换 v1.0)
    trng u_trng (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_vld   (trng_req_vld),
        .req_rdy   (trng_req_rdy),
        .req_bytes (8'd1),            // 每次交付 1 个 128-bit 块
        .data_vld  (trng_data_vld),
        .data_rdy  (trng_data_rdy),
        .data_out  (trng_data_out),
        .data_last (trng_data_last),
        .busy      (trng_busy),
        .done      (trng_done),
        .err_code  (trng_err_code)
    );

    // =========================================================================
    // SM2 签名引擎实例化 (v1.4: USE_SM2 参数开关)
    // =========================================================================
    // USE_SM2=0 (v1.4 默认, 板级出片): 不实例化 sm2_sign, 省 40,520 LUT / 68% 面积
    //   SM2 op (5) 落入非法 op 路径 (err=0x02), 端口 100% 兼容, 上层无感
    // USE_SM2=1 (子系统级回归): 完整 SM2 签名 (v3.0 SIGN-ONLY), 与 v1.3 行为一致
    generate
        if (USE_SM2 == 1) begin : gen_sm2_enabled
            sm2_sign u_sm2 (
                .clk     (clk),
                .rst_n   (rst_n),
                .start   (sm2_start),
                // v3.0 SIGN-ONLY: 验签端口已删除, 只保留签名 (d/e/k = la/lb/lc)
                .d_in    (la[255:0]),
                .e_in    (lb[255:0]),
                .k_in    (lc[255:0]),
                .r_out   (sm2_r),
                .s_out   (sm2_s),
                .err     (sm2_err),
                .done    (sm2_done)
            );
        end else begin : gen_sm2_disabled
            // tie-off: 防综合器对未驱动 wire 报 warning
            assign sm2_r    = 256'd0;
            assign sm2_s    = 256'd0;
            assign sm2_err  = 1'b0;
            assign sm2_done = 1'b0;
        end
    endgenerate

    // =========================================================================
    // FSM 主逻辑
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            op_r    <= 4'h0;
            la      <= 512'd0;
            lb      <= 512'd0;
            lc      <= 256'd0;
            ra_b    <= 256'd0;
            rb_b    <= 256'd0;
            ok_b    <= 1'b0;
            err_b   <= 8'h00;
            t_cnt   <= 1'd0;
            t_hi    <= 128'd0;
            t_lo    <= 128'd0;
            mask_seed_pending <= 1'b0;
            mask_seed_r <= (mask_seed_init != 64'h0) ? mask_seed_init
                                                    : 64'h9E3779B97F4A7C15;
        end else begin
            case (state)

                // -----------------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        // 命令与参数一次性锁存 (跨 10^5 拍, 端口值不能依赖外部)
                        op_r  <= op;
                        la    <= ia;
                        lb    <= ib;
                        lc    <= ic;
                        err_b <= 8'h00;
                        // 注意: 这里用 *_i (基于端口 op) 做分支判定, 不用 is_* (基于 op_r)
                        if (is_trng_i) begin
                            t_cnt <= 1'd0;
                            mask_seed_pending <= 1'b0;
                            state <= S_SREQ;
                        end else if (is_sm4_i) begin
                            // P0-6 方案2: SM4 先走 TRNG 取 64-bit 真随机掩码种子, 再 start SM4
                            mask_seed_pending <= 1'b1;
                            state <= S_SREQ;
                        end else if (is_sm3_i || is_sm2_i) begin
                            state <= S_RUN;
                        end else begin
                            // 非法 op (含 USE_SM2=0 时的 SM2 op): 立刻返回
                            err_b <= 8'h02;
                            ok_b  <= 1'b0;   // v3.0 SIGN-ONLY: 非法 op 必须清 ok, 否则残留上一事务 ok=1
                            state <= S_ERR;
                        end
                    end
                end

                // -----------------------------------------------------------
                S_RUN: begin
                    // 三个 start 脉冲已由组合逻辑在同一拍断言
                    state <= S_WAIT;
                end

                // -----------------------------------------------------------
                S_WAIT: begin
                    if (eng_done) begin
                        case (op_r)
                            OP_SM4_ENC, OP_SM4_DEC: begin
                                ra_b <= {192'd0, sm4_result};   // 128-bit 结果低对齐
                                rb_b <= 256'd0;
                                ok_b <= 1'b1;
                            end
                            OP_SM3_CMP: begin
                                ra_b <= sm3_state;
                                rb_b <= 256'd0;
                                ok_b <= 1'b1;
                            end
                            OP_SM2_SGN: begin
                                ra_b <= sm2_r;
                                rb_b <= sm2_s;
                                ok_b <= (sm2_err == 1'b0);
                            end
                            default: begin
                                ra_b <= 256'd0;
                                rb_b <= 256'd0;
                                ok_b <= 1'b0;
                            end
                        endcase
                        state <= S_OUT;
                    end
                end

                // -----------------------------------------------------------
                S_SREQ: begin
                    // trng_req_vld 已由组合逻辑断言, 等一拍让 TRNG 采样
                    state <= S_SWAIT;
                end

                // -----------------------------------------------------------
                S_TDONE: begin
                    // TRNG 交付单块后仍要走 S_OUTPUT -> S_DONE -> S_IDLE 三个状态。
                    // 若此时直接回 S_SREQ 发下一拍, 请求脉冲会落在 TRNG 的 S_DONE/S_IDLE
                    // 交错的那一拍上被漏掉 (v1.0 缺陷, Phase 2.6 首跑暴露: TRNG_256 卡死)。
                    // 这里先等它的 done 脉冲, 保证下一次请求被 TRNG 的 S_IDLE 稳定采到。
                    if (trng_done) state <= S_SREQ;
                end

                // -----------------------------------------------------------
                S_SWAIT: begin
                    if (trng_err_code != 8'h00) err_b <= trng_err_code;   // 健康测试失败透传
                    if (trng_data_vld && trng_data_last) begin
                        if (mask_seed_pending) begin
                            // P0-6 方案2: SM4 真随机掩码种子 (TRNG 128-bit 低 64-bit)
                            mask_seed_r <= trng_data_out[63:0];
                            mask_seed_pending <= 1'b0;
                            state <= S_RUN;
                        end else if ((op_r == OP_TRNG256) && (t_cnt == 1'd0)) begin
                            // 第一块 -> 存下, 再发一次请求
                            t_lo  <= trng_data_out;
                            t_cnt <= 1'd1;
                            state <= S_TDONE;
                        end else begin
                            t_hi  <= trng_data_out;
                            if (op_r == OP_TRNG256)
                                ra_b <= {trng_data_out, t_lo};   // 高块在上
                            else
                                ra_b <= {192'd0, trng_data_out};
                            rb_b <= 256'd0;
                            ok_b <= 1'b1;
                            state <= S_OUT;
                        end
                    end
                end

                // -----------------------------------------------------------
                S_OUT: begin
                    state <= S_IDLE;
                end

                // -----------------------------------------------------------
                S_ERR: begin
                    state <= S_IDLE;
                end

                // -----------------------------------------------------------
                default: state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // 输出逻辑
    // =========================================================================
    // busy 语义 = "除空闲外一律忙"。
    // 不能漏掉 S_TDONE: TRNG_256 在两次取块之间会经过 S_TDONE, 若此时 busy 拉低,
    // 外部按 busy 轮询的上层就会误判事务结束、在 S_TDONE 上再拉 start ——
    // 而 S_TDONE 分支不采样 start, 那笔命令会被静默丢掉 (v1.0 缺陷, Phase 2.6 暴露)。
    // S_OUT / S_ERR 是 done 脉冲态, 同样计入 busy, 保证 busy 拉低当拍一定回到 S_IDLE。
    assign busy = (state != S_IDLE);
    assign done = ((state == S_OUT) || (state == S_ERR));
    assign ra   = ra_b;
    assign rb   = rb_b;
    assign ok   = ok_b;
    // err 只反映锁存的错误码 (err_b), 不做 "busy && start" 的组合式忙时告警。
    // v1.2 修正: v1.1 曾写 err = err_b | ((busy && start) ? 8'h03 : 8'h00),
    // 意图是忙态期间误拉 start 时当拍报 0x03。但 busy = (state != S_IDLE) 是组合量,
    // 在 FSM 离开 S_IDLE 的那一拍 posedge 上 busy 已翻高, 而 TB 端的 start 脉冲
    // 要到 #1 之后才拉低 —— 于是每次合法 start 都会在 NBA 之后留下一个 1 拍 delta
    // 窗口的 busy=1 & start=1, err 被短暂污染成 0x03。上层若在 done 后按 err 语义
    // 采样, 恰好落在该窗口就会把 0x02 (非法 op) 误读成 0x03 (T10 因此失败)。
    // 结论: 忙时忽略 start 是 FSM 的正确行为 (S_IDLE 之外不采样 start), 但告警不应
    // 走组合路径, 否则告警与正常启动同拍竞争。此处保持 err = err_b 的纯锁存语义。
    assign err   = err_b;

endmodule
