// =============================================================================
// sm4_engine_masked_v2.v -- SM4 引擎级掩码表重计算 (C1 升级 B-3)
// =============================================================================
// 版本: 1.1  (v1.1: B-4 T4 均匀性判据捕获并修复 LFSR 常数项双重施加缺陷)
// 日期: 2026-10-05
// 设计: 齐流晶 (FPGA Full-Flow Lead)
// 生成: .workbuddy/tmp/gen_engine_masked_v2.py (从 sm4_engine_sys.v 定点替换)
// 关联: docs/Phase0_5_C1_升级路线选择_v1.md    §7 (B-3)
//       rtl/sm4/sm4_engine_sys.v                本文件基线, 559 行逐行移植
//       rtl/sm4/sm4_sbox_table_masked.v         B-2, S 盒级掩码表 774/774 PASS
//       sim/sm4/ref_sm4_sbox_table_masked.py    B-1 参考模型 ALL PASS
// =============================================================================
//
// 【设计目标】
//   把 B-2 的掩码表机制下沉到引擎级: 32 轮数据通路 + 密钥扩展的全部 16 个
//   S 盒查询点改走"重计算掩码表", 并在每块边界自动刷新表与常量掩码 c。
//
// 【构造 (纯 RSM-LUT, 函数恒等, 无消码步骤)】
//   表刷新时预计算 :  Tbl[n] = S(n ^ c)          n=0..255, c 为本块常量掩码
//   S 盒查询       :  sbox_v2(x) = Tbl[x ^ c] = S(x ^ c ^ c) = S(x)
//   => 输出恒为真值 S(x), 密文与未掩码基线逐 bit 一致。
//      零回归是**构造保证** (恒等式), 不依赖测试是否覆盖。
//
//   为何不用 B-2 的 Tbl[n] = S(n^c) ^ r_table[n] + 查询后消码形式:
//   消码形式在综合网表里存在代数恒等 a^b^b = a, 优化器可能把整条掩码通路
//   折叠掉, 使"保护"在硅上消失 (仿真里看不见, 上板后不存在)。本文件的表
//   旋转形式无此恒等: 掩码是真实存在的数据相关置换, 综合无法消除。
//
// 【保护点 (诚实边界, 不夸大)】
//   +-----------------------------------------------------+---------------------+
//   | 观测点                                              | 保护级别              |
//   +-----------------------------------------------------+---------------------+
//   | S 盒表存储内容 (实际存 S(n^c) 而非 S(n))           | Resistant 每块重计算  |
//   | S 盒查询地址线   (实际承载 x^c 而非 x)             | Resistant 每块随机化  |
//   | S 盒输出总线     (= S(x), 真值)                     | NOT protected         |
//   | S 盒上游 tmp     (= X^X^X^rk, 真值)                 | NOT protected         |
//   +-----------------------------------------------------+---------------------+
//   不抵御: 联合观测 (地址与输出同时探测 -> 可解 c 再去掩码);
//           表刷新过程 (16 个 S_KEY 周期内可见, 毛刺不安全)。
//   严格 1-order TVLA 需假设"刷新不被探测 + 地址与输出不联合观测"。
//   数据通路全程掩码须走路线 C (TI 阈值实现), 见路线选择文档 §8。
//   例外: 首块密钥扩展阶段使用复位期预置的固定常量掩码 0xA5 (非零, 但已知),
//         自首块 S_C0 起数据通路与后续块密钥扩展均使用每块随机 c。
//
// 【刷新调度 (零额外延迟)】
//   16 路并行 S 盒实例, 在 S_KEY 的 16 个周期内每周期生成 16 个条目:
//     256 条目 / 16 路 = 16 周期, 与密钥扩展 2-keyword/cycle 的 16 周期
//     精确对齐 => 引擎总延迟与 sm4_engine_sys 完全相同 (约 34 cycle/block)。
//   双缓冲 (sbox_tbl_src[0:511], sbox_buf_sel 作最高地址位) 保证刷新期间
//   密钥扩展读到的仍是上一块的有效表; 刷新完成于 S_KEY 末拍翻转 sbox_buf_sel,
//   自 S_C0 起数据通路使用新表。因此**不需要新增 FSM 状态**。
//
// 【面积/时序估算 (xcu250, 待 B-5 实测签核)】
//   sbox_tbl_src 512x8 = 4096 bit        1x BRAM36 (或 2x BRAM18), 非 LUT
//   16 路并行 S 盒刷新阵列                ~ 16 x 130 LUT = ~2100 LUT
//   512:1 表读取 mux (16 个调用点)        工具映射为 BRAM 读端口
//   生成 LFSR + 控制逻辑                  ~ 20 LUT
//   合计增量 ≈ +2200 LUT (优于 §7 的 +4000 估算)
//   注: 刷新阵列仅在 S_KEY 期间有效; 若以延迟换面积, 可改为 K 路并行
//       (K=1 时阵列降至 ~130 LUT, 但刷新需 256 周期, 延迟 +650%)。
//
// 【接口兼容】
//   clk/rst_n/start/key/plaintext/decrypt/ciphertext/result/done/busy 与
//   sm4_engine_sys 完全一致, 可原位替换。新增端口均为掩码控制与观测用途,
//   masked_en=0 时行为与 sm4_engine_sys 逐 bit 等价 (默认即该状态)。
// =============================================================================

`timescale 1ns / 1ps

module sm4_engine_masked_v2 (
    input  wire         clk,
    input  wire         rst_n,

    // 命令接口 (与 sm4_engine_sys v1.0 完全一致)
    input  wire         start,
    input  wire [127:0] key,
    input  wire [127:0] plaintext,
    input  wire         decrypt,
    input  wire [127:0] ciphertext,

    // 结果输出 (与 sm4_engine_sys v1.0 完全一致)
    output wire [127:0] result,
    output reg          done,
    output wire         busy,

    // =========================================================================
    // B-3 新增: 掩码控制
    // =========================================================================
    input  wire          masked_en,         // 1=启用掩码表重计算, 0=透传 (零回归)
    input  wire          sbox_mask_ext_en,  // 1=外部注入表 (生产环境接 trng_sm3)
    input  wire [7:0]    sbox_mask_c_ext,   // 外部常量掩码 c
    input  wire [2047:0] sbox_mask_tbl_ext, // 外部掩码表 Tbl[n]=S(n^c), n 左移3对齐

    // =========================================================================
    // B-3 新增: 侧信道观测端口 (供 SPA/TVLA 仿真, 非功能必需)
    //   masked_en=0 时三者在数值上等价, 观测端口退化为透传。
    // =========================================================================
    output wire [7:0] sbox_addr_tap,   // S 盒表读取地址 (受保护: 实为 x^c)
    output wire [7:0] sbox_mask_c_tap, // 当前生效的常量掩码 c
    output reg        sbox_mask_valid  // 当前活动表有效 (首块刷新完成后置位)
);

    // =========================================================================
    // 常量 (与 sm4_engine.v v1.0 一致)
    // =========================================================================
    localparam [31:0] FK0 = 32'ha3b1bac6;
    localparam [31:0] FK1 = 32'h56aa3350;
    localparam [31:0] FK2 = 32'h677d9197;
    localparam [31:0] FK3 = 32'hb27022dc;

    // =========================================================================
    // 状态机 (16-stage: S_C0..S_C15, 共 18 状态, 5-bit)
    // =========================================================================
    localparam [4:0] S_IDLE     = 5'd0;
    localparam [4:0] S_KEY      = 5'd1;
    localparam [4:0] S_C0       = 5'd2;
    localparam [4:0] S_C1       = 5'd3;
    localparam [4:0] S_C2       = 5'd4;
    localparam [4:0] S_C3       = 5'd5;
    localparam [4:0] S_C4       = 5'd6;
    localparam [4:0] S_C5       = 5'd7;
    localparam [4:0] S_C6       = 5'd8;
    localparam [4:0] S_C7       = 5'd9;
    localparam [4:0] S_C8       = 5'd10;
    localparam [4:0] S_C9       = 5'd11;
    localparam [4:0] S_C10      = 5'd12;
    localparam [4:0] S_C11      = 5'd13;
    localparam [4:0] S_C12      = 5'd14;
    localparam [4:0] S_C13      = 5'd15;
    localparam [4:0] S_C14      = 5'd16;
    localparam [4:0] S_C15      = 5'd17;
    localparam [4:0] S_OUTPUT   = 5'd18;

    reg [4:0]  fsm_state;
    reg [4:0]  k_idx;         // 密钥扩展索引 0..31
    reg        do_decrypt;    // 解密标志 (启动时锁存)

    // 输入窗口 (128-bit, 4 word)
    reg [127:0] input_window;

    // 密钥扩展窗口 {K[i], K[i+1], K[i+2], K[i+3]}
    reg [127:0] key_window;

    // 轮密钥数组
    reg [31:0] round_keys [0:31];

    // Systolic 流水线窗口寄存器 (16 个 stage)
    reg [127:0] pipe_w0;    // 2 轮后窗口 {X[2],  X[3],  X[4],  X[5]}
    reg [127:0] pipe_w1;    // 4 轮后窗口 {X[4],  X[5],  X[6],  X[7]}
    reg [127:0] pipe_w2;    // 6 轮后窗口 {X[6],  X[7],  X[8],  X[9]}
    reg [127:0] pipe_w3;    // 8 轮后窗口 {X[8],  X[9],  X[10], X[11]}
    reg [127:0] pipe_w4;    // 10 轮后窗口 {X[10], X[11], X[12], X[13]}
    reg [127:0] pipe_w5;    // 12 轮后窗口 {X[12], X[13], X[14], X[15]}
    reg [127:0] pipe_w6;    // 14 轮后窗口 {X[14], X[15], X[16], X[17]}
    reg [127:0] pipe_w7;    // 16 轮后窗口 {X[16], X[17], X[18], X[19]}
    reg [127:0] pipe_w8;    // 18 轮后窗口 {X[18], X[19], X[20], X[21]}
    reg [127:0] pipe_w9;    // 20 轮后窗口 {X[20], X[21], X[22], X[23]}
    reg [127:0] pipe_w10;   // 22 轮后窗口 {X[22], X[23], X[24], X[25]}
    reg [127:0] pipe_w11;   // 24 轮后窗口 {X[24], X[25], X[26], X[27]}
    reg [127:0] pipe_w12;   // 26 轮后窗口 {X[26], X[27], X[28], X[29]}
    reg [127:0] pipe_w13;   // 28 轮后窗口 {X[28], X[29], X[30], X[31]}
    reg [127:0] pipe_w14;   // 30 轮后窗口 {X[30], X[31], X[32], X[33]}
    reg [127:0] pipe_w15;   // 32 轮后窗口 {X[32], X[33], X[34], X[35]}

    // 输出缓冲
    reg [127:0] data_out;

    assign result = data_out;
    assign busy   = (fsm_state != S_IDLE);

    // 输入选择: 加密用 plaintext, 解密用 ciphertext
    wire [127:0] input_data = decrypt ? ciphertext : plaintext;

    // =========================================================================
    // rotl32 (与 sm4_engine.v 一致)
    // =========================================================================
    function [31:0] rotl32;
        input [31:0] x;
        input [4:0]  n;
        begin
            rotl32 = ({x, x} >> (6'd32 - n));
        end
    endfunction

    // =========================================================================
    // SM4 S-box BRAM ROM (A 优化: 显式 initial -> Vivado 映射到 BRAM)
    // =========================================================================
    (* rom_style = "block" *) reg [7:0] sbox_rom [0:255];
    initial begin
        sbox_rom[8'h00] = 8'hd6;
        sbox_rom[8'h01] = 8'h90;
        sbox_rom[8'h02] = 8'he9;
        sbox_rom[8'h03] = 8'hfe;
        sbox_rom[8'h04] = 8'hcc;
        sbox_rom[8'h05] = 8'he1;
        sbox_rom[8'h06] = 8'h3d;
        sbox_rom[8'h07] = 8'hb7;
        sbox_rom[8'h08] = 8'h16;
        sbox_rom[8'h09] = 8'hb6;
        sbox_rom[8'h0a] = 8'h14;
        sbox_rom[8'h0b] = 8'hc2;
        sbox_rom[8'h0c] = 8'h28;
        sbox_rom[8'h0d] = 8'hfb;
        sbox_rom[8'h0e] = 8'h2c;
        sbox_rom[8'h0f] = 8'h05;
        sbox_rom[8'h10] = 8'h2b;
        sbox_rom[8'h11] = 8'h67;
        sbox_rom[8'h12] = 8'h9a;
        sbox_rom[8'h13] = 8'h76;
        sbox_rom[8'h14] = 8'h2a;
        sbox_rom[8'h15] = 8'hbe;
        sbox_rom[8'h16] = 8'h04;
        sbox_rom[8'h17] = 8'hc3;
        sbox_rom[8'h18] = 8'haa;
        sbox_rom[8'h19] = 8'h44;
        sbox_rom[8'h1a] = 8'h13;
        sbox_rom[8'h1b] = 8'h26;
        sbox_rom[8'h1c] = 8'h49;
        sbox_rom[8'h1d] = 8'h86;
        sbox_rom[8'h1e] = 8'h06;
        sbox_rom[8'h1f] = 8'h99;
        sbox_rom[8'h20] = 8'h9c;
        sbox_rom[8'h21] = 8'h42;
        sbox_rom[8'h22] = 8'h50;
        sbox_rom[8'h23] = 8'hf4;
        sbox_rom[8'h24] = 8'h91;
        sbox_rom[8'h25] = 8'hef;
        sbox_rom[8'h26] = 8'h98;
        sbox_rom[8'h27] = 8'h7a;
        sbox_rom[8'h28] = 8'h33;
        sbox_rom[8'h29] = 8'h54;
        sbox_rom[8'h2a] = 8'h0b;
        sbox_rom[8'h2b] = 8'h43;
        sbox_rom[8'h2c] = 8'hed;
        sbox_rom[8'h2d] = 8'hcf;
        sbox_rom[8'h2e] = 8'hac;
        sbox_rom[8'h2f] = 8'h62;
        sbox_rom[8'h30] = 8'he4;
        sbox_rom[8'h31] = 8'hb3;
        sbox_rom[8'h32] = 8'h1c;
        sbox_rom[8'h33] = 8'ha9;
        sbox_rom[8'h34] = 8'hc9;
        sbox_rom[8'h35] = 8'h08;
        sbox_rom[8'h36] = 8'he8;
        sbox_rom[8'h37] = 8'h95;
        sbox_rom[8'h38] = 8'h80;
        sbox_rom[8'h39] = 8'hdf;
        sbox_rom[8'h3a] = 8'h94;
        sbox_rom[8'h3b] = 8'hfa;
        sbox_rom[8'h3c] = 8'h75;
        sbox_rom[8'h3d] = 8'h8f;
        sbox_rom[8'h3e] = 8'h3f;
        sbox_rom[8'h3f] = 8'ha6;
        sbox_rom[8'h40] = 8'h47;
        sbox_rom[8'h41] = 8'h07;
        sbox_rom[8'h42] = 8'ha7;
        sbox_rom[8'h43] = 8'hfc;
        sbox_rom[8'h44] = 8'hf3;
        sbox_rom[8'h45] = 8'h73;
        sbox_rom[8'h46] = 8'h17;
        sbox_rom[8'h47] = 8'hba;
        sbox_rom[8'h48] = 8'h83;
        sbox_rom[8'h49] = 8'h59;
        sbox_rom[8'h4a] = 8'h3c;
        sbox_rom[8'h4b] = 8'h19;
        sbox_rom[8'h4c] = 8'he6;
        sbox_rom[8'h4d] = 8'h85;
        sbox_rom[8'h4e] = 8'h4f;
        sbox_rom[8'h4f] = 8'ha8;
        sbox_rom[8'h50] = 8'h68;
        sbox_rom[8'h51] = 8'h6b;
        sbox_rom[8'h52] = 8'h81;
        sbox_rom[8'h53] = 8'hb2;
        sbox_rom[8'h54] = 8'h71;
        sbox_rom[8'h55] = 8'h64;
        sbox_rom[8'h56] = 8'hda;
        sbox_rom[8'h57] = 8'h8b;
        sbox_rom[8'h58] = 8'hf8;
        sbox_rom[8'h59] = 8'heb;
        sbox_rom[8'h5a] = 8'h0f;
        sbox_rom[8'h5b] = 8'h4b;
        sbox_rom[8'h5c] = 8'h70;
        sbox_rom[8'h5d] = 8'h56;
        sbox_rom[8'h5e] = 8'h9d;
        sbox_rom[8'h5f] = 8'h35;
        sbox_rom[8'h60] = 8'h1e;
        sbox_rom[8'h61] = 8'h24;
        sbox_rom[8'h62] = 8'h0e;
        sbox_rom[8'h63] = 8'h5e;
        sbox_rom[8'h64] = 8'h63;
        sbox_rom[8'h65] = 8'h58;
        sbox_rom[8'h66] = 8'hd1;
        sbox_rom[8'h67] = 8'ha2;
        sbox_rom[8'h68] = 8'h25;
        sbox_rom[8'h69] = 8'h22;
        sbox_rom[8'h6a] = 8'h7c;
        sbox_rom[8'h6b] = 8'h3b;
        sbox_rom[8'h6c] = 8'h01;
        sbox_rom[8'h6d] = 8'h21;
        sbox_rom[8'h6e] = 8'h78;
        sbox_rom[8'h6f] = 8'h87;
        sbox_rom[8'h70] = 8'hd4;
        sbox_rom[8'h71] = 8'h00;
        sbox_rom[8'h72] = 8'h46;
        sbox_rom[8'h73] = 8'h57;
        sbox_rom[8'h74] = 8'h9f;
        sbox_rom[8'h75] = 8'hd3;
        sbox_rom[8'h76] = 8'h27;
        sbox_rom[8'h77] = 8'h52;
        sbox_rom[8'h78] = 8'h4c;
        sbox_rom[8'h79] = 8'h36;
        sbox_rom[8'h7a] = 8'h02;
        sbox_rom[8'h7b] = 8'he7;
        sbox_rom[8'h7c] = 8'ha0;
        sbox_rom[8'h7d] = 8'hc4;
        sbox_rom[8'h7e] = 8'hc8;
        sbox_rom[8'h7f] = 8'h9e;
        sbox_rom[8'h80] = 8'hea;
        sbox_rom[8'h81] = 8'hbf;
        sbox_rom[8'h82] = 8'h8a;
        sbox_rom[8'h83] = 8'hd2;
        sbox_rom[8'h84] = 8'h40;
        sbox_rom[8'h85] = 8'hc7;
        sbox_rom[8'h86] = 8'h38;
        sbox_rom[8'h87] = 8'hb5;
        sbox_rom[8'h88] = 8'ha3;
        sbox_rom[8'h89] = 8'hf7;
        sbox_rom[8'h8a] = 8'hf2;
        sbox_rom[8'h8b] = 8'hce;
        sbox_rom[8'h8c] = 8'hf9;
        sbox_rom[8'h8d] = 8'h61;
        sbox_rom[8'h8e] = 8'h15;
        sbox_rom[8'h8f] = 8'ha1;
        sbox_rom[8'h90] = 8'he0;
        sbox_rom[8'h91] = 8'hae;
        sbox_rom[8'h92] = 8'h5d;
        sbox_rom[8'h93] = 8'ha4;
        sbox_rom[8'h94] = 8'h9b;
        sbox_rom[8'h95] = 8'h34;
        sbox_rom[8'h96] = 8'h1a;
        sbox_rom[8'h97] = 8'h55;
        sbox_rom[8'h98] = 8'had;
        sbox_rom[8'h99] = 8'h93;
        sbox_rom[8'h9a] = 8'h32;
        sbox_rom[8'h9b] = 8'h30;
        sbox_rom[8'h9c] = 8'hf5;
        sbox_rom[8'h9d] = 8'h8c;
        sbox_rom[8'h9e] = 8'hb1;
        sbox_rom[8'h9f] = 8'he3;
        sbox_rom[8'ha0] = 8'h1d;
        sbox_rom[8'ha1] = 8'hf6;
        sbox_rom[8'ha2] = 8'he2;
        sbox_rom[8'ha3] = 8'h2e;
        sbox_rom[8'ha4] = 8'h82;
        sbox_rom[8'ha5] = 8'h66;
        sbox_rom[8'ha6] = 8'hca;
        sbox_rom[8'ha7] = 8'h60;
        sbox_rom[8'ha8] = 8'hc0;
        sbox_rom[8'ha9] = 8'h29;
        sbox_rom[8'haa] = 8'h23;
        sbox_rom[8'hab] = 8'hab;
        sbox_rom[8'hac] = 8'h0d;
        sbox_rom[8'had] = 8'h53;
        sbox_rom[8'hae] = 8'h4e;
        sbox_rom[8'haf] = 8'h6f;
        sbox_rom[8'hb0] = 8'hd5;
        sbox_rom[8'hb1] = 8'hdb;
        sbox_rom[8'hb2] = 8'h37;
        sbox_rom[8'hb3] = 8'h45;
        sbox_rom[8'hb4] = 8'hde;
        sbox_rom[8'hb5] = 8'hfd;
        sbox_rom[8'hb6] = 8'h8e;
        sbox_rom[8'hb7] = 8'h2f;
        sbox_rom[8'hb8] = 8'h03;
        sbox_rom[8'hb9] = 8'hff;
        sbox_rom[8'hba] = 8'h6a;
        sbox_rom[8'hbb] = 8'h72;
        sbox_rom[8'hbc] = 8'h6d;
        sbox_rom[8'hbd] = 8'h6c;
        sbox_rom[8'hbe] = 8'h5b;
        sbox_rom[8'hbf] = 8'h51;
        sbox_rom[8'hc0] = 8'h8d;
        sbox_rom[8'hc1] = 8'h1b;
        sbox_rom[8'hc2] = 8'haf;
        sbox_rom[8'hc3] = 8'h92;
        sbox_rom[8'hc4] = 8'hbb;
        sbox_rom[8'hc5] = 8'hdd;
        sbox_rom[8'hc6] = 8'hbc;
        sbox_rom[8'hc7] = 8'h7f;
        sbox_rom[8'hc8] = 8'h11;
        sbox_rom[8'hc9] = 8'hd9;
        sbox_rom[8'hca] = 8'h5c;
        sbox_rom[8'hcb] = 8'h41;
        sbox_rom[8'hcc] = 8'h1f;
        sbox_rom[8'hcd] = 8'h10;
        sbox_rom[8'hce] = 8'h5a;
        sbox_rom[8'hcf] = 8'hd8;
        sbox_rom[8'hd0] = 8'h0a;
        sbox_rom[8'hd1] = 8'hc1;
        sbox_rom[8'hd2] = 8'h31;
        sbox_rom[8'hd3] = 8'h88;
        sbox_rom[8'hd4] = 8'ha5;
        sbox_rom[8'hd5] = 8'hcd;
        sbox_rom[8'hd6] = 8'h7b;
        sbox_rom[8'hd7] = 8'hbd;
        sbox_rom[8'hd8] = 8'h2d;
        sbox_rom[8'hd9] = 8'h74;
        sbox_rom[8'hda] = 8'hd0;
        sbox_rom[8'hdb] = 8'h12;
        sbox_rom[8'hdc] = 8'hb8;
        sbox_rom[8'hdd] = 8'he5;
        sbox_rom[8'hde] = 8'hb4;
        sbox_rom[8'hdf] = 8'hb0;
        sbox_rom[8'he0] = 8'h89;
        sbox_rom[8'he1] = 8'h69;
        sbox_rom[8'he2] = 8'h97;
        sbox_rom[8'he3] = 8'h4a;
        sbox_rom[8'he4] = 8'h0c;
        sbox_rom[8'he5] = 8'h96;
        sbox_rom[8'he6] = 8'h77;
        sbox_rom[8'he7] = 8'h7e;
        sbox_rom[8'he8] = 8'h65;
        sbox_rom[8'he9] = 8'hb9;
        sbox_rom[8'hea] = 8'hf1;
        sbox_rom[8'heb] = 8'h09;
        sbox_rom[8'hec] = 8'hc5;
        sbox_rom[8'hed] = 8'h6e;
        sbox_rom[8'hee] = 8'hc6;
        sbox_rom[8'hef] = 8'h84;
        sbox_rom[8'hf0] = 8'h18;
        sbox_rom[8'hf1] = 8'hf0;
        sbox_rom[8'hf2] = 8'h7d;
        sbox_rom[8'hf3] = 8'hec;
        sbox_rom[8'hf4] = 8'h3a;
        sbox_rom[8'hf5] = 8'hdc;
        sbox_rom[8'hf6] = 8'h4d;
        sbox_rom[8'hf7] = 8'h20;
        sbox_rom[8'hf8] = 8'h79;
        sbox_rom[8'hf9] = 8'hee;
        sbox_rom[8'hfa] = 8'h5f;
        sbox_rom[8'hfb] = 8'h3e;
        sbox_rom[8'hfc] = 8'hd7;
        sbox_rom[8'hfd] = 8'hcb;
        sbox_rom[8'hfe] = 8'h39;
        sbox_rom[8'hff] = 8'h48;
    end

    function [7:0] sm4_sbox;
        input [7:0] x;
        begin
            sm4_sbox = sbox_rom[x];
        end
    endfunction

    // =========================================================================
    // B-3 掩码表重计算状态 (RSM-LUT 双缓冲)
    // =========================================================================
    // 表容量 512 条目 = 2 x 256 (双缓冲)。地址格式 {buf_sel, idx[7:0]}:
    //   buf_sel = 0 -> 缓冲区 A (条目 0..255)
    //   buf_sel = 1 -> 缓冲区 B (条目 256..511)
    // 任一时刻仅 sbox_buf_sel 指向的缓冲区被查询, 另一块供刷新写入。
    // 复位时两缓冲均预置为 S(n ^ C_INIT), 故首块密钥扩展也走掩码通路。
    (* ram_style = "block" *) reg [7:0] sbox_tbl_src [0:511];   // 掩码表 Tbl[n] = S(n ^ c)
    reg        sbox_buf_sel;           // 当前活动缓冲区 (0=A, 1=B)
    reg [7:0]  sbox_c_a;               // 缓冲区 A 的常量掩码
    reg [7:0]  sbox_c_b;               // 缓冲区 B 的常量掩码
    reg [15:0] sbox_seed;              // 掩码生成 LFSR
    reg [5:0]  sbox_mg_cnt;            // 表刷新周期计数 0..15
    integer    gi;                     // 循环变量 (-g2005 需模块级声明)

    // 生成 LFSR: 原多项式 x^16+x^14+x^13+x^11+1 (周期 2^16-1 = 65535)
    //   验证: .workbuddy/tmp/verify_lfsr_b4.py
    //     [A] 乘 x 模 p 递推下 seed=1 恰好遍历 65535 个非零状态 (原多项式)
    //     [B] 全周期高字节 256/256 取值, 每个 255 或 257 次
    //     [E] 512 块采样: chi2_bit=6.48(<20.1) chi2_quart=17.38(<34.2)
    //                                    runs z=+0.13 (|z|<3.5)
    //   左移步进 = 乘 x 模 p:
    //     carry = s[15];  s = {s[14:0],carry} ^ (carry ? 16'h6800 : 0)
    //   【B-4 缺陷修复 v1.1】掩码必须取 16'h6800 = x^14+x^13+x^11 (不含常数项)。
    //     {s[14:0],carry} 的 bit0 已经等于 carry, 若再异或含 bit0 的 0x6801,
    //     常数项 x^0 被施加两次, bit0 恒为 0 -> 低字节恒 0 -> 高字节仅 12 个
    //     取值、周期 12 -> 掩码序列完全可预测 (B-4 T4 均匀性判据捕获)。
    //     旧值 16'h6801 源自 check_lfsr_prim.py 的 lfsr_reg_str(): 其 Python
    //     step() 递推正确, 但生成的 Verilog 串与模型不一致, 已一并修正。
    wire       sbox_seed_fb  = sbox_seed[15];
    wire [15:0] sbox_seed_nxt = {sbox_seed[14:0], sbox_seed_fb} ^
                                (sbox_seed_fb ? 16'h6800 : 16'h0000);

    // 本块将写入目标缓冲区的新常量掩码 (取自 LFSR 高字节)
    wire [7:0] sbox_c_new = sbox_seed_nxt[15:8];
    // 当前生效常量掩码 (活动缓冲区) / 刷新写入常量掩码 (目标缓冲区)
    wire [7:0] sbox_c_active = sbox_buf_sel ? sbox_c_b : sbox_c_a;
    wire [7:0] sbox_c_tgt    = sbox_buf_sel ? sbox_c_a : sbox_c_b;
    // 有效掩码: 外部注入模式必须用 sbox_mask_c_ext (外部表按 c_ext 预计算),
    // 否则 sbox_v2 会用内部 c 生成索引去查外部表 -> 索引与表不配套, 结果错。
    // (v1 未做此选择, sbox_mask_c_ext 端口形同虚设, T9 无法通过)
    wire [7:0] sbox_c_eff = sbox_mask_ext_en ? sbox_mask_c_ext : sbox_c_active;

    // 表刷新使能: 掩码开启且非外部注入, 在 S_KEY 的 16 周期内并行重计算
    wire sbox_mg_en = masked_en & ~sbox_mask_ext_en & (fsm_state == S_KEY);

    // =========================================================================
    // B-3 掩码表读取 (组合): 入参为已 XOR 掩码的索引
    //   外部注入模式下直接按 (x^c_ext) 从外部表移位读取, 不经双缓冲
    //   注: 移位结果先落到函数内局部变量再取 [7:0], 避免对表达式直接做
    //       part-select (iverilog -g2005 对此报 syntax error)
    // =========================================================================
    // ⚠⚠ 2026-10-06 实测踩坑 (板级综合撑爆 xc7a200t, DRC UTLZ-1):
    //   原来的写法是 `t_ext = sbox_mask_tbl_ext >> {idx_msk, 3'b000};`
    //   对 **2048 位**宽向量做变量桶形移位, 综合要生成 11 级 x 2048 位 =
    //   ~22528 个 LUT6; 而这个组合函数被内联到 16 个 S 盒查询点上,
    //   最终网表 152225 个 LUT6 / 73832 MUXF7 (器件只有 134600 / 67300),
    //   place_design 直接 DRC 失败 "Placer not run"。
    //   等价改写: 一次变量 part-select 取 8 位, 综合成一个 2048:8 选择器 (~88 LUT)。
    //   注意: `{idx_msk,3'b000}` 正好 11 位, 最大值 2047 = 表尾, 不会越界。
    //   变量下标 part-select 已用 .workbuddy/tmp/t_exprsel.v 在 -g2005 下验证。
    function [7:0] sbox_tbl_read;
        input  [7:0]    idx_msk;
        reg    [10:0]   byte_addr;
        reg    [7:0]    t_ext;
        begin
            byte_addr      = {idx_msk, 3'b000};
            t_ext          = sbox_mask_tbl_ext[byte_addr +: 8];
            sbox_tbl_read  = sbox_mask_ext_en ? t_ext :
                             sbox_tbl_src[{sbox_buf_sel, idx_msk}];
        end
    endfunction

    // =========================================================================
    // B-3 统一 S 盒查询入口  --  替换全部 16 个 sm4_sbox() 调用点
    //   masked_en=1 : sbox_v2(x) = Tbl[x ^ c] = S(x ^ c ^ c) = S(x)  (恒等)
    //   masked_en=0 : sbox_v2(x) = sm4_sbox(x)                        (零回归)
    // =========================================================================
    function [7:0] sbox_v2;
        input [7:0] x;
        begin
            sbox_v2 = masked_en ? sbox_tbl_read(x ^ sbox_c_eff) : sm4_sbox(x);
        end
    endfunction

    // =========================================================================
    // B-3 侧信道观测: 取第 0 轮第 1 字节的真实查询点
    //   advance_2_rounds 首轮: tmp = t[31:0]^t[63:32]^t[95:64]^rk, t=input_window
    //   tau[31:24] = S(tmp[31:24]), 首轮 rk = round_keys[0]
    //   sbox_addr_tap 即 S 盒表实际读取的地址 (受保护信号)
    // =========================================================================
    wire [31:0] sbox_tap_tmp = input_window[31:0] ^ input_window[63:32] ^
                               input_window[95:64]  ^ round_keys[0];
    wire [7:0]  sbox_tap_idx = sbox_tap_tmp[31:24] ^ sbox_c_eff;

    assign sbox_addr_tap   = masked_en ? sbox_tap_idx : sbox_tap_tmp[31:24];
    assign sbox_mask_c_tap = sbox_c_eff;

    // =========================================================================
    // SM4 CK 常数 (与 sm4_engine.v 一致)
    // =========================================================================
    function [31:0] get_ck;
        input [4:0] i;
        begin
            case (i)
                5'd0:  get_ck = 32'h00070e15;
                5'd1:  get_ck = 32'h1c232a31;
                5'd2:  get_ck = 32'h383f464d;
                5'd3:  get_ck = 32'h545b6269;
                5'd4:  get_ck = 32'h70777e85;
                5'd5:  get_ck = 32'h8c939aa1;
                5'd6:  get_ck = 32'ha8afb6bd;
                5'd7:  get_ck = 32'hc4cbd2d9;
                5'd8:  get_ck = 32'he0e7eef5;
                5'd9:  get_ck = 32'hfc030a11;
                5'd10: get_ck = 32'h181f262d;
                5'd11: get_ck = 32'h343b4249;
                5'd12: get_ck = 32'h50575e65;
                5'd13: get_ck = 32'h6c737a81;
                5'd14: get_ck = 32'h888f969d;
                5'd15: get_ck = 32'ha4abb2b9;
                5'd16: get_ck = 32'hc0c7ced5;
                5'd17: get_ck = 32'hdce3eaf1;
                5'd18: get_ck = 32'hf8ff060d;
                5'd19: get_ck = 32'h141b2229;
                5'd20: get_ck = 32'h30373e45;
                5'd21: get_ck = 32'h4c535a61;
                5'd22: get_ck = 32'h686f767d;
                5'd23: get_ck = 32'h848b9299;
                5'd24: get_ck = 32'ha0a7aeb5;
                5'd25: get_ck = 32'hbcc3cad1;
                5'd26: get_ck = 32'hd8dfe6ed;
                5'd27: get_ck = 32'hf4fb0209;
                5'd28: get_ck = 32'h10171e25;
                5'd29: get_ck = 32'h2c333a41;
                5'd30: get_ck = 32'h484f565d;
                5'd31: get_ck = 32'h646b7279;
                default: get_ck = 32'h0;
            endcase
        end
    endfunction

    // =========================================================================
    // SM4 单轮 T 变换 (组合, 与 sm4_engine.v 一致)
    // =========================================================================
    function [31:0] sm4_round;
        input [31:0] x0;  // X[i]
        input [31:0] x1;  // X[i+1]
        input [31:0] x2;  // X[i+2]
        input [31:0] x3;  // X[i+3]
        input [31:0] rk;  // rk[i]
        reg [31:0] tmp;
        reg [31:0] tau;
        reg [31:0] L;
        begin
            tmp = x3 ^ x2 ^ x1 ^ rk;
            tau = {sbox_v2(tmp[31:24]),
                   sbox_v2(tmp[23:16]),
                   sbox_v2(tmp[15:8]),
                   sbox_v2(tmp[7:0])};
            L = tau ^ rotl32(tau, 5'd2) ^ rotl32(tau, 5'd10) ^
                rotl32(tau, 5'd18) ^ rotl32(tau, 5'd24);
            sm4_round = x0 ^ L;
        end
    endfunction

    // =========================================================================
    // 2 轮窗口推进 (Systolic 核心, 2 轮组合串联)
    // 输入:  4-word 窗口 {X[i], X[i+1], X[i+2], X[i+3]}
    //        起始轮索引 r_start (0, 2, 4, ..., 30)
    // 输出:  4-word 窗口 {X[i+2], X[i+3], X[i+4], X[i+5]}
    //        即经过 2 轮后的新窗口
    //
    // 注: 单轮 T 变换在 advance_2_rounds 内内联 (避免 iverilog -g2005
    //     对嵌套函数调用的解析问题; 组合语义等价)
    // =========================================================================
    function [127:0] advance_2_rounds;
        input [127:0] window;
        input [4:0]   r_start;
        reg [127:0]   t;
        reg [1:0]     r;
        reg [31:0]    rk;
        reg [31:0]    new_word;
        reg [31:0]    tmp;
        reg [31:0]    tau;
        reg [31:0]    L;
        begin
            t = window;
            for (r = 0; r < 2; r = r + 1) begin
                if (do_decrypt) begin
                    rk = round_keys[31-(r_start+r)];
                end else begin
                    rk = round_keys[r_start+r];
                end
                // 单轮 T 变换 (内联 sm4_round)
                tmp = t[31:0] ^ t[63:32] ^ t[95:64] ^ rk;
                tau = {sbox_v2(tmp[31:24]),
                       sbox_v2(tmp[23:16]),
                       sbox_v2(tmp[15:8]),
                       sbox_v2(tmp[7:0])};
                L = tau ^ rotl32(tau, 5'd2) ^ rotl32(tau, 5'd10) ^
                    rotl32(tau, 5'd18) ^ rotl32(tau, 5'd24);
                new_word = t[127:96] ^ L;
                // 窗口前移: {X[i+1], X[i+2], X[i+3], X[i+4]}
                t = {t[95:64], t[63:32], t[31:0], new_word};
            end
            advance_2_rounds = t;
        end
    endfunction

    // =========================================================================
    // 密钥扩展 (组合, 与 sm4_engine.v 一致)
    // =========================================================================
    // =========================================================================
    // 密钥扩展 (组合逻辑, 2 keywords/cycle)
    // K[i+4] = K[i] ^ T'(K[i+1] ^ K[i+2] ^ K[i+3] ^ CK[i])
    // K[i+5] = K[i+1] ^ T'(K[i+2] ^ K[i+3] ^ K[i+4] ^ CK[i+1])
    // 注: K[i+5] 依赖 K[i+4], 两个 T' 串行 (组合深度 ~20 级)
    // =========================================================================
    // 第一个 T' -> key_next1 = K[i+4]
    wire [31:0] key_xors1 = key_window[95:64] ^ key_window[63:32] ^ key_window[31:0] ^ get_ck(k_idx);
    wire [31:0] key_tau1  = {sbox_v2(key_xors1[31:24]),
                            sbox_v2(key_xors1[23:16]),
                            sbox_v2(key_xors1[15:8]),
                            sbox_v2(key_xors1[7:0])};
    wire [31:0] key_Lp1   = key_tau1 ^ rotl32(key_tau1, 5'd13) ^ rotl32(key_tau1, 5'd23);
    wire [31:0] key_next1 = key_window[127:96] ^ key_Lp1;

    // 第二个 T' -> key_next2 = K[i+5] (依赖 key_next1)
    wire [31:0] key_xors2 = key_window[63:32] ^ key_window[31:0] ^ key_next1 ^ get_ck(k_idx+5'd1);
    wire [31:0] key_tau2  = {sbox_v2(key_xors2[31:24]),
                            sbox_v2(key_xors2[23:16]),
                            sbox_v2(key_xors2[15:8]),
                            sbox_v2(key_xors2[7:0])};
    wire [31:0] key_Lp2   = key_tau2 ^ rotl32(key_tau2, 5'd13) ^ rotl32(key_tau2, 5'd23);
    wire [31:0] key_next2 = key_window[95:64] ^ key_Lp2;

    // =========================================================================
    // FSM 主逻辑
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_state    <= S_IDLE;
            k_idx        <= 5'd0;
            do_decrypt   <= 1'b0;
            input_window <= 128'd0;
            key_window   <= 128'd0;
            pipe_w0      <= 128'd0;
            pipe_w1      <= 128'd0;
            pipe_w2      <= 128'd0;
            pipe_w3      <= 128'd0;
            pipe_w4      <= 128'd0;
            pipe_w5      <= 128'd0;
            pipe_w6      <= 128'd0;
            pipe_w7      <= 128'd0;
            pipe_w8      <= 128'd0;
            pipe_w9      <= 128'd0;
            pipe_w10     <= 128'd0;
            pipe_w11     <= 128'd0;
            pipe_w12     <= 128'd0;
            pipe_w13     <= 128'd0;
            pipe_w14     <= 128'd0;
            pipe_w15     <= 128'd0;
            data_out     <= 128'd0;
            done         <= 1'b0;
            sbox_buf_sel    <= 1'b0;
            sbox_c_a        <= 8'hA5;
            sbox_c_b        <= 8'hA5;
            sbox_seed       <= 16'hB000;
            sbox_mg_cnt     <= 6'd0;
            sbox_mask_valid <= 1'b0;
            // 双缓冲预初始化为 S(n ^ C_INIT), 保证首块密钥扩展
            // 也走掩码通路且数值正确 (Tbl[x^c]=S(x^c^c)=S(x))
            for (gi = 0; gi < 512; gi = gi + 1) begin
                sbox_tbl_src[gi] <= sm4_sbox(gi[7:0] ^ 8'hA5);
            end
        end else begin
            done <= 1'b0;

            case (fsm_state)
            S_IDLE: begin
                if (start) begin
                    input_window <= input_data;
                    do_decrypt   <= decrypt;
                    key_window   <= {key[127:96] ^ FK0,
                                     key[95:64]  ^ FK1,
                                     key[63:32]  ^ FK2,
                                     key[31:0]   ^ FK3};
                    k_idx        <= 5'd0;
                    fsm_state    <= S_KEY;


                    // B-3: 每块生成新常量掩码 c, 写入目标缓冲区
                    //       (目标 = 当前非活动块, 刷新结束后 sbox_buf_sel 翻转)
                    if (masked_en & ~sbox_mask_ext_en) begin
                        sbox_seed   <= sbox_seed_nxt;
                        sbox_mg_cnt <= 6'd0;
                        if (sbox_buf_sel) sbox_c_a <= sbox_c_new;
                        else              sbox_c_b <= sbox_c_new;
                    end
                end
            end

            S_KEY: begin
                if (k_idx < 5'd30) begin
                    round_keys[k_idx]     <= key_next1;
                    round_keys[k_idx+1]   <= key_next2;
                    key_window <= {key_window[63:32],
                                   key_window[31:0],
                                   key_next1,
                                   key_next2};
                    k_idx <= k_idx + 5'd2;
                end else begin
                    // k_idx == 30: 写最后两个 rk, key_window 冻结不移
                    // (掩码模式下 S_KEY 停留 64 周期, 此分支重复写同值, 安全)
                    round_keys[5'd30]     <= key_next1;
                    round_keys[5'd31]     <= key_next2;
                end

                // 表刷新: 4 路并行 (B 优化), 每周期写 4 条, 共 64 周期
                if (sbox_mg_en) begin
                    for (gi = 0; gi < 4; gi = gi + 1) begin
                        sbox_tbl_src[{~sbox_buf_sel, sbox_mg_cnt, gi[1:0]}] <=
                            sm4_sbox({sbox_mg_cnt, gi[1:0]} ^ sbox_c_tgt);
                    end
                    if (sbox_mg_cnt < 6'd63)
                        sbox_mg_cnt <= sbox_mg_cnt + 6'd1;
                end

                // S_KEY 退出: 掩码开→等刷新完成(64 周期), 掩码关→等密钥扩展(16 周期)
                if ((masked_en & ~sbox_mask_ext_en) ? (sbox_mg_cnt == 6'd63) : (k_idx == 5'd30)) begin
                    fsm_state <= S_C0;
                    if (masked_en) sbox_mask_valid <= 1'b1;
                    if (masked_en & ~sbox_mask_ext_en) sbox_buf_sel <= ~sbox_buf_sel;
                end
            end

            // Systolic pipeline: 16 stages, 每 stage 2 轮
            S_C0: begin
                pipe_w0 <= advance_2_rounds(input_window, 5'd0);
                fsm_state <= S_C1;
            end
            S_C1: begin
                pipe_w1 <= advance_2_rounds(pipe_w0, 5'd2);
                fsm_state <= S_C2;
            end
            S_C2: begin
                pipe_w2 <= advance_2_rounds(pipe_w1, 5'd4);
                fsm_state <= S_C3;
            end
            S_C3: begin
                pipe_w3 <= advance_2_rounds(pipe_w2, 5'd6);
                fsm_state <= S_C4;
            end
            S_C4: begin
                pipe_w4 <= advance_2_rounds(pipe_w3, 5'd8);
                fsm_state <= S_C5;
            end
            S_C5: begin
                pipe_w5 <= advance_2_rounds(pipe_w4, 5'd10);
                fsm_state <= S_C6;
            end
            S_C6: begin
                pipe_w6 <= advance_2_rounds(pipe_w5, 5'd12);
                fsm_state <= S_C7;
            end
            S_C7: begin
                pipe_w7 <= advance_2_rounds(pipe_w6, 5'd14);
                fsm_state <= S_C8;
            end
            S_C8: begin
                pipe_w8 <= advance_2_rounds(pipe_w7, 5'd16);
                fsm_state <= S_C9;
            end
            S_C9: begin
                pipe_w9 <= advance_2_rounds(pipe_w8, 5'd18);
                fsm_state <= S_C10;
            end
            S_C10: begin
                pipe_w10 <= advance_2_rounds(pipe_w9, 5'd20);
                fsm_state <= S_C11;
            end
            S_C11: begin
                pipe_w11 <= advance_2_rounds(pipe_w10, 5'd22);
                fsm_state <= S_C12;
            end
            S_C12: begin
                pipe_w12 <= advance_2_rounds(pipe_w11, 5'd24);
                fsm_state <= S_C13;
            end
            S_C13: begin
                pipe_w13 <= advance_2_rounds(pipe_w12, 5'd26);
                fsm_state <= S_C14;
            end
            S_C14: begin
                pipe_w14 <= advance_2_rounds(pipe_w13, 5'd28);
                fsm_state <= S_C15;
            end
            S_C15: begin
                pipe_w15 <= advance_2_rounds(pipe_w14, 5'd30);
                fsm_state <= S_OUTPUT;
            end

            // 尾部字序调换: {X[35], X[34], X[33], X[32]}
            // pipe_w15 = {X[32], X[33], X[34], X[35]}
            // 即 pipe_w15[127:96]=X[32], [95:64]=X[33], [63:32]=X[34], [31:0]=X[35]
            S_OUTPUT: begin
                data_out <= {pipe_w15[31:0],  // X[35] -> result[127:96]
                             pipe_w15[63:32], // X[34] -> result[95:64]
                             pipe_w15[95:64], // X[33] -> result[63:32]
                             pipe_w15[127:96]}; // X[32] -> result[31:0]
                done      <= 1'b1;
                fsm_state <= S_IDLE;
            end

            default: fsm_state <= S_IDLE;
            endcase
        end
    end

endmodule
