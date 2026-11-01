// =============================================================================
// sm4_engine_masked_v4_wrapper -- compatibility wrapper
// F4 决策 2026-11-01: 板级 DUT 切换为 sm4_engine_masked_v4_indep 后,
// 旧 TB (tb_sm4_engine_masked_v4.v) 仍实例化 sm4_engine_masked_v4。
// 本 wrapper 提供同名同端口的 drop-in 替身, 使旧 TB 无需修改即可
// 验证 v4_indep 的加密/解密正确性 (端口完全一致, 行为等价)。
// =============================================================================
`timescale 1ns / 1ps

module sm4_engine_masked_v4 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [127:0] key,
    input  wire [127:0] plaintext,
    input  wire         decrypt,
    input  wire [127:0] ciphertext,
    input  wire         masked_en,
    input  wire [63:0]  mask_seed,
    output wire [127:0] result,
    output wire         done,
    output wire         busy
);
    sm4_engine_masked_v4_indep dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .key(key), .plaintext(plaintext), .decrypt(decrypt), .ciphertext(ciphertext),
        .result(result), .done(done), .busy(busy),
        .masked_en(masked_en), .mask_seed(mask_seed)
    );
endmodule