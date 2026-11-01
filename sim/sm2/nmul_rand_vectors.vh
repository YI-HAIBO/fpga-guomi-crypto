// =========================================================================
// 自动生成: .workbuddy/tmp/nmul_rand_ref.py
// 用途  : sm2_nmul_rand (路线图 A2) TB 的期望向量
// 格式  : Verilog-2005 兼容 (标量 localparam + 按索引 case 函数)
// 警告  : 本文件禁止手改; 改向量集请运行 nmul_rand_ref.py --vh-only
// =========================================================================

`ifndef NMUL_RAND_VECTORS_VH
`define NMUL_RAND_VECTORS_VH


// --- 参数 ---
localparam integer NM_NUM = 14;

// --- 曲线阶 n (仅作断言用) ---
localparam [255:0] NM_N = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123;

// --- 输入 a ---
localparam [255:0] NM_A0  = 256'hd20a5679e5b210469c866455dd2d0b60bc11492f9bdd4bf87a1d291745a63b3a;  // R1
localparam [255:0] NM_A1  = 256'h1d45e903a25d509383264c83155430158449250160e321c6493cc2ee3545849f;  // R2
localparam [255:0] NM_A2  = 256'hc2b6e55eebd601400d2614bab21901e9fec7e0521344b18a5657093620d7329a;  // R3
localparam [255:0] NM_A3  = 256'h6599818f643e238db02cb9edd0e7a4557db7c8c23d43f2c7c5d68ab197a92b4d;  // R4
localparam [255:0] NM_A4  = 256'h0000000000000000000000000000000000000000000000000000000000000003;  // SMALL
localparam [255:0] NM_A5  = 256'h0000000000000000000000000000000000000000000000000000000000000000;  // A0
localparam [255:0] NM_A6  = 256'h0000000000000000000000000000000000000000000000000000000000000001;  // A1
localparam [255:0] NM_A7  = 256'h0000000000000000000000000000000000000000000000000000000000000001;  // AONE
localparam [255:0] NM_A8  = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54122;  // BN1N1
localparam [255:0] NM_A9  = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54122;  // BN1_2
localparam [255:0] NM_A10  = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54122;  // BN1_N2
localparam [255:0] NM_A11  = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54122;  // B0
localparam [255:0] NM_A12  = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54122;  // BMSB
localparam [255:0] NM_A13  = 256'h0000000000000000000000000000000000000000000000000000000000000003;  // BHI

// --- 输入 b ---
localparam [255:0] NM_B0  = 256'hb87ebb0e732df182ae712d62e0b634a8e062f74a0378fbf0444c2992c3556d9c;  // R1
localparam [255:0] NM_B1  = 256'hc3e1490ce4469563dbc01b571c0628f3a46b9d7436d4eb42c2aab1d0041bb9cd;  // R2
localparam [255:0] NM_B2  = 256'h7bbc73ff5377fd2acaf0327d42aec0486cbc5204743f8dfe9f84a59324b15334;  // R3
localparam [255:0] NM_B3  = 256'h963bd679cea9b1340d539c6e31f4b240afaa322adf0975bb6223415b2ff73db9;  // R4
localparam [255:0] NM_B4  = 256'h0000000000000000000000000000000000000000000000000000000000000005;  // SMALL
localparam [255:0] NM_B5  = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54122;  // A0
localparam [255:0] NM_B6  = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54122;  // A1
localparam [255:0] NM_B7  = 256'h0000000000000000000000000000000000000000000000000000000000000001;  // AONE
localparam [255:0] NM_B8  = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54122;  // BN1N1
localparam [255:0] NM_B9  = 256'h0000000000000000000000000000000000000000000000000000000000000002;  // BN1_2
localparam [255:0] NM_B10  = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54121;  // BN1_N2
localparam [255:0] NM_B11  = 256'h0000000000000000000000000000000000000000000000000000000000000000;  // B0
localparam [255:0] NM_B12  = 256'h8000000000000000000000000000000000000000000000000000000000000000;  // BMSB
localparam [255:0] NM_B13  = 256'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;  // BHI

// --- 期望值 (a*b mod n, 由 Python 参考模型计算) ---
localparam [255:0] NM_EXP0 = 256'h4ab6fcb190c25dfe738a151e0d4a5905e910f64efd7566b1e85e7df5c2e0460f;  // R1
localparam [255:0] NM_EXP1 = 256'h3e3ffad36a5538a6336720a6756400b3a25ef9a2bf65a5c167a8845b747b0ce1;  // R2
localparam [255:0] NM_EXP2 = 256'h2a21e8856822b5114ea8061e90b462d82f9db6d5356db46a965c6fa05b861304;  // R3
localparam [255:0] NM_EXP3 = 256'hc2408ec5f6d0b0dffeb76fc2d898e7aee354a8bfe73d3a62da44b554b2773bd2;  // R4
localparam [255:0] NM_EXP4 = 256'h000000000000000000000000000000000000000000000000000000000000000f;  // SMALL
localparam [255:0] NM_EXP5 = 256'h0000000000000000000000000000000000000000000000000000000000000000;  // A0
localparam [255:0] NM_EXP6 = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54122;  // A1
localparam [255:0] NM_EXP7 = 256'h0000000000000000000000000000000000000000000000000000000000000001;  // AONE
localparam [255:0] NM_EXP8 = 256'h0000000000000000000000000000000000000000000000000000000000000001;  // BN1N1
localparam [255:0] NM_EXP9 = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54121;  // BN1_2
localparam [255:0] NM_EXP10 = 256'h0000000000000000000000000000000000000000000000000000000000000002;  // BN1_N2
localparam [255:0] NM_EXP11 = 256'h0000000000000000000000000000000000000000000000000000000000000000;  // B0
localparam [255:0] NM_EXP12 = 256'h7ffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123;  // BMSB
localparam [255:0] NM_EXP13 = 256'h800000010000000000000000000000008dfc2094de39fad4ac440bf6c62abeda;  // BHI

// --- 按索引函数: nm_vec_a ---
function [255:0] nm_vec_a;
    input integer i;
    begin
        case (i)
            0: nm_vec_a = NM_A0;
            1: nm_vec_a = NM_A1;
            2: nm_vec_a = NM_A2;
            3: nm_vec_a = NM_A3;
            4: nm_vec_a = NM_A4;
            5: nm_vec_a = NM_A5;
            6: nm_vec_a = NM_A6;
            7: nm_vec_a = NM_A7;
            8: nm_vec_a = NM_A8;
            9: nm_vec_a = NM_A9;
            10: nm_vec_a = NM_A10;
            11: nm_vec_a = NM_A11;
            12: nm_vec_a = NM_A12;
            13: nm_vec_a = NM_A13;
            default: nm_vec_a = 256'h0000000000000000000000000000000000000000000000000000000000000000;
        endcase
    end
endfunction

// --- 按索引函数: nm_vec_b ---
function [255:0] nm_vec_b;
    input integer i;
    begin
        case (i)
            0: nm_vec_b = NM_B0;
            1: nm_vec_b = NM_B1;
            2: nm_vec_b = NM_B2;
            3: nm_vec_b = NM_B3;
            4: nm_vec_b = NM_B4;
            5: nm_vec_b = NM_B5;
            6: nm_vec_b = NM_B6;
            7: nm_vec_b = NM_B7;
            8: nm_vec_b = NM_B8;
            9: nm_vec_b = NM_B9;
            10: nm_vec_b = NM_B10;
            11: nm_vec_b = NM_B11;
            12: nm_vec_b = NM_B12;
            13: nm_vec_b = NM_B13;
            default: nm_vec_b = 256'h0000000000000000000000000000000000000000000000000000000000000000;
        endcase
    end
endfunction

// --- 按索引函数: nm_vec_exp ---
function [255:0] nm_vec_exp;
    input integer i;
    begin
        case (i)
            0: nm_vec_exp = NM_EXP0;
            1: nm_vec_exp = NM_EXP1;
            2: nm_vec_exp = NM_EXP2;
            3: nm_vec_exp = NM_EXP3;
            4: nm_vec_exp = NM_EXP4;
            5: nm_vec_exp = NM_EXP5;
            6: nm_vec_exp = NM_EXP6;
            7: nm_vec_exp = NM_EXP7;
            8: nm_vec_exp = NM_EXP8;
            9: nm_vec_exp = NM_EXP9;
            10: nm_vec_exp = NM_EXP10;
            11: nm_vec_exp = NM_EXP11;
            12: nm_vec_exp = NM_EXP12;
            13: nm_vec_exp = NM_EXP13;
            default: nm_vec_exp = 256'h0000000000000000000000000000000000000000000000000000000000000000;
        endcase
    end
endfunction

`endif
