// =============================================================================
// sm4_engine_sys_masked_wrapper.v -- SM4 引擎输出掩码 wrapper (C1-2b POC)
// =============================================================================
// 版本: 1.0
// 日期: 2026-10-05
// 设计: 齐流晶 (FPGA Full-Flow Lead)
// 关联: Phase 0.5 C1-2b（C1-2 MVP 端到端集成 POC）
//       docs/Phase0_5_C1_SM4_S盒1阶掩码_微规格书_v1.md §6.1
// =============================================================================
//
// 【定位】
//   本模块是 sm4_engine_sys 的**输出掩码 wrapper**，不修改引擎内部结构。
//
//   与 C1-2 (sm4_sbox_masked) 的**本质区别**：
//   - sm4_sbox_masked：S 盒级掩码，每 S 盒调用消耗 8 bit 随机，
//                      保护 S 盒内部中间值（但对整个 S 盒查询结果的
//                      联合观测不抵御）
//   - 本模块：引擎级输出掩码，每次加密消耗 128 bit 随机，
//             保护最终 result 总线（对整块密文 probing 有效）
//
//   两者是**互补关系**：本 wrapper 提供总线级保护，S 盒级保护由
//   后续 C1-5（sm4_engine_sys 内部 advance_2_rounds 集成 sm4_sbox_masked）
//   完成。
//
// 【保护机理】
//   wrapper 在 sm4_engine_sys.result 输出前 XOR 一层 128-bit 随机：
//       wrapper_result = engine_result ^ r_block
//   r_block 来自 TRNG（128 bit / 次），每次 start 时刷新一次。
//
//   解码端需要知道 r_block 才能恢复真实密文，因此需要 r_block 传递机制：
//   - 方案 1：r_block 从 wrapper 额外输出（wrapper 增加 r_out 端口）
//   - 方案 2：r_block 与密文同时通过 DMA 传递
//   - 方案 3：对称密钥派生（本次 POC 未实现）
//
// 【接口】
//   与原 sm4_engine_sys 完全兼容，新增：
//     - wrapper_masked_en（参数）：默认 1'b0（关闭时零回归）
//     - trng_data[127:0]（输入）：TRNG 随机数据
//     - trng_valid（输入）：TRNG 有效标志
//     - r_out[127:0]（输出）：本次加密使用的随机掩码
//
// 【使用】
//   - 掩码关闭（wrapper_masked_en=0）：wrapper_result == engine_result，r_out=0
//   - 掩码开启（wrapper_masked_en=1）：wrapper_result == engine_result ^ r_out
//   - r_out 在 done 时锁存（对应本次加密）
//
// 【安全边界】
//   - ✅ 抵御：单点静态探测 result 总线
//   - ✅ 抵御：SPA 对最终密文的直接攻击
//   - ❌ 不抵御：对 engine_result 内部中间值的探测
//   - ❌ 不满足：S 盒内部严格 1-order 保护
// =============================================================================

`timescale 1ns / 1ps

module sm4_engine_sys_masked_wrapper #(
    parameter wrapper_masked_en = 1'b0   // 1=输出掩码开，0=透传（默认，零回归）
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [127:0] key,
    input  wire [127:0] plaintext,
    input  wire         decrypt,
    input  wire [127:0] ciphertext,

    input  wire [127:0] trng_data,   // 128-bit 随机数据（来自 TRNG）
    input  wire         trng_valid,  // TRNG 有效标志

    output wire [127:0] result,      // 掩码后（或未掩码）的结果
    output wire [127:0] r_out,       // 本次加密使用的掩码（可空）
    output wire         done,
    output wire         busy
);

    // =========================================================================
    // 内部信号：引擎未掩码输出
    // =========================================================================
    wire [127:0] engine_result;
    wire         engine_done;
    wire         engine_busy;

    // =========================================================================
    // 例化 sm4_engine_sys
    // =========================================================================
    sm4_engine_sys u_engine (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .key(key),
        .plaintext(plaintext),
        .decrypt(decrypt),
        .ciphertext(ciphertext),
        .result(engine_result),
        .done(engine_done),
        .busy(engine_busy)
    );

    // =========================================================================
    // 掩码寄存器：每次 start 时从 trng_data 采样一次
    // =========================================================================
    reg [127:0] r_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_reg <= 128'd0;
        end else if (start && trng_valid) begin
            r_reg <= trng_data;
        end
    end

    // =========================================================================
    // done 寄存器（把脉冲 done 保持到下一次 start）
    //   原因：TB 用 while(!done) 等待，脉冲 done 会导致循环卡死。
    // =========================================================================
    reg done_reg = 1'b0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_reg <= 1'b0;
        end else begin
            if (engine_done) done_reg <= 1'b1;
            else if (start) done_reg <= 1'b0;
        end
    end

    // =========================================================================
    // 输出：纯组合 XOR
    //   engine_result 在 done 拉高后保持稳定（data_out 寄存器），
    //   直接 XOR r_reg 即可。不需要 result_reg 锁存，避免 NBA 时序陷阱。
    // =========================================================================
    assign result = wrapper_masked_en ? (engine_result ^ r_reg) : engine_result;
    assign r_out  = wrapper_masked_en ? r_reg : 128'd0;

    // =========================================================================
    // 透传控制信号
    // =========================================================================
    assign done = done_reg;
    assign busy = engine_busy;

endmodule
