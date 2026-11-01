// =============================================================================
// 模块名称 : sm2_modaddsub
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0  (方案 C: 紧凑时序化 SM2 的共享模加减器)
// 日期     : 2026-10-22
// 视角     : rtl-designer
// 功能     : 256-bit 模加 / 模减 (Montgomery 域下与普通域完全一致)
//            1 拍吞吐量: req 当拍锁存操作数, 下一拍 done=1 且 r 有效。
//            所有调用点 (f_add/f_sub/f_a2/f_a4/f_a8) 合并到本模块,
//            取代 sm2_point_add 内 ~20 个内联加法器, 大幅降面积/降扇出。
//
// 域约定: 全部端口为 Montgomery 形式; 模 p = sm2p256v1 素数。
//   ADD(a,b) = (a+b) mod p
//   SUB(a,b) = (a-b) mod p
// =============================================================================

`timescale 1ns / 1ps

module sm2_modaddsub (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         req,           // 启动 (1 拍)
    input  wire         op_sel,        // 0 = 模加, 1 = 模减
    input  wire [255:0] a,
    input  wire [255:0] b,
    output reg  [255:0] r,             // 结果 (Montgomery 形式)
    output reg          done           // 完成脉冲 (1 拍, 与 r 同拍)
);

    localparam [255:0] PP = 256'hfffffffeffffffffffffffffffffffffffffffff00000000ffffffffffffffff;

    reg  [256:0] e;
    reg          op_sel_r;
    reg  [255:0] a_r, b_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r        <= 256'd0;
            done     <= 1'b0;
            op_sel_r <= 1'b0;
            a_r      <= 256'd0;
            b_r      <= 256'd0;
        end else begin
            // 1 拍延迟: 当拍锁存, 下拍出结果
            a_r      <= a;
            b_r      <= b;
            op_sel_r <= op_sel;
            done     <= req;
            if (req) begin
                if (op_sel == 1'b0) begin          // 模加
                    e = {1'b0, a} + {1'b0, b};
                    r <= ((e[256] == 1'b1) || (e[255:0] >= PP)) ? (e[255:0] - PP) : e[255:0];
                end else begin                       // 模减
                    e = {1'b0, a} - {1'b0, b};
                    r <= (e[256] == 1'b1) ? (e[255:0] + PP) : e[255:0];
                end
            end
        end
    end

endmodule
