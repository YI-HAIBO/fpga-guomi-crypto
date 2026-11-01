// =============================================================================
// 存根调度器: 用于 v1.5 全系统综合快速验证
// 功能: 直通命令 -> 结果 (1 拍延迟), 不含真实引擎
// =============================================================================
`timescale 1ns / 1ps

module crypto_sched_subsys_stub (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         cmd_vld,
    output wire         cmd_rdy,
    input  wire [7:0]   cmd_rid,
    input  wire [3:0]   cmd_op,
    input  wire [1:0]   cmd_prio,
    input  wire [511:0] cmd_ia,
    input  wire [511:0] cmd_ib,
    input  wire [255:0] cmd_ic,
    output wire         res_vld,
    input  wire         res_rdy,
    output wire [7:0]   res_rid,
    output wire [7:0]   res_err,
    output wire         res_ok,
    output wire [255:0] res_ra,
    output wire [255:0] res_rb
);
    reg cmd_d1 = 0;
    reg [7:0] rid_d1 = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_d1 <= 0;
            rid_d1 <= 0;
        end else begin
            cmd_d1 <= cmd_vld;
            rid_d1 <= cmd_rid;
        end
    end

    assign cmd_rdy = 1'b1;
    assign res_vld = cmd_d1;
    assign res_rid = rid_d1;
    assign res_err = 8'h00;
    assign res_ok = 1'b1;
    assign res_ra = 256'h0;
    assign res_rb = 256'h0;

endmodule