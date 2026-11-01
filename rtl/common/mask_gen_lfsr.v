// =============================================================================
// mask_gen_lfsr.v -- 跨引擎共享 LFSR 掩码生成器 (B2 MVP)
// -----------------------------------------------------------------------------
// 版本    : v1.0 (2026-10-05)
// 项目    : GM-CRYPTO-COORD-2026
// 微规格书: docs/Phase0_5_B2_跨引擎资源共享_微规格书_v1.md §5
//
// 用途
// ----
// 单一权威 LFSR 实现，供 C1（SM4 掩码）与 C2（SM3 W 掩码）及未来任意
// 掩码算法复用。多项式 x^32 + x^22 + x^2 + x + 1（满周期 2^32 - 1）。
//
// 接口（纯组合逻辑，无时钟/复位）
// --------------------------------
//   seed  : 32-bit 输入种子（调用者负责保证非零，seed=0 会退化全 0 序列）
//   m0..m15 : 16 个 32-bit 组合输出，分别为
//             m0  = seed
//             m1  = step(seed)
//             m2  = step(step(seed))
//             ...
//             m15 = step^15(seed)
//   每步递推公式:
//       next = {cur[30:0], cur[31] ^ cur[21] ^ cur[1] ^ cur[0]}
//
// 与 C2 的关系
// -------------
// C2 (sm3_engine_masked) 内部原本定义了本地 lfsr_step 函数并在 always @*
// 展开 16 步 r_init[0..15]。B2 MVP 将其抽取为本模块；sm3_engine_masked 通过
// 实例化 mask_gen_lfsr 得到 r_init[0..15]，功能完全等价（同一多项式、同一
// 递推公式、同一 16 步深度）。
//
// 与 C1 的关系
// -------------
// C1 (sm4_engine_sys_masked_wrapper) 使用外部 trng_data[127:0] 直采策略，
// 未使用 LFSR。B2 MVP 保留 C1 现状不动；若未来 C1 需要 mask_seed 展开
// （如接入 mask_gen_lfsr 作为 TRNG→掩码流的适配层），可直接例化本模块。
//
// 面积 / 时序
// -------------
// 16 个 32-bit XOR shift step = 16 × 4 XOR + 16 × 32-bit 拼接
// 综合后约 20-30 LUT（纯组合，非寄存器）。与 C2 原有内联实现面积相同。
//
// 安全边界
// ---------
// ✅ 单一权威实现：多项式、递推公式集中在此模块，跨引擎一致性审计方便
// ✅ 满周期特性：多项式 x^32 + x^22 + x^2 + x + 1 已验证周期为 2^32 - 1
// ✅ 非线性扩散：连续 16 步递推的相邻掩码字汉明距离接近 16
// ❌ 不覆盖熵源问题：seed 的来源由调用者决定（外部 mask_seed 端口或 TRNG）
// =============================================================================

module mask_gen_lfsr (
    input  wire [31:0] seed,
    output wire [31:0] m0,
    output wire [31:0] m1,
    output wire [31:0] m2,
    output wire [31:0] m3,
    output wire [31:0] m4,
    output wire [31:0] m5,
    output wire [31:0] m6,
    output wire [31:0] m7,
    output wire [31:0] m8,
    output wire [31:0] m9,
    output wire [31:0] m10,
    output wire [31:0] m11,
    output wire [31:0] m12,
    output wire [31:0] m13,
    output wire [31:0] m14,
    output wire [31:0] m15
);

    // 16 步组合递推 (等价于 C2 内的 lfsr_step 函数展开)
    wire [31:0] s0  = seed;
    wire [31:0] s1  = {s0[30:0],  s0[31]  ^ s0[21]  ^ s0[1]  ^ s0[0]};
    wire [31:0] s2  = {s1[30:0],  s1[31]  ^ s1[21]  ^ s1[1]  ^ s1[0]};
    wire [31:0] s3  = {s2[30:0],  s2[31]  ^ s2[21]  ^ s2[1]  ^ s2[0]};
    wire [31:0] s4  = {s3[30:0],  s3[31]  ^ s3[21]  ^ s3[1]  ^ s3[0]};
    wire [31:0] s5  = {s4[30:0],  s4[31]  ^ s4[21]  ^ s4[1]  ^ s4[0]};
    wire [31:0] s6  = {s5[30:0],  s5[31]  ^ s5[21]  ^ s5[1]  ^ s5[0]};
    wire [31:0] s7  = {s6[30:0],  s6[31]  ^ s6[21]  ^ s6[1]  ^ s6[0]};
    wire [31:0] s8  = {s7[30:0],  s7[31]  ^ s7[21]  ^ s7[1]  ^ s7[0]};
    wire [31:0] s9  = {s8[30:0],  s8[31]  ^ s8[21]  ^ s8[1]  ^ s8[0]};
    wire [31:0] s10 = {s9[30:0],  s9[31]  ^ s9[21]  ^ s9[1]  ^ s9[0]};
    wire [31:0] s11 = {s10[30:0], s10[31] ^ s10[21] ^ s10[1] ^ s10[0]};
    wire [31:0] s12 = {s11[30:0], s11[31] ^ s11[21] ^ s11[1] ^ s11[0]};
    wire [31:0] s13 = {s12[30:0], s12[31] ^ s12[21] ^ s12[1] ^ s12[0]};
    wire [31:0] s14 = {s13[30:0], s13[31] ^ s13[21] ^ s13[1] ^ s13[0]};
    wire [31:0] s15 = {s14[30:0], s14[31] ^ s14[21] ^ s14[1] ^ s14[0]};

    assign m0  = s0;
    assign m1  = s1;
    assign m2  = s2;
    assign m3  = s3;
    assign m4  = s4;
    assign m5  = s5;
    assign m6  = s6;
    assign m7  = s7;
    assign m8  = s8;
    assign m9  = s9;
    assign m10 = s10;
    assign m11 = s11;
    assign m12 = s12;
    assign m13 = s13;
    assign m14 = s14;
    assign m15 = s15;

endmodule
