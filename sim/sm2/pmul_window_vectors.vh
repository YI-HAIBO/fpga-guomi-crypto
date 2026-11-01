// ============================================================================
// pmul_window_vectors.vh  -  sm2_pmul_windowed TB 期望向量
// 由 .workbuddy/tmp/pmul_window_ref.py 自动生成, 勿手改 (w=4)
//
// 每条向量的期望 Jacobian (X,Y,Z) 由 Python 参考模型给出, 该模型已通过:
//   [B] 仿射解码校准 + [C] 与已签核 sm2_pmul v2.0 RTL 输出逐位一致
//   [E] 窗口化结果与 DAA 仿射等价
// ============================================================================
// Ver-2005 约束 (本机 iverilog -g2005 实测):
//   * 文件作用域 parameter/localparam 一律拒绝  -> 本 .vh 必须 include 在
//     module 体内
//   * 无 localparam 数组 (那是 SystemVerilog) -> 每列向量展开为标量
//     VEC_XX0..VEC_XX{VEC_NUM-1}, 并用 vec_xx(i) 按索引取值
`ifndef PMUL_WINDOW_VECTORS_VH
`define PMUL_WINDOW_VECTORS_VH

    localparam integer VEC_NUM = 11;

    // 基点 (Montgomery 形式): px = to_mont(Gx), py = to_mont(Gy), pz = R mod p
    localparam [255:0] PM_PX = 256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e;
    localparam [255:0] PM_PY = 256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd;
    localparam [255:0] PM_PZ = 256'h0000000100000000000000000000000000000000ffffffff0000000000000001;

    // 标量期望向量 K
    localparam [255:0] VEC_K0 = 256'h0000000000000000000000000000000000000000000000000000000000000001;  /* K1 */
    localparam [255:0] VEC_K1 = 256'h0000000000000000000000000000000000000000000000000000000000000002;  /* K2 */
    localparam [255:0] VEC_K2 = 256'h0000000000000000000000000000000000000000000000000000000000000003;  /* K3 */
    localparam [255:0] VEC_K3 = 256'h0000000000000000000000000000000000000000000000000000000000000007;  /* K7 */
    localparam [255:0] VEC_K4 = 256'h000000000000000000000000000000000000000000000000000000000000000f;  /* K15 */
    localparam [255:0] VEC_K5 = 256'h0000000000000000000000000000000000000000000000000000000000000010;  /* K16 */
    localparam [255:0] VEC_K6 = 256'h00000000000000000000000000000000000000000000000000000000000000ff;  /* K255 */
    localparam [255:0] VEC_K7 = 256'h8000000000000000000000000000000000000000000000000000000000000000;  /* KMSB */
    localparam [255:0] VEC_K8 = 256'h00000000000000000000000000000000000000000000000000000000093638f1;  /* KR1 */
    localparam [255:0] VEC_K9 = 256'h00000000000000000000000000000000000000000000000000000000034b567a;  /* KR2 */
    localparam [255:0] VEC_K10 = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54122;  /* KNM1 */

    // 标量期望向量 EX
    localparam [255:0] VEC_EX0 = 256'h91167a5ee1c13b05d6a1ed99ac24c3c33e7981eddca6c05061328990f418029e;  /* K1 */
    localparam [255:0] VEC_EX1 = 256'h398874c476a3b1f77aef3e862601440903243d78d5b614a62eda8381e63c48d6;  /* K2 */
    localparam [255:0] VEC_EX2 = 256'hc056b481df2300a1775dbef2f7c0df90f147ad031f142af014a5303d4d263438;  /* K3 */
    localparam [255:0] VEC_EX3 = 256'h024df95fd525e4e302255d47a87b7fcda84c42424bd4e2c80aa8c45c0837ff88;  /* K7 */
    localparam [255:0] VEC_EX4 = 256'h3da4271d34341c0105d967eb7996a5ab9ab5dc4a1b265d8ded4add5753b82694;  /* K15 */
    localparam [255:0] VEC_EX5 = 256'h54ea747ff266e11d75c5d1db1c5abe01953dc915f0df5af3e899b82f1a71c36f;  /* K16 */
    localparam [255:0] VEC_EX6 = 256'hee2edd834db8bd1122b65b982a6e1a9dfbe3b2dd42308efd926da2f814911457;  /* K255 */
    localparam [255:0] VEC_EX7 = 256'h9aa29d06b562338717d56cf1ebda6de74715e1f46ae962f1a82057211ccb2d38;  /* KMSB */
    localparam [255:0] VEC_EX8 = 256'hff457b5d8cae77878ed24d2d88ad6c99e34ab8cd0de97e266e67ad29442aedb7;  /* KR1 */
    localparam [255:0] VEC_EX9 = 256'h07172840ce5eba47e73f40ea133129ece89cd45ba7e29b47c25bea263a98f553;  /* KR2 */
    localparam [255:0] VEC_EX10 = 256'h920ef3e6ba595de57479410db450fdadd4753bd8bdc088d9c362befc3f296877;  /* KNM1 */

    // 标量期望向量 EY
    localparam [255:0] VEC_EY0 = 256'h63cd65d481d735bd8d4cfb066e2a48f8c1f5e5788d3295fac1354e593c2d0ddd;  /* K1 */
    localparam [255:0] VEC_EY1 = 256'h1fbbdfdddaf4fd475a86a7ae64921d4829f04a88f6cf4dc128385681c1a73e40;  /* K2 */
    localparam [255:0] VEC_EY2 = 256'h4c1055380f2f77d3ce47047418c7ea5b082b3ab8cede9e2095fa23b42074661f;  /* K3 */
    localparam [255:0] VEC_EY3 = 256'h417b7bc2314b56b63e9ce3613c60b44a6ffc52d0202bb62d28abe9c5b7b31116;  /* K7 */
    localparam [255:0] VEC_EY4 = 256'h9657626b9b6e7010802a93df4978fb0c8fb2e3878509e0ddba1b05ab4e6472bb;  /* K15 */
    localparam [255:0] VEC_EY5 = 256'h211f9870979316c0044d1bea3613f6fa0f5c0a0b1629eacd7ce89b13b22caba5;  /* K16 */
    localparam [255:0] VEC_EY6 = 256'h1665fffcee73a7150ed9a158f98c7dba00495532f65b0aa599e11eb06d47a179;  /* K255 */
    localparam [255:0] VEC_EY7 = 256'he70c055936eebe20bb6ae70975368a45e20f7b206cec2e039fa1e001636ccd4c;  /* KMSB */
    localparam [255:0] VEC_EY8 = 256'h640ae512a707a2c44307b46fdb36a9aa309e9a6ddc09057f723b28b539ea5d06;  /* KR1 */
    localparam [255:0] VEC_EY9 = 256'hdada2d34a584202faf340a7305cb8833671fb321d6d3e381fd07edb68a8e7143;  /* KR2 */
    localparam [255:0] VEC_EY10 = 256'hdfcc9998f18c061d7a17e9f1191b267cdbf653741f74c10930a6c0ef2832fa68;  /* KNM1 */

    // 标量期望向量 EZ
    localparam [255:0] VEC_EZ0 = 256'h0000000100000000000000000000000000000000ffffffff0000000000000001;  /* K1 */
    localparam [255:0] VEC_EZ1 = 256'hc79acba903ae6b7b1a99f60cdc5491f183ebcaf11a652bf5826a9cb2785a1bba;  /* K2 */
    localparam [255:0] VEC_EZ2 = 256'h385bdb480d7bd163fa7be0a4df92e43b4f9ad9a70221a97b5d1dc679a7ac999c;  /* K3 */
    localparam [255:0] VEC_EZ3 = 256'h21c5609e732e15cbeae7bb0976a74ceb4f1f2c4cacacd962926b69c07008df0a;  /* K7 */
    localparam [255:0] VEC_EZ4 = 256'hbcf0c4135b32cc7597d74a5bf0aded334716c21e2b325755294e882b22c22243;  /* K15 */
    localparam [255:0] VEC_EZ5 = 256'h1acc5cec17e31a581de8319dbd637ee5e466ae787547e09fa5a2c36b856379fa;  /* K16 */
    localparam [255:0] VEC_EZ6 = 256'h87af56947b0aded64e46d4213d9ef0a76d174f7c63cc724c9d69bb440e2d0562;  /* K255 */
    localparam [255:0] VEC_EZ7 = 256'hf92eb55d80565cdd79f8f12225f6348b010340b9d5b3bd0bfc56becc32f229d6;  /* KMSB */
    localparam [255:0] VEC_EZ8 = 256'h549285ffc07db0edede67df79c9df785f4bbb7a93b6fc3d8dcc98a2bcd50fad5;  /* KR1 */
    localparam [255:0] VEC_EZ9 = 256'hd407f51912259d0b9ba09070a7358e3074591ffbfb838eb985486a0a80463836;  /* KR2 */
    localparam [255:0] VEC_EZ10 = 256'h875e5441bfb53351dcb2fcbf2dfcf4ea1305fcd5c9407c55494195626bc3f535;  /* KNM1 */

    // 按索引取 K 向量
    function [255:0] vec_k (input integer i);
        begin
            case (i)
                0: vec_k = VEC_K0;
                1: vec_k = VEC_K1;
                2: vec_k = VEC_K2;
                3: vec_k = VEC_K3;
                4: vec_k = VEC_K4;
                5: vec_k = VEC_K5;
                6: vec_k = VEC_K6;
                7: vec_k = VEC_K7;
                8: vec_k = VEC_K8;
                9: vec_k = VEC_K9;
                10: vec_k = VEC_K10;
                default: vec_k = 256'd0;
            endcase
        end
    endfunction

    // 按索引取 EX 向量
    function [255:0] vec_ex (input integer i);
        begin
            case (i)
                0: vec_ex = VEC_EX0;
                1: vec_ex = VEC_EX1;
                2: vec_ex = VEC_EX2;
                3: vec_ex = VEC_EX3;
                4: vec_ex = VEC_EX4;
                5: vec_ex = VEC_EX5;
                6: vec_ex = VEC_EX6;
                7: vec_ex = VEC_EX7;
                8: vec_ex = VEC_EX8;
                9: vec_ex = VEC_EX9;
                10: vec_ex = VEC_EX10;
                default: vec_ex = 256'd0;
            endcase
        end
    endfunction

    // 按索引取 EY 向量
    function [255:0] vec_ey (input integer i);
        begin
            case (i)
                0: vec_ey = VEC_EY0;
                1: vec_ey = VEC_EY1;
                2: vec_ey = VEC_EY2;
                3: vec_ey = VEC_EY3;
                4: vec_ey = VEC_EY4;
                5: vec_ey = VEC_EY5;
                6: vec_ey = VEC_EY6;
                7: vec_ey = VEC_EY7;
                8: vec_ey = VEC_EY8;
                9: vec_ey = VEC_EY9;
                10: vec_ey = VEC_EY10;
                default: vec_ey = 256'd0;
            endcase
        end
    endfunction

    // 按索引取 EZ 向量
    function [255:0] vec_ez (input integer i);
        begin
            case (i)
                0: vec_ez = VEC_EZ0;
                1: vec_ez = VEC_EZ1;
                2: vec_ez = VEC_EZ2;
                3: vec_ez = VEC_EZ3;
                4: vec_ez = VEC_EZ4;
                5: vec_ez = VEC_EZ5;
                6: vec_ez = VEC_EZ6;
                7: vec_ez = VEC_EZ7;
                8: vec_ez = VEC_EZ8;
                9: vec_ez = VEC_EZ9;
                10: vec_ez = VEC_EZ10;
                default: vec_ez = 256'd0;
            endcase
        end
    endfunction

`endif  // PMUL_WINDOW_VECTORS_VH
