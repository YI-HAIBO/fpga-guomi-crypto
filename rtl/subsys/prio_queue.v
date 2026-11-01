// =============================================================================
// 模块名称 : prio_queue
// 模块编号 : M07 (SS2 - Command Scheduler, 见 phase1/架构与模块划分说明书_v1.md §2.2)
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-03
// 视角     : rtl-designer (葛逻辑)
// 时钟     : clk_l400
//
// 功能     : 4 级优先级命令队列。每级一个独立 FIFO, 条目只存命令索引 (指向上层
//            的命令 RAM), 队宽因此很窄, 64 位宽的命令字统一放在 RAM 里。
//            每一级额外维护一个「队头年龄」计数 age[l]:
//              - 该级非空时每拍 +1 (饱和), 表示队头条目已等了多久
//              - 该级出队或转空时清零
//            age[l] 交给 M08 arbiter 做老化提升判断。
//
// 设计约定 :
//   - 每级的 free 计数从 DEPTH 递减; 出队 +1, 入队 -1。因此被弹出的槽位
//     允许留在中间, 新条目从 free 计数往下继续写 (环形占用), 不会覆盖未消费条目。
//   - 命令索引 IDX_W 由上层按 (正常区 + 错误区) 总槽数决定, 4 级共用同一地址空间。
//   - 每一级的 o_age 是「自队头条目进入以来的拍数」, 对单主控 FIFO 是精确的
//     队头年龄 (单主控下每个条目到达时都是队尾, 且只有队头会被弹出)。
//
// 编译     : iverilog -g2005
// =============================================================================

`timescale 1ns / 1ps

module prio_queue #(
    parameter DEPTH      = 16,                 // 每级深度
    parameter IDX_W      = 6,                  // 命令索引位宽
    parameter CNT_W      = 4,                  // 计数位宽 (须 >= $clog2(DEPTH)+1)
    parameter AGING_W    = 14                  // 队头年龄位宽
) (
    input  wire               clk,
    input  wire               rst_n,

    // 入队 (4 级, 命令按 prio 选级)
    input  wire               i_push,
    input  wire [1:0]         i_prio,
    input  wire [IDX_W-1:0]   i_idx,

    // 出队 (4 级, 由 M08 arbiter 选中哪级出队)
    input  wire               i_pop,
    input  wire [1:0]         i_pop_lvl,

    // 状态输出 (每级一组)
    output wire [3:0]         o_valid,          // [l] = 该级非空
    output wire [3:0]         o_full,           // [l] = 该级已满
    output wire [CNT_W-1:0]   o_cnt,            // [l] = 该级深度
    output wire [4*IDX_W-1:0] o_head_idx,       // 各级队头索引 (4 级 × IDX_W)
    output wire [4*AGING_W-1:0] o_head_age      // 各级队头年龄
);

    // ------------------------------------------------------------------
    // 存储阵列 (4 级 × DEPTH)
    // ------------------------------------------------------------------
    localparam DEPTH_S = (DEPTH < 16) ? 16 : DEPTH;

    reg [IDX_W-1:0]   mem   [0:4*DEPTH_S-1];
    reg [AGING_W-1:0] age_m [0:4*DEPTH_S-1];

    reg [CNT_W-1:0]   head  [0:3];
    reg [CNT_W-1:0]   tail  [0:3];
    reg [CNT_W-1:0]   cnt   [0:3];
    reg [CNT_W-1:0]   free  [0:3];
    reg [AGING_W-1:0] age_r [0:3];

    // ------------------------------------------------------------------
    // 复位
    // ------------------------------------------------------------------
    integer k;
    initial begin
        for (k = 0; k < 4*DEPTH_S; k = k + 1) begin
            mem[k]   = {(IDX_W){1'b0}};
            age_m[k] = {(AGING_W){1'b0}};
        end
        head[0] = 0; head[1] = 0; head[2] = 0; head[3] = 0;
        tail[0] = 0; tail[1] = 0; tail[2] = 0; tail[3] = 0;
        cnt[0]  = 0; cnt[1]  = 0; cnt[2]  = 0; cnt[3]  = 0;
        free[0] = DEPTH; free[1] = DEPTH; free[2] = DEPTH; free[3] = DEPTH;
        age_r[0] = 0; age_r[1] = 0; age_r[2] = 0; age_r[3] = 0;
    end

    // ------------------------------------------------------------------
    // 指针推进
    // ------------------------------------------------------------------
    function [CNT_W-1:0] pntx;
        input [CNT_W-1:0] p;
        begin
            if (p + 1 == DEPTH_S) pntx = 0;
            else                  pntx = p + 1;
        end
    endfunction

    // ------------------------------------------------------------------
    // 各级出队 / 入队标志
    // ------------------------------------------------------------------
    wire pop0 = i_pop && (i_pop_lvl == 2'd0);
    wire pop1 = i_pop && (i_pop_lvl == 2'd1);
    wire pop2 = i_pop && (i_pop_lvl == 2'd2);
    wire pop3 = i_pop && (i_pop_lvl == 2'd3);

    wire push0 = i_push && (i_prio == 2'd0);
    wire push1 = i_push && (i_prio == 2'd1);
    wire push2 = i_push && (i_prio == 2'd2);
    wire push3 = i_push && (i_prio == 2'd3);

    // ------------------------------------------------------------------
    // 队头年龄: 非空则 +1 (饱和), 出队或转空则清零
    //   单主控下队头就是最早到达且未被弹出的条目, 故 age_r 即精确队头年龄。
    // ------------------------------------------------------------------
    wire lvl0_idle = (cnt[0] == 0) || pop0;
    wire lvl1_idle = (cnt[1] == 0) || pop1;
    wire lvl2_idle = (cnt[2] == 0) || pop2;
    wire lvl3_idle = (cnt[3] == 0) || pop3;

    always @(posedge clk) begin
        if (!rst_n) begin
            age_r[0] <= {(AGING_W){1'b0}};
            age_r[1] <= {(AGING_W){1'b0}};
            age_r[2] <= {(AGING_W){1'b0}};
            age_r[3] <= {(AGING_W){1'b0}};
        end else begin
            if (lvl0_idle) age_r[0] <= {(AGING_W){1'b0}};
            else if (age_r[0] != {(AGING_W){1'b1}}) age_r[0] <= age_r[0] + 1;
            if (lvl1_idle) age_r[1] <= {(AGING_W){1'b0}};
            else if (age_r[1] != {(AGING_W){1'b1}}) age_r[1] <= age_r[1] + 1;
            if (lvl2_idle) age_r[2] <= {(AGING_W){1'b0}};
            else if (age_r[2] != {(AGING_W){1'b1}}) age_r[2] <= age_r[2] + 1;
            if (lvl3_idle) age_r[3] <= {(AGING_W){1'b0}};
            else if (age_r[3] != {(AGING_W){1'b1}}) age_r[3] <= age_r[3] + 1;
        end
    end

    // ------------------------------------------------------------------
    // 状态推进 (指针 / 计数)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            head[0] <= 0; tail[0] <= 0;
            head[1] <= 0; tail[1] <= 0;
            head[2] <= 0; tail[2] <= 0;
            head[3] <= 0; tail[3] <= 0;
            cnt[0]  <= 0; free[0] <= DEPTH;
            cnt[1]  <= 0; free[1] <= DEPTH;
            cnt[2]  <= 0; free[2] <= DEPTH;
            cnt[3]  <= 0; free[3] <= DEPTH;
        end else begin
            // 级 0
            if (push0 && !pop0) begin cnt[0] <= cnt[0] + 1; free[0] <= free[0] - 1; end
            else if (!push0 && pop0) begin cnt[0] <= cnt[0] - 1; free[0] <= free[0] + 1; end
            if (push0) begin mem[0*DEPTH_S + tail[0]] <= i_idx; age_m[0*DEPTH_S + tail[0]] <= 0; tail[0] <= pntx(tail[0]); end
            if (pop0)  head[0] <= pntx(head[0]);
            // 级 1
            if (push1 && !pop1) begin cnt[1] <= cnt[1] + 1; free[1] <= free[1] - 1; end
            else if (!push1 && pop1) begin cnt[1] <= cnt[1] - 1; free[1] <= free[1] + 1; end
            if (push1) begin mem[1*DEPTH_S + tail[1]] <= i_idx; age_m[1*DEPTH_S + tail[1]] <= 0; tail[1] <= pntx(tail[1]); end
            if (pop1)  head[1] <= pntx(head[1]);
            // 级 2
            if (push2 && !pop2) begin cnt[2] <= cnt[2] + 1; free[2] <= free[2] - 1; end
            else if (!push2 && pop2) begin cnt[2] <= cnt[2] - 1; free[2] <= free[2] + 1; end
            if (push2) begin mem[2*DEPTH_S + tail[2]] <= i_idx; age_m[2*DEPTH_S + tail[2]] <= 0; tail[2] <= pntx(tail[2]); end
            if (pop2)  head[2] <= pntx(head[2]);
            // 级 3
            if (push3 && !pop3) begin cnt[3] <= cnt[3] + 1; free[3] <= free[3] - 1; end
            else if (!push3 && pop3) begin cnt[3] <= cnt[3] - 1; free[3] <= free[3] + 1; end
            if (push3) begin mem[3*DEPTH_S + tail[3]] <= i_idx; age_m[3*DEPTH_S + tail[3]] <= 0; tail[3] <= pntx(tail[3]); end
            if (pop3)  head[3] <= pntx(head[3]);
        end
    end


    // ------------------------------------------------------------------
    // 输出
    // ------------------------------------------------------------------
    assign o_valid[0]  = (cnt[0] != 0);
    assign o_valid[1]  = (cnt[1] != 0);
    assign o_valid[2]  = (cnt[2] != 0);
    assign o_valid[3]  = (cnt[3] != 0);

    assign o_full[0]   = (free[0] == 0);
    assign o_full[1]   = (free[1] == 0);
    assign o_full[2]   = (free[2] == 0);
    assign o_full[3]   = (free[3] == 0);

    assign o_cnt       = {cnt[3], cnt[2], cnt[1], cnt[0]};

    assign o_head_idx  = {mem[3*DEPTH_S + head[3]], mem[2*DEPTH_S + head[2]],
                          mem[1*DEPTH_S + head[1]], mem[0*DEPTH_S + head[0]]};

    assign o_head_age  = {age_r[3], age_r[2], age_r[1], age_r[0]};

endmodule
