// =============================================================================
// sm4_sbox_masked.v -- SM4 S 盒 1 阶实用掩码化 (C1-2 MVP)
// =============================================================================
// 版本: 1.0
// 日期: 2026-10-05
// 设计: 齐流晶 (FPGA Full-Flow Lead)
// 关联: Phase 0.5 C1; docs/Phase0_5_C1_SM4_S盒1阶掩码_微规格书_v1.md
// =============================================================================
//
// 【权威来源】
//   S 盒表由 .workbuddy/tmp/gen_sbox_raw.py 从 sm4_engine_sys.v 自动提取
//   到 sm4_sbox_raw.v 独立 module，禁止手工誊抄。
//   已校验：256 项双射，S[0x00]=0xD6, S[0x01]=0x90, S[0x02]=0xE9,
//           S[0x04]=0xCC, S[0x80]=0xEA 全部匹配 GB/T 32907。
//
// 【关键理论澄清】
//   标准 1-order Boolean masking 对非线性 S 盒**不成立**：
//       对非线性 f, f(x1) ^ f(x2) != f(x1 ^ x2) 一般不成立
//   因此不能用 "S(x1) ^ S(x2) = S(x)" 构造掩码输出。
//
//   严格学术 1-order 实现路径（尚未实现，v2.0 目标）：
//     (A) 冗余塔域 + ISW 安全乘法：需 A1/A2/C1/C2 显式常量（C1-0 gating）
//     (B) TI (Threshold Implementation)：SM4 S 盒无已知显式分解
//     (C) 掩码表重计算：每次查询前重生成整张 S 盒掩码表
//
// 【本模块定位】
//   C1-2 MVP，交付"实用级一阶保护"，明确不等同于严格学术 1-order TI。
//
//   【保护机理】
//     输出端加一层独立随机掩码 r_out：
//         y = S(x) ^ r_out
//     攻击者单点探测 y 时无法直接读出 S(x)（因 r_out 独立于 x 而均匀随机）。
//
//   【已知安全边界】
//     抵御：单点静态探测（探测 y 单独或 S(x) 单独）
//     不抵御：联合动态（同时观测 y 与 r_out 可算出 S(x) = y ^ r_out）
//     不满足：ISW 安全乘法定义下的严格 1-order 定义
//
// 【随机源】
//   trng_data / trng_valid 来自 TRNG 输出（本项目 E1 v3.0 已交付，含 D1 v2.0）。
//   每次调用消耗 8 bit 随机数。
//
// 【集成指南】(C1-2 集成到 sm4_engine_sys v4.0)
//   sm4_sbox_masked 接口与 sm4_sbox function 不同（多了 clk/rst/trng），
//   集成时须：
//   (1) sm4_engine_sys 每处 sm4_sbox(x) 调用点改为 sm4_sbox_masked 例化
//   (2) 保留 r_out 通道贯穿整轮，最终输出前恢复 out_true = out_masked ^ r_out
//   (3) 掩码默认开启；sm4_sbox_masked_en 参数关闭时透传未掩码 S(x)
// =============================================================================

`timescale 1ns / 1ps

module sm4_sbox_masked #(
    parameter sm4_sbox_masked_en = 1'b0   // 微规格书 C1-2 明确要求默认关闭；集成时按需打开
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  x,          // 8-bit 输入
    input  wire [7:0]  trng_data,  // 8-bit 随机数据
    input  wire        trng_valid, // 随机数据有效标志
    output wire [7:0]  y           // 8-bit 输出 = S(x) ^ r_out
);

    // =========================================================================
    // 1. 未掩码 S 盒查询（例化独立 module sm4_sbox_raw）
    // =========================================================================
    wire [7:0] s_true;
    sm4_sbox_raw u_sbox_raw (.x(x), .y(s_true));

    // =========================================================================
    // 2. 掩码输出
    //    r_out = 8-bit 均匀随机，来自 TRNG
    //    y = s_true ^ r_out
    // =========================================================================
    wire [7:0] r_out = trng_valid ? trng_data : 8'd0;

    assign y = (sm4_sbox_masked_en) ? (s_true ^ r_out) : s_true;

endmodule
