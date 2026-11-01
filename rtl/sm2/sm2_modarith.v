// =============================================================================
// 模块名称 : sm2_modarith
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-02
// 视角     : rtl-designer (葛逻辑)
// 功能     : SM2 曲线模算术 — 模加法/减法 (组合逻辑, 1 cycle)
// 曲线     : sm2p256v1 (GB/T 32918-2016)
//           p = 0xFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFF
// 时序     : 纯组合, 0 cycle 延迟 (适合 FSM 内嵌使用)
// =============================================================================

`timescale 1ns / 1ps

// =============================================================================
// 曲线素数 p (SM2 sm2p256v1)
// p = 2^256 - 2^224 + 2^192 + 2^96 - 1
// =============================================================================
`define SM2_P 256'hfffffffeffffffffffffffffffffffffffffffff00000000ffffffffffffffff

// =============================================================================
// 模加法: result = (a + b) mod p
// 组合逻辑: 256-bit 加法 + 条件减法
// =============================================================================
module sm2_modadd (
    input  wire [255:0] a,
    input  wire [255:0] b,
    output wire [255:0] result
);
    wire [256:0] sum_ext = {1'b0, a} + {1'b0, b};  // 257-bit to detect overflow
    wire [255:0] sum_256 = sum_ext[255:0];
    wire         ge_p    = sum_ext[256] || (sum_256 >= `SM2_P);
    assign result = ge_p ? (sum_256 - `SM2_P) : sum_256;
endmodule

// =============================================================================
// 模减法: result = (a - b) mod p
// 组合逻辑: 256-bit 减法 + 条件加法
// =============================================================================
module sm2_modsub (
    input  wire [255:0] a,
    input  wire [255:0] b,
    output wire [255:0] result
);
    wire [256:0] diff_ext = {1'b0, a} - {1'b0, b};  // 257-bit to detect borrow
    wire [255:0] diff_256 = diff_ext[255:0];
    wire         borrow    = diff_ext[256];  // 1 if a < b (unsigned borrow)
    assign result = borrow ? (diff_256 + `SM2_P) : diff_256;
endmodule

// =============================================================================
// 模加法/减法 (二选一): result = (a ± b) mod p
// op = 0: add, op = 1: sub
// =============================================================================
module sm2_modaddsub (
    input  wire [255:0] a,
    input  wire [255:0] b,
    input  wire         op,       // 0=add, 1=sub
    output wire [255:0] result
);
    wire [256:0] sum_ext = {1'b0, a} + {1'b0, b};
    wire [256:0] diff_ext = {1'b0, a} - {1'b0, b};
    
    wire [255:0] add_result = (sum_ext[256] || (sum_ext[255:0] >= `SM2_P)) ?
                               (sum_ext[255:0] - `SM2_P) : sum_ext[255:0];
    wire [255:0] sub_result = (diff_ext[256]) ?
                               (diff_ext[255:0] + `SM2_P) : diff_ext[255:0];
    
    assign result = op ? sub_result : add_result;
endmodule

// =============================================================================
// 模比较: a >= b (mod p 空间, 即 a >= b in [0, p))
// =============================================================================
module sm2_modcompare (
    input  wire [255:0] a,
    input  wire [255:0] b,
    output wire         ge      // 1 if a >= b
);
    assign ge = (a > b) || (a == b);
endmodule
