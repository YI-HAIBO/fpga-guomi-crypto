// =============================================================================
// 模块名称 : sm4_engine_sys_multi
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0 (多实例部署验证)
// 日期     : 2026-10-04
// 视角     : rtl-designer (葛逻辑)
// 功能     : N 个 sm4_engine_sys v4.0 并行实例, 共享时钟, 独立运行
//           用于验证多实例部署的资源上限和功能正确性
//
// 用法:
//   - parameter NUM_INSTANCES = 4  (默认 4 个实例)
//   - 每个实例有独立的 start/key/plaintext/decrypt 输入和 done/result/busy 输出
//   - 所有实例共享 clk/rst_n
//
// 参考: sm4_engine_sys.v v4.0 (16-stage × 2 轮 + 2-keywords/cycle)
// =============================================================================

`timescale 1ns / 1ps

module sm4_engine_sys_multi #(
    parameter NUM_INSTANCES = 4
) (
    input  wire         clk,
    input  wire         rst_n,

    // Per-instance inputs (packed arrays)
    input  wire [NUM_INSTANCES-1:0] start,
    input  wire [NUM_INSTANCES-1:0] decrypt,
    input  wire [NUM_INSTANCES*128-1:0] keys,
    input  wire [NUM_INSTANCES*128-1:0] plaintexts,

    // Per-instance outputs (packed arrays)
    output wire [NUM_INSTANCES-1:0] done,
    output wire [NUM_INSTANCES-1:0] busy,
    output wire [NUM_INSTANCES*128-1:0] results
);

    genvar i;
    generate
        for (i = 0; i < NUM_INSTANCES; i = i + 1) begin : inst
            sm4_engine_sys u_engine (
                .clk       (clk),
                .rst_n     (rst_n),
                .start     (start[i]),
                .key       (keys[i*128 +: 128]),
                .plaintext (plaintexts[i*128 +: 128]),
                .decrypt   (decrypt[i]),
                .ciphertext(plaintexts[i*128 +: 128]),
                .result    (results[i*128 +: 128]),
                .done      (done[i]),
                .busy      (busy[i])
            );
        end
    endgenerate

endmodule
