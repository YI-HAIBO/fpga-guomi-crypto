// =============================================================================
// sm4_engine_masked_v3_wrapper.v -- B-5 P&R 时序签核专用顶层 wrapper (v3)
// =============================================================================
// 目的: 减少顶层端口数量以适配 xc7a200tsbg484-2 (285 IOB)
//   1. 内部化 sbox_mask_tbl_ext[2047:0] (省 2048 IBUF)
//   2. 数据总线 128bit → 32bit (省 4×96 = 384 IOB)
//   3. 观测端口保留 8bit
//
// 注意: 此 wrapper 仅用于综合/P&R 时序签核, 不用于功能仿真。
//       数据总线缩减为 32bit 后, 上层 96bit 接固定模式以保留核心逻辑。
// v1.0 (2026-10-08): 实例化 sm4_engine_masked_v3 (串行化架构)
// =============================================================================

`timescale 1ns / 1ps

module sm4_engine_masked_v3_wrapper (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [31:0]  key,            // 128bit → 32bit (缩减)
    input  wire [31:0]  plaintext,      // 128bit → 32bit
    input  wire         decrypt,
    input  wire [31:0]  ciphertext,     // 128bit → 32bit
    output wire [31:0]  result,         // 128bit → 32bit
    output wire         done,
    output wire         busy,
    input  wire         masked_en,
    input  wire         sbox_mask_ext_en,
    input  wire [7:0]   sbox_mask_c_ext,
    output wire [7:0]   sbox_addr_tap,
    output wire [7:0]   sbox_mask_c_tap,
    output wire         sbox_mask_valid,
    output wire         sbox_tbl_valid
);

    // ---- 内部化 sbox_mask_tbl_ext: tie to 0 ----
    wire [2047:0] sbox_mask_tbl_ext = 2048'h0;

    // ---- 128bit 内部总线: 低 32bit 接外部, 高 96bit 接固定模式 ----
    // 固定模式选 0xA5A5...A5: 非零, 避免被优化器当作常量消除
    wire [127:0] key_int       = {96'hA5A5A5A5A5A5A5A5A5A5A5A5A5A5A5A5, key};
    wire [127:0] plaintext_int = {96'hA5A5A5A5A5A5A5A5A5A5A5A5A5A5A5A5, plaintext};
    wire [127:0] ciphertext_int = {96'hA5A5A5A5A5A5A5A5A5A5A5A5A5A5A5A5, ciphertext};

    // 核心实例化 (v3.0: 串行化架构)
    sm4_engine_masked_v3 u_core (
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (start),
        .key               (key_int),
        .plaintext         (plaintext_int),
        .decrypt           (decrypt),
        .ciphertext        (ciphertext_int),
        .result            (result_int),
        .done              (done),
        .busy              (busy),
        .masked_en         (masked_en),
        .sbox_mask_ext_en  (sbox_mask_ext_en),
        .sbox_mask_c_ext   (sbox_mask_c_ext),
        .sbox_mask_tbl_ext (sbox_mask_tbl_ext),
        .sbox_addr_tap     (sbox_addr_tap),
        .sbox_mask_c_tap   (sbox_mask_c_tap),
        .sbox_mask_valid   (sbox_mask_valid),
        .sbox_tbl_valid    (sbox_tbl_valid)
    );

    // 输出: 仅低 32bit 暴露
    wire [127:0] result_int;
    assign result = result_int[31:0];

endmodule
