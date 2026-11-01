//=============================================================================
// File:      rtl/subsys/arbiter.v
// Project:   fpga-guomi-crypto (GM-CRYPTO-COORD-2026)
// Version:   v1.2 (Phase 2.7 / SS2 scheduler)
// Author:    Yi Haibo
// Platform:  Xilinx Artix-7 / Vivado (target: Intel Agilex 7 for production)
// Synthesis: Vivado 2023.2
//
// 模块职责 (SS2 / M08):
//   加权优先级 + 老化提升仲裁器:
//     1) 老化提升 (防饥饿): 某级队头年龄 >= AGING_THRESHOLD (默认 1e6 ns = 1ms)
//        视为"饿死了", 该级被提升为强制最高优先级, 覆盖静态优先级。
//     2) 静态优先级 (默认): 老化未触发时, lvl0 > lvl1 > lvl2 > lvl3 出队。
//     3) 同级加权公平: 同一时刻有多级"选中候选"(e.g. 老化触发 2 级),
//        用 2-bit 轮转计数器 rrot 在候选里做加权公平, 防止某一级永远抢。
//
// 关键契约:
//   o_pop 是 **单拍寄存器脉冲** (不是电平)。FSM:
//     S_IDLE   : 采样组合量 pick_comb, 若为 1, 打一拍 o_pop=1 并跳 S_POP
//     S_POP    : o_pop=1, o_pop_lvl 保持选中 lvl; 下一拍回 S_IDLE
//   这样 prio_queue 每拍最多收到 1 次弹请求, 与 cnt 语义一致。
//
// 输入 (来自 prio_queue):
//   i_valid[3:0]  : 每级是否有命令待出队
//   i_head_age[4*AGING_W-1:0]: 每级队头年龄 (cycles), lvl0 在 bit[AGING_W-1:0]
//
// 输出:
//   o_pop[1]      : 单拍脉冲, 触发出队
//   o_pop_lvl[1:0]: 选中的级别 (0..3, 越小优先级越高)
//   o_aging_hit[3:0]: 供 TB 观察每级老化触发状态
//
// 版本历史:
//   v1.2 2026-10-03 把 o_pop 改成 FSM 单拍脉冲 (原 v1.1 是电平, 导致
//           prio_queue 每拍都在弹, cnt 从 0 减到 15 溢出 —— 根因坐实)
//   v1.1 2026-10-03 修正轮转位运算; 用 case 展开真轮转
//   v1.0 2026-10-03 首版
//=============================================================================

`timescale 1ns / 1ps

module arbiter #(
    parameter AGING_W         = 14,
    parameter AGING_THRESHOLD = 1000000
) (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire [3:0]               i_valid,
    input  wire [4*AGING_W-1:0]     i_head_age,

    output reg                      o_pop,
    output reg  [1:0]               o_pop_lvl,

    output wire [3:0]               o_aging_hit
);

    // ---- FSM ----
    localparam S_IDLE = 1'b0;
    localparam S_POP  = 1'b1;
    reg        st_r;

    // ---- 老化判定 ----
    wire [AGING_W-1:0] age0 = i_head_age[        AGING_W-1:        0];
    wire [AGING_W-1:0] age1 = i_head_age[     2*AGING_W-1:  AGING_W];
    wire [AGING_W-1:0] age2 = i_head_age[     3*AGING_W-1:2*AGING_W];
    wire [AGING_W-1:0] age3 = i_head_age[     4*AGING_W-1:3*AGING_W];

    wire [3:0] aging_hit;
    assign aging_hit[0] = (age0 >= AGING_THRESHOLD) & i_valid[0];
    assign aging_hit[1] = (age1 >= AGING_THRESHOLD) & i_valid[1];
    assign aging_hit[2] = (age2 >= AGING_THRESHOLD) & i_valid[2];
    assign aging_hit[3] = (age3 >= AGING_THRESHOLD) & i_valid[3];

    assign o_aging_hit = aging_hit;

    // ---- 老化候选轮转 (真轮转) ----
    reg [1:0] rrot;

    wire [3:0] aged_rot4;
    assign aged_rot4 = (rrot == 2'd0) ? aging_hit :
                       (rrot == 2'd1) ? {aging_hit[0], aging_hit[3:1]} :
                       (rrot == 2'd2) ? {aging_hit[1:0], aging_hit[3:2]} :
                                        {aging_hit[2:0], aging_hit[3]};

    wire        aged_any  = |aged_rot4;
    wire [1:0] aged_pick_rel = aged_rot4[0] ? 2'd0 :
                               aged_rot4[1] ? 2'd1 :
                               aged_rot4[2] ? 2'd2 : 2'd3;
    wire [1:0] aged_lvl_real = (rrot + aged_pick_rel) & 2'b11;

    // ---- 正常候选 (未老化): 静态优先级 0 > 1 > 2 > 3 ----
    wire [3:0] normal_mask = i_valid & ~aging_hit;
    wire        normal_any  = |normal_mask;
    wire [1:0] normal_pick = normal_mask[0] ? 2'd0 :
                             normal_mask[1] ? 2'd1 :
                             normal_mask[2] ? 2'd2 : 2'd3;

    // ---- 组合选择 (纯组合, 供 FSM 采样) ----
    wire        pick_aged   = aged_any;
    wire        pick_normal = !aged_any && normal_any;
    wire        pick_comb   = pick_aged || pick_normal;
    wire [1:0]  pick_lvl_comb = pick_aged ? aged_lvl_real : normal_pick;

    // ---- FSM 推进 + 打拍输出 ----
    // 单拍脉冲: S_IDLE 采样 pick_comb, 若为 1 则跳 S_POP 并置 o_pop=1;
    // S_POP 保留 o_pop=1 一拍 (供 prio_queue 采样), 回 S_IDLE 时清零。
    // 关键: 每个分支都必须显式覆盖 o_pop / o_pop_lvl, 否则 NBA 保留旧值。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_r      <= S_IDLE;
            o_pop     <= 1'b0;
            o_pop_lvl <= 2'd0;
            rrot      <= 2'd0;
        end else begin
            case (st_r)
                S_IDLE: begin
                    if (pick_comb) begin
                        // 检测到待弹命令: 立即置 pop, 下一拍进入 S_POP
                        st_r      <= S_POP;
                        o_pop     <= 1'b1;
                        o_pop_lvl <= pick_lvl_comb;
                        // 只在纯老化路径推进 rrot (加权公平)
                        if (pick_aged && !pick_normal)
                            rrot <= rrot + 2'd1;
                    end else begin
                        st_r      <= S_IDLE;
                        o_pop     <= 1'b0;
                        o_pop_lvl <= 2'd0;
                    end
                end
                S_POP: begin
                    // 保持 o_pop=1 一拍 (供 prio_queue 在下一个 posedge 采样),
                    // 然后回 S_IDLE, 下一拍把 o_pop 清零
                    st_r      <= S_IDLE;
                    o_pop     <= 1'b0;
                    o_pop_lvl <= 2'd0;
                end
                default: begin
                    st_r      <= S_IDLE;
                    o_pop     <= 1'b0;
                    o_pop_lvl <= 2'd0;
                end
            endcase
        end
    end

endmodule
