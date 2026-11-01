// =============================================================================
// 模块名称 : cmd_parser
// 模块编号 : M06 (SS2 - Command Scheduler, 见 phase1/架构与模块划分说明书_v1.md §2.2)
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-03
// 视角     : rtl-designer (葛逻辑)
// 时钟     : clk_l400 (与 SS2 全模块同源同频, 无 CDC)
//
// 功能     : GM-CP 命令解析与合法性校验。
//            在命令进入队列/路由之前做一次纯组合的参数体检, 把非法命令
//            挡在引擎之外 —— 引擎一拍都不用占。校验结论分两路输出:
//              o_legal   : 1 拍脉冲, 命令合法, 送 prio_queue 正常入队
//              o_illegal : 1 拍脉冲, 命令非法, 送 err_path 直接返回错误码
//
// 校验规则 (对应错误码) :
//   ERR_ILLEGAL_OP = 8'h02  op 不在 {0..6}, 即不是任何已实现的操作码
//   ERR_SM4_KEY    = 8'h11  SM4 密钥为 0 (零密钥无效)
//   ERR_SM2_SIGN   = 8'h21  SM2 签名私钥 d 非法: d == 0 或 d >= n
//   ERR_SM2_VER    = 8'h31  SM2 验签签名值非法: r 或 s 为 0 / >= n
//
// 说明     :
//   - SM2_SIGN 的 k 只做「非零」校验, 不卡 k < n。理由: 引擎 sm2_sign 内部
//     对 k 做的是 mod n 算术 (kG 与 k^-1 mod n 在 k >= n 时仍良定义), 只把
//     k == 0 / k == n 判为非法; 与引擎语义保持一致, 避免解析层把引擎能算的
//     命令错杀。k 是否落在 [1, n-1) 由调度层的「重选 k」机制兜底。
//   - 解析是纯组合的, 一拍内出结论。o_legal / o_illegal 互斥。
//
// 编译     : iverilog -g2005
// =============================================================================

`timescale 1ns / 1ps

module cmd_parser (
    input  wire         clk,
    input  wire         rst_n,

    // 命令输入 (握手; i_rdy 在本模块内部恒为 1, 反压由上层负责)
    input  wire         i_vld,
    output wire         i_rdy,
    input  wire [3:0]   i_op,
    input  wire [7:0]   i_rid,
    input  wire [1:0]   i_prio,
    input  wire [511:0] i_ia,
    input  wire [511:0] i_ib,
    input  wire [255:0] i_ic,

    // 校验结论 (两路互斥, 均为 1 拍脉冲)
    output wire         o_legal,
    output wire         o_illegal,
    output wire [7:0]   o_err,

    // 命令字透传 (o_legal / o_illegal 当拍有效)
    output wire [3:0]   o_op,
    output wire [7:0]   o_rid,
    output wire [1:0]   o_prio
);

    // ------------------------------------------------------------------
    // 错误码
    // ------------------------------------------------------------------
    localparam [7:0] ERR_ILLEGAL_OP = 8'h02;
    localparam [7:0] ERR_SM4_KEY    = 8'h11;
    localparam [7:0] ERR_SM2_SIGN   = 8'h21;
    localparam [7:0] ERR_SM2_VER    = 8'h31;

    // SM2 群阶 n (与 rtl/sm2/sm2_sign.v 的 NN 常量严格一致)
    localparam [255:0] NN = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123;

    // ------------------------------------------------------------------
    // 操作码分类
    // ------------------------------------------------------------------
    wire is_sm4   = (i_op == 4'h0) || (i_op == 4'h1);
    wire is_sm2_s = (i_op == 4'h5);
    wire is_sm2_v = (i_op == 4'h6);
    wire op_ok    = (i_op <= 4'h6);

    // ------------------------------------------------------------------
    // 分字段校验 (参数按「低半字对齐」约定解包)
    //   SM4_ENC/DEC : ia 低 128 = key, ib 低 128 = pt/ct
    //   SM2_SIGN    : ia = d, ib = e, ic = k
    //   SM2_VER     : ia = {qx, qy}, ib = {e, r}, ic = s
    // ------------------------------------------------------------------
    wire [127:0] key      = i_ia[127:0];
    wire         k_nonz   = (i_ic != 256'd0);
    wire         d_ok     = (i_ia != 256'd0) && (i_ia < NN);
    wire         rs_ok    = (i_ib[127:0] != 256'd0) && (i_ib[127:0] < NN) &&
                            (i_ic   != 256'd0) && (i_ic   < NN);

    wire [7:0] field_err  = !op_ok      ? ERR_ILLEGAL_OP :
                            (is_sm4 && (key == 128'd0)) ? ERR_SM4_KEY :
                            (is_sm2_s && !d_ok)          ? ERR_SM2_SIGN :
                            (is_sm2_s && !k_nonz)        ? ERR_SM2_SIGN :
                            (is_sm2_v && !rs_ok)         ? ERR_SM2_VER :
                            8'h00;

    assign o_legal   = i_vld && (field_err == 8'h00);
    assign o_illegal = i_vld && (field_err != 8'h00);

    assign i_rdy = 1'b1;      // 解析无代价, 反压由上层按队列/实例占用施加
    assign o_err = field_err;

    // 命令字透传 (与校验同拍, 纯组合)
    assign o_op   = i_op;
    assign o_rid  = i_rid;
    assign o_prio = i_prio;

endmodule
