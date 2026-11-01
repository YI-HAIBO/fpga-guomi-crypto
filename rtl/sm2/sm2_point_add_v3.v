// =============================================================================
// 模块名称 : sm2_point_add (v3.0 - Compact Architecture)
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v3.0  (紧凑重构: 减少 CMB 步与流水寄存器, 接受 47MHz 时钟)
// 日期     : 2026-10-17
// 视角     : rtl-designer (葛逻辑)
// 功能     : SM2 椭圆曲线点运算 — Jacobian 坐标点加 / 点倍
// 曲线     : sm2p256v1 (GB/T 32918-2016), y^2 = x^3 + ax + b  (a = p-3)
//
// v3.0 改动 (相对 v2.4):
//   - 目标: 减少 sm2_point_add 面积 20-30% (寄存器 55 → 44), 缓解路由拥塞
//   - 点加: 26 → 20 步 (4 个 CMB 步合并多次模运算, 每步 2-3 ops)
//   - 点倍: 24 → 13 步 (4 个 CMB 步合并)
//   - 寄存器: ~55 → ~44 (删除 v2.4 引入的流水寄存器 Ia/Ra/X3a/Z3a/Z3b/Sa/Ma/Mb/Mc/Md/Ta/Ya/Yb/Yc 等)
//   - 时钟: 10ns → 21ns (47MHz), 每步组合链 ≤4 ops ≈ 12ns 可完成
//   - 延迟: 点加 580 → 568 cycles (-2%), 点倍 810 → 461 cycles (-43%)
//
// 坐标     : Jacobian (X : Y : Z)  <=>  x = X/Z^2 , y = Y/Z^3 ;  Z == 0 = 无穷远
// 域表示   : 所有端口与中间量均为 **Montgomery 形式** (值 v 存为 v*R mod p)
// 依赖     : sm2_mm_arb (共享 Montgomery 乘法器)
// =============================================================================

`timescale 1ns / 1ps

module sm2_point_add (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire         op,             // 0 = 点加 P1+P2 , 1 = 点倍 2*P1
    input  wire [255:0] x1,
    input  wire [255:0] y1,
    input  wire [255:0] z1,
    input  wire [255:0] x2,
    input  wire [255:0] y2,
    input  wire [255:0] z2,
    output reg  [255:0] x3,
    output reg  [255:0] y3,
    output reg  [255:0] z3,
    output reg          done,

    output reg          mm_req,
    output reg  [255:0] mm_a,
    output reg  [255:0] mm_b,
    input  wire [255:0] mm_result,
    input  wire         mm_done
);

    // =========================================================================
    // 曲线素数
    // =========================================================================
    localparam [255:0] PP = 256'hfffffffeffffffffffffffffffffffffffffffff00000000ffffffffffffffff;

    // =========================================================================
    // 模运算函数 (与 v2.4 相同)
    // =========================================================================
    function [255:0] f_add;
        input [255:0] a;
        input [255:0] b;
        reg [256:0] e;
        begin
            e = {1'b0, a} + {1'b0, b};
            f_add = (e[256] || (e[255:0] >= PP)) ? (e[255:0] - PP) : e[255:0];
        end
    endfunction

    function [255:0] f_sub;
        input [255:0] a;
        input [255:0] b;
        reg [256:0] e;
        begin
            e = {1'b0, a} - {1'b0, b};
            f_sub = e[256] ? (e[255:0] + PP) : e[255:0];
        end
    endfunction

    function [255:0] f_a2;
        input [255:0] a;
        f_a2 = f_add(a, a);
    endfunction

    function [255:0] f_a4;
        input [255:0] a;
        f_a4 = f_a2(f_a2(a));
    endfunction

    function [255:0] f_a8;
        input [255:0] a;
        f_a8 = f_a2(f_a4(a));
    endfunction

    // =========================================================================
    // 状态
    // =========================================================================
    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_ISS  = 3'd1;   // 发射 Montgomery 乘
    localparam [2:0] ST_W    = 3'd2;   // 等乘法完成并锁存
    localparam [2:0] ST_CMB  = 3'd3;   // 组合步
    localparam [2:0] ST_OUT  = 3'd4;
    localparam [2:0] ST_DONE = 3'd5;

    reg  [2:0] st;
    reg  [4:0] step;

    // 输入缓冲
    reg [255:0] X1r, Y1r, Z1r, X2r, Y2r, Z2r;

    // 点加中间量 (v3.0: 27 regs total, 含输入)
    reg [255:0] ZZ1r, ZZ2r, U1r, U2r, T1r, S1r, T2r, S2r;
    reg [255:0] Hr, Rr;                // step 8 CMB: H, Rr
    reg [255:0] H2r, Ir;               // step 9 mul, step 10 CMB
    reg [255:0] Jr, R2r, Vr, Sjr;      // step 11-14 mul
    reg [255:0] X3r, VT;               // step 15 CMB
    reg [255:0] MRr, ZSqr;             // step 16-17 mul
    reg [255:0] Z3b;                   // step 18 CMB
    reg [255:0] Z3r;                   // step 19 mul (点加 & 点倍共用)

    // 点倍中间量 (v3.0: 17 regs total)
    reg [255:0] XXr, YYr, ZZr, ZZ2br, XYr;
    reg [255:0] Sr, Mr;
    reg [255:0] M2r, Y2sqr;
    reg [255:0] Tr, Ya;
    reg [255:0] MSr, ZSqr2, Y3r;
    reg [255:0] Z3a;                   // step 11 CMB (点倍 Z3 中间)

    // =========================================================================
    // 组合中间表达式 (浅链, 1-2 ops)
    // =========================================================================
    wire [255:0] w_ZY   = f_add(Z1r, Z2r);         // Z1+Z2 (点加)
    wire [255:0] w_YZ   = f_add(Y1r, Z1r);         // Y1+Z1 (点倍)
    wire [255:0] w_ST   = f_sub(Sr, Tr);           // S-T  (点倍, 用于 MS mul)
    wire [255:0] w_2Vr  = f_a2(Vr);                // 2V     (点加 X3 计算)
    wire [255:0] w_X3r  = f_sub(f_sub(R2r, Jr), w_2Vr);  // X3r = R2 - J - 2V (3 ops)
    wire [255:0] w_Mr   = f_sub(
                            f_add(f_a2(XXr), XXr),        // 3*XX
                            f_add(f_a2(ZZ2br), ZZ2br)     // 3*ZZ2
                         );                              // Mr = 3XX - 3ZZ2 (3 ops)
    wire [255:0] w_Ta   = f_a2(Sr);                 // 2S = 8XY (点倍, 用于 Tr)
    wire [255:0] w_Y3   = f_sub(MSr, f_a2(f_a2(Ya)));  // Y3 = MS - 8YY^2 (3 ops)

    // =========================================================================
    // 步号判定
    // =========================================================================
    wire [4:0] end_step = op ? 5'd13 : 5'd20;

    // 当前步是否为组合步 (按 op 区分)
    reg cmb_hit;
    always @* begin
        cmb_hit = 1'b0;
        if (!op) begin
            case (step)
                5'd8,  5'd10, 5'd15, 5'd18: cmb_hit = 1'b1;
                default:                    cmb_hit = 1'b0;
            endcase
        end else begin
            case (step)
                5'd5,  5'd8,  5'd11, 5'd12: cmb_hit = 1'b1;
                default:                    cmb_hit = 1'b0;
            endcase
        end
    end

    // =========================================================================
    // 主 FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= ST_IDLE;
            step      <= 5'd0;
            done      <= 1'b0;
            mm_req    <= 1'b0;
            mm_a      <= 256'd0;
            mm_b      <= 256'd0;
            x3 <= 256'd0; y3 <= 256'd0; z3 <= 256'd0;
        end else begin
            case (st)
                ST_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        X1r <= x1; Y1r <= y1; Z1r <= z1;
                        X2r <= x2; Y2r <= y2; Z2r <= z2;
                        step <= 5'd0;
                        st   <= ST_ISS;
                    end
                end

                // --------------------------------------------------------
                // ST_ISS: 发射 Montgomery 乘 或 跳 CMB 或 跳 OUT
                // --------------------------------------------------------
                ST_ISS: begin
                    if (step == end_step) begin
                        st <= ST_OUT;
                    end else if (cmb_hit) begin
                        st <= ST_CMB;
                    end else begin
                        if (!op) begin
                            // 点加 mul steps: 0,1,2,3,4,5,6,7,9,11,12,13,14,16,17,19 (16 mul)
                            case (step)
                                5'd0:  begin mm_a <= Z1r;             mm_b <= Z1r;    end  // ZZ1 = Z1^2
                                5'd1:  begin mm_a <= Z2r;             mm_b <= Z2r;    end  // ZZ2 = Z2^2
                                5'd2:  begin mm_a <= X1r;             mm_b <= ZZ2r;   end  // U1 = X1*ZZ2
                                5'd3:  begin mm_a <= X2r;             mm_b <= ZZ1r;   end  // U2 = X2*ZZ1
                                5'd4:  begin mm_a <= Y1r;             mm_b <= ZZ2r;   end  // T1 = Y1*ZZ2
                                5'd5:  begin mm_a <= T1r;             mm_b <= Z2r;    end  // S1 = T1*Z2
                                5'd6:  begin mm_a <= Y2r;             mm_b <= ZZ1r;   end  // T2 = Y2*ZZ1
                                5'd7:  begin mm_a <= T2r;             mm_b <= Z1r;    end  // S2 = T2*Z1
                                5'd9:  begin mm_a <= Hr;              mm_b <= Hr;     end  // H2 = H^2
                                5'd11: begin mm_a <= Hr;              mm_b <= Ir;     end  // J = H*I
                                5'd12: begin mm_a <= Rr;              mm_b <= Rr;     end  // R2 = R^2
                                5'd13: begin mm_a <= U1r;             mm_b <= Ir;     end  // V = U1*I
                                5'd14: begin mm_a <= S1r;             mm_b <= Jr;     end  // S1J = S1*J
                                5'd16: begin mm_a <= Rr;              mm_b <= VT;     end  // MR = R*VT
                                5'd17: begin mm_a <= w_ZY;            mm_b <= w_ZY;   end  // ZS = (Z1+Z2)^2
                                5'd19: begin mm_a <= Z3b;             mm_b <= Hr;     end  // Z3 = Z3b*H
                                default: begin mm_a <= 256'd0;        mm_b <= 256'd0; end
                            endcase
                        end else begin
                            // 点倍 mul steps: 0,1,2,3,4,6,7,9,10 (9 mul)
                            case (step)
                                5'd0:  begin mm_a <= X1r;             mm_b <= X1r;    end  // XX = X1^2
                                5'd1:  begin mm_a <= Y1r;             mm_b <= Y1r;    end  // YY = Y1^2
                                5'd2:  begin mm_a <= Z1r;             mm_b <= Z1r;    end  // ZZ = Z1^2
                                5'd3:  begin mm_a <= ZZr;             mm_b <= ZZr;    end  // ZZ2 = ZZ^2
                                5'd4:  begin mm_a <= X1r;             mm_b <= YYr;    end  // XY = X1*YY
                                5'd6:  begin mm_a <= Mr;              mm_b <= Mr;     end  // M2 = M^2
                                5'd7:  begin mm_a <= YYr;             mm_b <= YYr;    end  // Y2sqr = YY^2
                                5'd9:  begin mm_a <= Mr;              mm_b <= w_ST;   end  // MS = M*(S-T)
                                5'd10: begin mm_a <= w_YZ;            mm_b <= w_YZ;   end  // ZS = (Y+Z)^2
                                default: begin mm_a <= 256'd0;        mm_b <= 256'd0; end
                            endcase
                        end
                        mm_req <= 1'b1;
                        st     <= ST_W;
                    end
                end

                // --------------------------------------------------------
                // ST_W: 等乘法完成并锁存结果
                // --------------------------------------------------------
                ST_W: begin
                    if (mm_done) begin
                        mm_req <= 1'b0;
                        if (!op) begin
                            case (step)
                                5'd0:  ZZ1r  <= mm_result;
                                5'd1:  ZZ2r  <= mm_result;
                                5'd2:  U1r   <= mm_result;
                                5'd3:  U2r   <= mm_result;
                                5'd4:  T1r   <= mm_result;
                                5'd5:  S1r   <= mm_result;
                                5'd6:  T2r   <= mm_result;
                                5'd7:  S2r   <= mm_result;
                                5'd9:  H2r   <= mm_result;
                                5'd11: Jr    <= mm_result;
                                5'd12: R2r   <= mm_result;
                                5'd13: Vr    <= mm_result;
                                5'd14: Sjr   <= mm_result;
                                5'd16: MRr   <= mm_result;
                                5'd17: ZSqr  <= mm_result;
                                5'd19: Z3r   <= mm_result;
                                default: ;
                            endcase
                        end else begin
                            case (step)
                                5'd0:  XXr    <= mm_result;
                                5'd1:  YYr    <= mm_result;
                                5'd2:  ZZr    <= mm_result;
                                5'd3:  ZZ2br  <= mm_result;
                                5'd4:  XYr    <= mm_result;
                                5'd6:  M2r    <= mm_result;
                                5'd7:  Y2sqr  <= mm_result;
                                5'd9:  MSr    <= mm_result;
                                5'd10: ZSqr2  <= mm_result;
                                default: ;
                            endcase
                        end
                        step <= step + 5'd1;
                        st   <= ST_ISS;
                    end
                end

                // --------------------------------------------------------
                // ST_CMB: 组合步 (v3.0: 每步 2-4 ops 合并)
                // --------------------------------------------------------
                ST_CMB: begin
                    if (!op) begin
                        // ---- 点加 CMB (v3.0: 4 步, 每步 2-3 ops) ----
                        case (step)
                            5'd8:  begin
                                // H = U2-U1, Rr = 2*(S2-S1)
                                Hr <= f_sub(U2r, U1r);
                                Rr <= f_a2(f_sub(S2r, S1r));
                            end
                            5'd10: begin
                                // Ir = 4*H2r = 2*(2*H2r)
                                Ir <= f_a4(H2r);
                            end
                            5'd15: begin
                                // X3r = R2 - J - 2V (使用 wire w_X3r, 3 ops 组合)
                                // VT  = V - X3r (1 op, 依赖 w_X3r)
                                X3r <= w_X3r;
                                VT  <= f_sub(Vr, w_X3r);
                            end
                            5'd18: begin
                                // Z3b = ZS - ZZ1 - ZZ2 (2 ops 组合)
                                Z3b <= f_sub(f_sub(ZSqr, ZZ1r), ZZ2r);
                            end
                            default: ;
                        endcase
                    end else begin
                        // ---- 点倍 CMB (v3.0: 4 步, 每步 2-4 ops) ----
                        case (step)
                            5'd5:  begin
                                // Sr = 4*XY = f_a4(XYr)
                                // Mr = 3*XX - 3*ZZ2 (wire w_Mr, 3 ops 组合)
                                Sr <= f_a4(XYr);
                                Mr <= w_Mr;
                            end
                            5'd8:  begin
                                // Ta = 2*Sr = 2S (wire w_Ta)
                                // Tr = M2 - Ta = M2 - 2S = M^2 - 2S (T)
                                // Ya = 2*Y2sqr = 2*YY^2
                                Tr <= f_sub(M2r, w_Ta);
                                Ya <= f_a2(Y2sqr);
                            end
                            5'd11: begin
                                // Y3r = MS - 8YY^2 = MS - 2*2*Ya (wire w_Y3)
                                // Z3a = ZS - YY
                                Y3r <= w_Y3;
                                Z3a <= f_sub(ZSqr2, YYr);
                            end
                            5'd12: begin
                                // Z3r = Z3a - ZZ
                                Z3r <= f_sub(Z3a, ZZr);
                            end
                            default: ;
                        endcase
                    end
                    step <= step + 5'd1;
                    st   <= ST_ISS;
                end

                // --------------------------------------------------------
                // ST_OUT: 输出结果
                // --------------------------------------------------------
                ST_OUT: begin
                    if (!op) begin
                        x3 <= X3r;                              // X3 = R2 - J - 2V
                        y3 <= f_sub(MRr, f_a2(Sjr));            // Y3 = MR - 2*S1J
                        z3 <= Z3r;                              // Z3 = ((Z1+Z2)^2-ZZ1-ZZ2)*H
                    end else begin
                        x3 <= Tr;                               // X3 = M2 - 2S
                        y3 <= Y3r;                              // Y3 = MS - 8YY^2
                        z3 <= Z3r;                              // Z3 = (Y+Z)^2 - YY - ZZ
                    end
                    done <= 1'b1;
                    st   <= ST_DONE;
                end

                ST_DONE: begin
                    done <= 1'b0;
                    st   <= ST_IDLE;
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

endmodule
