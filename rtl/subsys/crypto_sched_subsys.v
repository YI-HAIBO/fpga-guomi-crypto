// =============================================================================
// 模块名称 : crypto_sched_subsys
// 模块编号 : SS2 (Phase 2.7 - Command Scheduler)
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.2
// 日期     : 2026-10-11
// 变更记录 :
//   v1.0 2026-10-03 首版
//   v1.1 2026-10-03 res_ok 加 fifo_empty 保护: fifo 空时 head 指向未写入
//                  槽位, 直读得 X, 再反相进 err_src_vld 会把 X 带进
//                  控制路径。改为 fifo_empty ? 1'b0 : fifo_ok[fifo_head]
//   v1.2 2026-10-11 降配 2->1 引擎 (UTLZ-1 容量决策 A): 删除 u_eng1 实例与
//                  route_eng1/rr_ptr 轮转路由, 结果 FIFO/重试控制器只保留
//                  eng0 通路。SM2 吞吐减半, 但单引擎 ~88k LUT 解除 xc7a200t
//                  的 134,600 LUT 容量超限 (Phase 8 实测双引擎 184,401=137%)。
//                  外部端口完全不变, gm_crypto_top / pcie_front_subsys_v15
//                  无需改动。
//       2026-10-11 RAM 写端口合并: cmd_accept 与 e0_needs_retry 原各占一个
//                  always 写 ram_ic/ram_retry, Vivado 判为多写端口 RAM
//                  (Synth 8-13234), RAM_STYLE="distributed" 被拒, 退回 BRAM
//                  推断, 512/256 位宽超模板 -> [Synth 8-2914]。
//                  修法: 两路合并进一个 always; 并在 e0_needs_retry 当拍把
//                  cmd_rdy 拉低一拍, 使 cmd_accept 与 e0_needs_retry 严格
//                  互斥 (上游 cmd_fifo 保持 cmd_vld, 下一拍再接收, 握手
//                  不违约), 单写端口成立, 分布式 RAM 推断恢复, 且重试仍
//                  在原拍完成, 行为与历史版本一致。
//   v1.3 2026-10-25 新增模块参数 USE_SM4_MASKED (默认 0, 向下穿透到
//                  crypto_coord_subsys): 2 = sm4_engine_masked_v4 (板级
//                  掩码出片), 1 = v3 (兼容保留), 0 = baseline。
//                  外部端口不变, 默认值与历史版本行为完全一致。
//
// 视角     : fpga-fullflow-lead (齐流晶)
//
// 功能     : SS2 调度器顶层。把 cmd_parser / prio_queue / arbiter 三个底层
//            模块 + 1 个 crypto_coord_subsys 引擎实例收进统一握手接口。
//
// 数据通路:
//   命令输入 -> cmd_parser -> cmd_ram + prio_queue -> arbiter -> cmd_router
//            -> 引擎实例 (1x) -> done 收集 -> 结果 FIFO -> 结果输出
//
// 设计决策:
//   D1: 命令 RAM 用独立寄存器存各字段 (避免位拼接错误)。
//   D2: 单引擎顺序服务, 不抢占。命令在 prio_queue 里排队, 引擎空闲即弹出
//       下一路。M09 ctx_switcher 属 SS4。历史版本 v1.0/v1.1 为 2 引擎
//       round-robin; v1.2 因 xc7a200t 容量降配 (见 Phase8 微规格书 §8.2)。
//   D3: 结果 FIFO 深度 8, 支持 rid 乱序返回。
//   D4: SM2_SIGN 失败重试最多 3 次, 新 k 由 LFSR 生成 (简化版)。
//   D5: 非法命令走快速返回通道, 不占引擎、不入队。
//
// 编译     : iverilog -g2005
// =============================================================================

`timescale 1ns / 1ps

module crypto_sched_subsys #(
    // 向下穿透到 crypto_coord_subsys:
    //   0 = sm4_engine baseline (默认), 1 = v3 表混淆 (兼容), 2 = v4 输出再掩码
    parameter USE_SM4_MASKED = 0
) (
    input  wire         clk,
    input  wire         rst_n,

    // ---- 命令输入 (握手) ----
    input  wire         cmd_vld,
    output wire         cmd_rdy,
    input  wire [7:0]   cmd_rid,
    input  wire [3:0]   cmd_op,
    input  wire [1:0]   cmd_prio,
    input  wire [511:0] cmd_ia,
    input  wire [511:0] cmd_ib,
    input  wire [255:0] cmd_ic,
    input  wire [63:0]  mask_seed_init,  // v4 掩码种子初值 (每设备保密, P0-6 修复)

    // ---- 结果输出 (握手) ----
    output wire         res_vld,
    input  wire         res_rdy,
    output wire [7:0]   res_rid,
    output wire [7:0]   res_err,
    output wire         res_ok,
    output wire [255:0] res_ra,
    output wire [255:0] res_rb
);

    // =========================================================================
    // 参数
    // =========================================================================
    localparam CMD_RAM_DEPTH  = 16;
    localparam CMD_IDX_W      = 4;
    localparam PQ_DEPTH       = 8;
    localparam PQ_IDX_W       = 4;
    localparam RES_FIFO_DEPTH = 8;
    localparam MAX_RETRY      = 3;
    localparam AGING_W        = 14;
    localparam AGING_THRESH   = 10000;

    localparam [7:0] ERR_RETRY_EXH = 8'h22;
    localparam [3:0] OP_SM2_SGN    = 4'h5;

    // =========================================================================
    // 命令 RAM (独立寄存器, 避免位拼接错误)
    //   RAM 推断要点 (2026-10-11, 解决 [Synth 8-2914]):
    //   (1) 单引擎版面积降下来后, Vivado 对 ram_ia/ram_ib/ram_ic 尝试整块
    //       RAM 推断; 512/256 位宽远超 RAM16X1D/RAM32M/BRAM 模板位宽,
    //       触发 8-2914 (双引擎版因面积压力被拆成分立 RAM16X1D 而没报错)。
    //   (2) 显式 RAM_STYLE="distributed" 强制分布式 RAM, 与双引擎版一致;
    //       但它要求**单写端口**——历史版本 cmd_accept 与 e0_needs_retry 各
    //       占一个 always 写 ram_ic/ram_retry, 被判多写端口 (Synth 8-13234),
    //       属性被拒, 退回 BRAM 推断 -> 仍 8-2914。
    //   (3) 最终修法: 两个写源合并进一个 always, 并在 e0_needs_retry 当拍
    //       把 cmd_rdy 拉低, 使两路严格互斥 (见"命令接收逻辑"注释)。
    //       单写端口成立, 分布式 RAM16X1D 推断恢复。
    //   iverilog 忽略 RAM_STYLE 属性, 仿真语义不受影响。
    // =========================================================================
    reg [7:0]   ram_rid    [0:CMD_RAM_DEPTH-1];
    reg [3:0]   ram_op     [0:CMD_RAM_DEPTH-1];
    reg [1:0]   ram_prio   [0:CMD_RAM_DEPTH-1];
    (* RAM_STYLE = "distributed" *)
    reg [511:0] ram_ia     [0:CMD_RAM_DEPTH-1];
    (* RAM_STYLE = "distributed" *)
    reg [511:0] ram_ib     [0:CMD_RAM_DEPTH-1];
    (* RAM_STYLE = "distributed" *)
    reg [255:0] ram_ic     [0:CMD_RAM_DEPTH-1];
    reg [2:0]   ram_retry  [0:CMD_RAM_DEPTH-1];

    // =========================================================================
    // 命令索引生成
    // =========================================================================
    reg [CMD_IDX_W-1:0] cmd_idx_gen;

    // =========================================================================
    // cmd_parser
    // =========================================================================
    wire        cp_legal;
    wire        cp_illegal;
    wire [7:0]  cp_err;

    // 注意: cmd_parser 的 i_rdy 是 **output** (内部 assign i_rdy = 1'b1, 见
    // cmd_parser.v:100, "解析无代价, 反压由上层负责")。绝不可把它连到 cmd_rdy ——
    // 否则 cmd_rdy 被 VCC 与 pq_all_not_full 双驱动, Vivado 保留常数驱动而忽略
    // pq_all_not_full (Synth 8-6858), 综合后反压永久失效: 队列满时仍接受命令,
    // prio_queue 的 free 计数下溢、队列状态损坏。此处必须悬空, cmd_rdy 只由
    // pq_all_not_full 驱动 (见下方 assign)。
    cmd_parser u_parser (
        .clk(clk), .rst_n(rst_n),
        .i_vld(cmd_vld), .i_rdy(),
        .i_op(cmd_op), .i_rid(cmd_rid), .i_prio(cmd_prio),
        .i_ia(cmd_ia), .i_ib(cmd_ib), .i_ic(cmd_ic),
        .o_legal(cp_legal), .o_illegal(cp_illegal),
        .o_err(cp_err), .o_op(), .o_rid(), .o_prio()
    );

    // =========================================================================
    // prio_queue
    // =========================================================================
    reg              pq_push = 0;
    reg [1:0]       pq_prio = 0;
    reg  [CMD_IDX_W-1:0] pq_idx = 0;

    wire [3:0]      pq_valid;
    wire [3:0]      pq_full;
    wire [3:0]      pq_cnt;
    wire [4*CMD_IDX_W-1:0] pq_head_idx;
    wire [4*AGING_W-1:0]   pq_head_age;

    wire            pq_pop;
    wire [1:0]      pq_pop_lvl;

    prio_queue #(
        .DEPTH(PQ_DEPTH),
        .IDX_W(PQ_IDX_W),
        .AGING_W(AGING_W)
    ) u_pq (
        .clk(clk), .rst_n(rst_n),
        .i_push(pq_push), .i_prio(pq_prio), .i_idx(pq_idx),
        .i_pop(pq_pop), .i_pop_lvl(pq_pop_lvl),
        .o_valid(pq_valid), .o_full(pq_full),
        .o_cnt(pq_cnt), .o_head_idx(pq_head_idx),
        .o_head_age(pq_head_age)
    );

    // =========================================================================
    // arbiter
    // =========================================================================
    wire            ab_pop;
    wire [1:0]      ab_pop_lvl;
    wire [3:0]      ab_aging_hit;

    arbiter #(
        .AGING_W(AGING_W),
        .AGING_THRESHOLD(AGING_THRESH)
    ) u_arb (
        .clk(clk), .rst_n(rst_n),
        .i_valid(pq_valid),
        .i_head_age(pq_head_age),
        .o_pop(ab_pop),
        .o_pop_lvl(ab_pop_lvl),
        .o_aging_hit(ab_aging_hit)
    );

    // 路由前馈 (eng_free 在下面声明, 这里先声明 pq_pop 的 wire, 后面重连)
    wire eng_any_free;
    assign pq_pop     = ab_pop & eng_any_free;
    assign pq_pop_lvl = ab_pop_lvl;

    // =========================================================================
    // 命令接收逻辑
    //   cmd_rdy 在 e0_needs_retry 当拍拉低: SM2_SIGN 重试必须占用 cmd_ram
    //   写端口 (写新 k + 重试计数) 与 pq_push (重新入队)。若该拍同时接收
    //   新命令, 两者争同一写端口。把 rdy 拉低一拍即可从源头避免竞争:
    //   上游 cmd_fifo 见 rdy=0 会保持 cmd_vld, 下一拍重试完成、rdy 恢复
    //   再接收, 握手协议不违约。无组合回路 (e0_needs_retry 只依赖引擎
    //   寄存器输出)。
    // =========================================================================
    wire pq_all_not_full = (pq_full == 4'd0);
    assign cmd_rdy = pq_all_not_full && !e0_needs_retry;

    wire cmd_accept = cmd_vld && cmd_rdy && cp_legal;
    wire cmd_reject = cmd_vld && cmd_rdy && cp_illegal;

    // =========================================================================
    // 命令索引递增 (只在新命令入队时分配槽位; pop 不消耗新槽)
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n)
            cmd_idx_gen <= 0;
        else if (cmd_accept)
            cmd_idx_gen <= cmd_idx_gen + 1;
    end

    // =========================================================================
    // 推入 prio_queue (前馈避免 NBA 滞后)
    // =========================================================================
    reg              n_pq_push;
    reg [1:0]       n_pq_prio;
    reg [CMD_IDX_W-1:0] n_pq_idx;

    always @(posedge clk) begin
        if (!rst_n) begin
            pq_push <= 0; pq_prio <= 0; pq_idx <= 0;
            n_pq_push <= 0;
        end else begin
            pq_push <= n_pq_push;
            pq_prio <= n_pq_prio;
            pq_idx  <= n_pq_idx;

            if (cmd_accept) begin
                n_pq_push <= 1'b1;
                n_pq_prio <= cmd_prio;
                n_pq_idx  <= cmd_idx_gen;
            end else if (e0_needs_retry) begin
                n_pq_push <= 1'b1;
                n_pq_prio <= 2'd0;
                n_pq_idx  <= e0_cmd_idx_l;
            end else begin
                n_pq_push <= 1'b0;
            end
        end
    end

    // =========================================================================
    // 弹出命令索引解码
    //   pq_head_idx: [15:12]=lvl3, [11:8]=lvl2, [7:4]=lvl1, [3:0]=lvl0
    // =========================================================================
    wire [CMD_IDX_W-1:0] popped_idx;
    assign popped_idx = (ab_pop_lvl == 2'd0) ? pq_head_idx[CMD_IDX_W-1:0] :
                        (ab_pop_lvl == 2'd1) ? pq_head_idx[2*CMD_IDX_W-1:CMD_IDX_W] :
                        (ab_pop_lvl == 2'd2) ? pq_head_idx[3*CMD_IDX_W-1:2*CMD_IDX_W] :
                                                pq_head_idx[4*CMD_IDX_W-1:3*CMD_IDX_W];

    // 从 cmd_ram 读出弹出命令
    wire [7:0]   popped_rid    = ram_rid[popped_idx];
    wire [3:0]   popped_op     = ram_op[popped_idx];
    wire [511:0] popped_ia     = ram_ia[popped_idx];
    wire [511:0] popped_ib     = ram_ib[popped_idx];
    wire [255:0] popped_ic     = ram_ic[popped_idx];
    wire [2:0]   popped_retry  = ram_retry[popped_idx];

    // =========================================================================
    // 引擎实例 (v1.2: 单引擎降配)
    // =========================================================================
    wire [3:0]   eng0_op;
    wire [511:0] eng0_ia;
    wire [511:0] eng0_ib;
    wire [255:0] eng0_ic;
    wire         eng0_start;
    wire [255:0] eng0_ra;
    wire [255:0] eng0_rb;
    wire         eng0_ok;
    wire         eng0_done;
    wire         eng0_busy;
    wire [7:0]   eng0_err;

    crypto_coord_subsys #(
        .USE_SM4_MASKED (USE_SM4_MASKED),
        .USE_SM2        (0)          // 板级出片裁剪: SM2 由上位机/软件完成
    ) u_eng0 (
        .clk(clk), .rst_n(rst_n),
        .start(eng0_start), .op(eng0_op),
        .ia(eng0_ia), .ib(eng0_ib), .ic(eng0_ic),
        .mask_seed_init (mask_seed_init),  // v4 掩码种子 (P0-6 修复)
        .ra(eng0_ra), .rb(eng0_rb),
        .ok(eng0_ok), .done(eng0_done), .busy(eng0_busy), .err(eng0_err)
    );

    // =========================================================================
    // 命令路由 (v1.2: 单引擎)
    //   规则: 引擎空闲 -> 弹出队头并启动; 引擎忙 -> 不路由 (pq_pop 被
    //         eng_any_free 门控为 0, 命令留在 prio_queue 里等下一拍再试)。
    // =========================================================================
    wire eng0_free = !eng0_busy;

    assign eng_any_free = eng0_free;

    wire route_eng0 = ab_pop && eng0_free;

    assign eng0_start = route_eng0;

    assign eng0_op = popped_op;
    assign eng0_ia = popped_ia;
    assign eng0_ib = popped_ib;
    assign eng0_ic = popped_ic;

    // =========================================================================
    // 引擎完成追踪 (v1.2: 仅 eng0)
    // =========================================================================
    reg [CMD_IDX_W-1:0] e0_cmd_idx_l;
    reg [7:0]           e0_rid_l;
    reg [3:0]           e0_op_l;
    reg [2:0]           e0_retry_l;

    always @(posedge clk) begin
        if (!rst_n) begin
            e0_cmd_idx_l <= 0; e0_rid_l <= 0; e0_op_l <= 0; e0_retry_l <= 0;
        end else begin
            if (route_eng0) begin
                e0_cmd_idx_l <= popped_idx;
                e0_rid_l     <= popped_rid;
                e0_op_l      <= popped_op;
                e0_retry_l   <= popped_retry;
            end
        end
    end

    // =========================================================================
    // SM2_SIGN 重试控制器 (LFSR 生成新 k)
    // =========================================================================
    reg [31:0] lfsr = 32'hDEADBEEF;
    wire [31:0] lfsr_next = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1]};
    always @(posedge clk) begin
        if (!rst_n) lfsr <= 32'hDEADBEEF;
        else        lfsr <= lfsr_next;
    end

    wire e0_needs_retry = eng0_done && !eng0_ok &&
                           (e0_op_l == OP_SM2_SGN) &&
                           (e0_retry_l < 3'd3);

    wire e0_retry_exh = eng0_done && !eng0_ok &&
                         (e0_op_l == OP_SM2_SGN) &&
                         (e0_retry_l >= 3'd3);

    // -------------------------------------------------------------------------
    // 竞争消除说明 (v1.2):
    //   历史版本 cmd_accept 与 e0_needs_retry 各占一个 always 写 ram_ic/
    //   ram_retry -> Vivado 判多写端口 RAM (Synth 8-13234), 分布式属性被拒,
    //   退回 BRAM 推断, 512/256 位宽超模板 -> [Synth 8-2914]。
    //   现把两路合并进下面唯一的 always (cmd_accept 优先); 由于 cmd_rdy 已
    //   在 e0_needs_retry 当拍拉低, cmd_accept 与 e0_needs_retry 严格互斥,
    //   不需要额外的挂起寄存器, 重试仍在原拍完成 RAM 更新与重新入队,
    //   行为与历史版本完全一致 (仅当拍不接受新命令)。
    // -------------------------------------------------------------------------

    // =========================================================================
    // cmd_ram 统一写端口 (单一 always, cmd_accept / e0_needs_retry 互斥)
    // =========================================================================
    always @(posedge clk) begin
        if (cmd_accept) begin
            ram_rid[cmd_idx_gen]   <= cmd_rid;
            ram_op[cmd_idx_gen]    <= cmd_op;
            ram_prio[cmd_idx_gen]  <= cmd_prio;
            ram_ia[cmd_idx_gen]    <= cmd_ia;
            ram_ib[cmd_idx_gen]    <= cmd_ib;
            ram_ic[cmd_idx_gen]    <= cmd_ic;
            ram_retry[cmd_idx_gen] <= 3'd0;
        end else if (e0_needs_retry) begin
            ram_ic[e0_cmd_idx_l]    <= {224'd0, lfsr};
            ram_retry[e0_cmd_idx_l] <= e0_retry_l + 3'd1;
        end
    end

    // =========================================================================
    // 结果 FIFO (独立寄存器)
    // =========================================================================
    reg [7:0]   fifo_rid [0:RES_FIFO_DEPTH-1];
    reg [7:0]   fifo_err [0:RES_FIFO_DEPTH-1];
    reg         fifo_ok  [0:RES_FIFO_DEPTH-1];
    reg [255:0] fifo_ra  [0:RES_FIFO_DEPTH-1];
    reg [255:0] fifo_rb  [0:RES_FIFO_DEPTH-1];
    reg [3:0]   fifo_head = 0;
    reg [3:0]   fifo_tail = 0;
    reg [3:0]   fifo_cnt  = 0;

    wire fifo_full  = (fifo_cnt == RES_FIFO_DEPTH[3:0]);
    wire fifo_empty = (fifo_cnt == 0);
    assign res_vld = !fifo_empty;
    wire res_pop = res_vld && res_rdy;

    assign res_rid = fifo_rid[fifo_head];
    assign res_err = fifo_err[fifo_head];
    // fifo 空时 head 指向未写入槽位, 直读得 X; res_ok 又反相进 err_src_vld,
    // 这里显式清零, 避免 X 渗入控制路径 (err_src_vld = res_vld && !res_ok)。
    assign res_ok  = fifo_empty ? 1'b0 : fifo_ok[fifo_head];
    assign res_ra  = fifo_ra[fifo_head];
    assign res_rb  = fifo_rb[fifo_head];

    // 结果入队 (v1.2: 仅 eng0 + 非法命令快速通道)
    wire res_push_any = eng0_done || cmd_reject;
    wire res_push_ok  = res_push_any && !fifo_full &&
                         !e0_needs_retry;

    always @(posedge clk) begin
        if (!rst_n) begin
            fifo_head <= 0;
            fifo_tail <= 0;
            fifo_cnt  <= 0;
        end else begin
            if (res_push_ok) begin
                // 选择入队数据
                if (e0_retry_exh) begin
                    fifo_rid[fifo_tail] <= e0_rid_l;
                    fifo_err[fifo_tail] <= ERR_RETRY_EXH;
                    fifo_ok[fifo_tail]  <= 1'b0;
                    fifo_ra[fifo_tail]  <= eng0_ra;
                    fifo_rb[fifo_tail]  <= eng0_rb;
                end else if (eng0_done) begin
                    fifo_rid[fifo_tail] <= e0_rid_l;
                    fifo_err[fifo_tail] <= eng0_err;
                    fifo_ok[fifo_tail]  <= eng0_ok;
                    fifo_ra[fifo_tail]  <= eng0_ra;
                    fifo_rb[fifo_tail]  <= eng0_rb;
                end else if (cmd_reject) begin
                    fifo_rid[fifo_tail] <= cmd_rid;
                    fifo_err[fifo_tail] <= cp_err;
                    fifo_ok[fifo_tail]  <= 1'b0;
                    fifo_ra[fifo_tail]  <= 256'd0;
                    fifo_rb[fifo_tail]  <= 256'd0;
                end

                if (fifo_tail == RES_FIFO_DEPTH - 1)
                    fifo_tail <= 0;
                else
                    fifo_tail <= fifo_tail + 1;
            end

            if (res_pop) begin
                if (fifo_head == RES_FIFO_DEPTH - 1)
                    fifo_head <= 0;
                else
                    fifo_head <= fifo_head + 1;
            end

            if (res_push_ok && !res_pop)
                fifo_cnt <= fifo_cnt + 1;
            else if (!res_push_ok && res_pop)
                fifo_cnt <= fifo_cnt - 1;
        end
    end

endmodule
