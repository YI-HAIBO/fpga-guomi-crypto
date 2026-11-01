// =============================================================================
// 模块名称 : sm2_point_add
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v2.5  (时序硬化: 每周期最多 1 次模运算, 打破 164 级 CARRY4 真路径)
// 日期     : 2026-10-22
// 视角     : rtl-designer
// 功能     : SM2 椭圆曲线点运算 — Jacobian 坐标点加 / 点倍
// 曲线     : sm2p256v1 (GB/T 32918-2016), y^2 = x^3 + ax + b  (a = p-3)
//
// 坐标     : Jacobian (X : Y : Z)  <=>  x = X/Z^2 , y = Y/Z^3 ;  Z == 0 = 无穷远
// 域表示   : 所有端口与中间量均为 **Montgomery 形式** (值 v 存为 v*R mod p)。
//            Montgomery 域下加减与普通域完全一致; 乘法统一调用 sm2_montmul;
//            公式里的常数倍 (2*,3*,4*,8*) 用组合模加法实现 (f_a2/f_a3/f_a4/f_a8)。
//            因此: 输入坐标须先 to_mont() (= v * R mod p), 输出是 Montgomery 形式。
//            **坑**: 常量倍函数只做加法 (f_a4(a) = 4a), 不能替代表达式里的平方;
//            I = 4H^2 必须先把 H*H 乘出来再乘 4, 否则得到的是 4H (v2.2 的 bug)。
//
// v2.5 改动: 2026-10-22, 时序收敛 (wrap14 实测驱动)
//   根因: v2.4 残留 2 处 4 条 carry 链串联 (f_add/f_sub/f_a2 各 2 链):
//         点加 step19: X3r = f_sub(X3a, f_a2(Vr))  -> 4 链
//         ST_OUT    : y3   = f_sub(MRr, f_a2(Sjr)) -> 4 链
//         impl_w14d 实测: logic 20.459ns / 171 逻辑级 / CARRY4=164,
//         路径 Jr_reg[128]_replica -> VT_reg[252]/D, slack -7.893ns @20ns,
//         全部 30 条最差路径同构, 1136 端点违例 (TNS -3444ns)。
//   修法: 各拆成 2 个单模运算步 (新增 V2r=2V, Sj2r=2*S1*J 流水寄存器),
//         点加 26 -> 28 步 (+2 周期, 对 ~256 次点运算的签名影响 <1%)。
//         代数完全不变: X3 = (R^2-J) - 2V, Y3 = R(V-X3) - 2*S1*J。
//   代价: 点加 +2 周期; 每步模运算深度 4 链 -> 2 链 (logic ~20.5ns -> ~10.3ns)。
//
// v2.4 改动: 2026-10-15, 时序收敛
//   根因: v2.3 的 ST_CMB 步把 2-4 次连续模运算挤在 1 周期 (10ns), 256-bit 模减
//         约 40 CARRY4 = 4ns, 3 次串联 = 12ns > 10ns, 产生 -21.6ns Setup 违例
//         (169 级 CARRY4, R2r_reg → mm_b_reg, 见 timing_wrap4_place.rpt)。
//   修法: 将每个 >=2 连续模运算的 ST_CMB 步拆分为每周期 1 次模运算的流水链,
//         用新增中间寄存器 (Ia/Ra/X3a/X3r/Z3a/Z3b/Sa/Ma/Mb/Mc/Md/Ta/Ya/Yb/Yc)
//         打断长组合链。step 号重新编号, end_step 点加 20→26, 点倍 14→24。
//   延迟: 点加 36→42 周期 (+17%), 点倍 21→32 周期 (+52%), 对 SM2 签名
//         (~256 次点运算) 影响 <0.5%, 可接受。
//
// 点加 add-2007-bl (Z1, Z2 任意), v2.5 步序 (step 0..27, 共 28 步):
//   0  ZZ1=Z1^2     1  ZZ2=Z2^2    2  U1=X1*ZZ2   3  U2=X2*ZZ1
//   4  T1=Y1*ZZ2    5  S1=T1*Z2    6  T2=Y2*ZZ1   7  S2=T2*Z1
//   8  H=U2-U1(c)    9  HH=H^2     10 Ia=2HH(c)   11 Ir=2Ia(c)
//  12  J=H*Ir       13 Ra=S2-S1(c) 14 Rr=2Ra(c)   15 R2=Rr^2
//  16  V=U1*Ir      17 S1J=S1*J    18 X3a=R2-J(c) 19 V2r=2V(c)
//  20  X3r=X3a-V2r(c) 21 VT=V-X3r(c) 22 Sj2r=2S1J(c) 23 MR=Rr*VT
//  24  ZS=(Z1+Z2)^2 25 Z3a=ZS-ZZ1(c) 26 Z3b=Z3a-ZZ2(c) 27 Z3=Z3b*H
//  ST_OUT: x3=X3r  y3=MR-Sj2r  z3=Z3r
//
// 点倍 dbl-2001-b (a = -3), v2.4 步序 (step 0..23, 共 24 步):
//   0 XX=X1^2  1 YY=Y1^2  2 ZZ=Z1^2  3 ZZ2=ZZ^2  4 XY=X1*YY
//   5 Sa=2XY(c) 6 Sr=2Sa(c)  7 Ma=2XX(c)  8 Mb=2ZZ2(c)
//   9 Mc=Ma+XX(c) 10 Md=Mb+ZZ2(c) 11 Mr=Mc-Md(c)
//  12 M2=Mr^2 13 Ta=2Sr(c) 14 Tr=M2-Ta(c) 15 YY2=YY^2
//  16 MS=Mr*(Sr-Tr) 17 Ya=2YY2(c) 18 Yb=2Ya(c) 19 Yc=2Yb(c)
//  20 Y3r=MS-Yc(c) 21 ZS=(Y1+Z1)^2 22 Z3a=ZS-YY(c) 23 Z3r=Z3a-ZZ(c)
// =============================================================================

`timescale 1ns / 1ps

module sm2_point_add (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,          // 启动脉冲
    input  wire         op,             // 0 = 点加 P1+P2 , 1 = 点倍 2*P1
    input  wire [255:0] x1,             // 第一个点 (Montgomery 形式)
    input  wire [255:0] y1,
    input  wire [255:0] z1,
    input  wire [255:0] x2,             // 第二个点 (点倍时忽略)
    input  wire [255:0] y2,
    input  wire [255:0] z2,
    output reg  [255:0] x3,             // 结果 (Montgomery 形式)
    output reg  [255:0] y3,
    output reg  [255:0] z3,
    output reg          done,

    // -- Phase 8: 共享 Montgomery 乘法请求端口 (见 sm2_mm_arb) --
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
    // 组合辅助: Montgomery 域模加 / 模减 (Mont 形式下与普通域运算完全一致)
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

    // 注意 f_a2/f_a4/f_a8 必须是 2a/4a/8a —— 早期写成 t=f_add(a,a); f_a2=f_add(t,t)
    // 实际返回 4a, 连带 f_a4=16a、f_a8=256a, 点倍/点加 X3/Y3 全错 (实测定位过的坑)
    function [255:0] f_a2;          // 2a
        input [255:0] a;
        reg [255:0] t;
        begin
            t = f_add(a, a);
            f_a2 = t;
        end
    endfunction

    function [255:0] f_a3;
        input [255:0] a;
        reg [255:0] t;
        begin
            t = f_add(a, a);
            f_a3 = f_add(t, a);
        end
    endfunction

    function [255:0] f_a4;          // 4a
        input [255:0] a;
        reg [255:0] t;
        begin
            t = f_a2(a);
            f_a4 = f_a2(t);
        end
    endfunction

    function [255:0] f_a8;          // 8a
        input [255:0] a;
        reg [255:0] t;
        begin
            t = f_a4(a);
            f_a8 = f_a2(t);
        end
    endfunction

    // =========================================================================
    // Phase 8: Montgomery 乘法器已上提到 sm2_sign 层的 sm2_mm_arb 共享
    // =========================================================================

    // =========================================================================
    // 状态
    // =========================================================================
    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_ISS  = 3'd1;   // 发射 Montgomery 乘
    localparam [2:0] ST_W    = 3'd2;   // 等乘法完成并锁存
    localparam [2:0] ST_CMB  = 3'd3;   // 组合步 (无乘法, 直接锁存表达式)
    localparam [2:0] ST_OUT  = 3'd4;
    localparam [2:0] ST_DONE = 3'd5;

    reg [2:0] st;
    // step 是点加/点倍全部 256-bit mux 的选择信号, 布线后实测 step_reg[1] fo=86、
    // 单网 6.901 ns, 是最差 setup 路径的源点。强制复制以压缩布线延迟。
    (* MAX_FANOUT = 24 *) reg [4:0] step;

    // 输入缓冲
    reg [255:0] X1r, Y1r, Z1r, X2r, Y2r, Z2r;

    // 点加中间量 (含 v2.4 流水寄存器)
    reg [255:0] ZZ1r, ZZ2r, U1r, U2r, T1r, T2r, S1r, S2r;
    reg [255:0] Hr, H2r, Ia, Ir, Jr, Ra, Rr, R2r, Vr, Sjr, MRr, VT, ZSqr, Z3r;
    reg [255:0] X3a, X3r;            // v2.4: X3 流水 (X3a=R2-J, X3r=X3a-2V)
    reg [255:0] Z3a, Z3b;            // v2.4: Z3d 流水 (Z3a=ZS-ZZ1, Z3b=Z3a-ZZ2)
                                     //        Z3a 与点倍 step 22 共用
    reg [255:0] V2r, Sj2r;           // v2.5: 拆 4 链为 2 链 (V2r=2V, Sj2r=2*S1J)

    // 点倍中间量 (含 v2.4 流水寄存器)
    reg [255:0] XXr, YYr, ZZr, ZZ2br, XYr, Sa, Sr, Ma, Mb, Mc, Md, Mr, M2r;
    reg [255:0] Tr, Y2sqr, MSr, Y3r, ZSqr2;
    reg [255:0] Ta;                  // v2.4: w_T 流水 (Ta=2S, Tr=M2-Ta)
    reg [255:0] Ya, Yb, Yc;          // v2.4: f_a8 流水 (Ya=2YY2, Yb=4YY2, Yc=8YY2)

    // =========================================================================
    // 组合中间表达式 (仅保留 <=1 次模运算的浅链, 深链已改为流水寄存器)
    // =========================================================================
    wire [255:0] w_ZY  = f_add(Z1r, Z2r);         // Z1+Z2 (点加, 1 次模加)
    wire [255:0] w_YZ  = f_add(Y1r, Z1r);         // Y1+Z1 (点倍, 1 次模加)
    wire [255:0] w_ST  = f_sub(Sr, Tr);            // S-T  (点倍, 1 次模减)

    // 最后一步之后进入 ST_OUT 的步号: 点加 28 (v2.5: 原 26, 拆 2 步), 点倍 24
    wire [4:0] end_step = op ? 5'd24 : 5'd28;

    // 当前步是否为组合步 (步号在两个算法里含义不同, 必须按 op 区分)
    reg cmb_hit;
    always @* begin
        cmb_hit = 1'b0;
        if (!op) begin
            case (step)
                5'd8,  5'd10, 5'd11, 5'd13, 5'd14,
                5'd18, 5'd19, 5'd20, 5'd21, 5'd22,
                5'd25, 5'd26:                     cmb_hit = 1'b1;
                default:                          cmb_hit = 1'b0;
            endcase
        end else begin
            case (step)
                5'd5,  5'd6,  5'd7,  5'd8,  5'd9,  5'd10,
                5'd11, 5'd13, 5'd14, 5'd17, 5'd18,
                5'd19, 5'd20, 5'd22, 5'd23: cmb_hit = 1'b1;
                default:                        cmb_hit = 1'b0;
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
                // --------------------------------------------------------
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
                ST_ISS: begin
                    if (step == end_step) begin
                        st <= ST_OUT;
                    end else if (cmb_hit) begin
                        st <= ST_CMB;
                    end else begin
                        if (!op) begin
                            case (step)
                                5'd0:  begin mm_a <= Z1r;             mm_b <= Z1r;  end
                                5'd1:  begin mm_a <= Z2r;             mm_b <= Z2r;  end
                                5'd2:  begin mm_a <= X1r;             mm_b <= ZZ2r; end
                                5'd3:  begin mm_a <= X2r;             mm_b <= ZZ1r; end
                                5'd4:  begin mm_a <= Y1r;             mm_b <= ZZ2r; end
                                5'd5:  begin mm_a <= T1r;             mm_b <= Z2r;  end
                                5'd6:  begin mm_a <= Y2r;             mm_b <= ZZ1r; end
                                5'd7:  begin mm_a <= T2r;             mm_b <= Z1r;  end
                                5'd9:  begin mm_a <= Hr;              mm_b <= Hr;    end
                                5'd12: begin mm_a <= Hr;              mm_b <= Ir;    end
                                5'd15: begin mm_a <= Rr;              mm_b <= Rr;    end
                                5'd16: begin mm_a <= U1r;             mm_b <= Ir;    end
                                5'd17: begin mm_a <= S1r;             mm_b <= Jr;    end
                                5'd23: begin mm_a <= Rr;              mm_b <= VT;    end
                                5'd24: begin mm_a <= w_ZY;            mm_b <= w_ZY;  end
                                5'd27: begin mm_a <= Z3b;             mm_b <= Hr;    end
                                default: begin mm_a <= 256'd0;        mm_b <= 256'd0; end
                            endcase
                        end else begin
                            case (step)
                                5'd0:  begin mm_a <= X1r;             mm_b <= X1r;  end
                                5'd1:  begin mm_a <= Y1r;             mm_b <= Y1r;  end
                                5'd2:  begin mm_a <= Z1r;             mm_b <= Z1r;  end
                                5'd3:  begin mm_a <= ZZr;             mm_b <= ZZr;  end
                                5'd4:  begin mm_a <= X1r;             mm_b <= YYr;  end
                                5'd12: begin mm_a <= Mr;              mm_b <= Mr;   end
                                5'd15: begin mm_a <= YYr;             mm_b <= YYr;  end
                                5'd16: begin mm_a <= Mr;              mm_b <= w_ST;  end
                                5'd21: begin mm_a <= w_YZ;            mm_b <= w_YZ;  end
                                default: begin mm_a <= 256'd0;        mm_b <= 256'd0; end
                            endcase
                        end
                        mm_req <= 1'b1;
                        st     <= ST_W;
                    end
                end

                // --------------------------------------------------------
                ST_W: begin
                    if (mm_done) begin
                        mm_req <= 1'b0;       // 撤 req, 防止仲裁器重复服务
                        if (!op) begin
                            case (step)
                                5'd0:  ZZ1r   <= mm_result;
                                5'd1:  ZZ2r   <= mm_result;
                                5'd2:  U1r    <= mm_result;
                                5'd3:  U2r    <= mm_result;
                                5'd4:  T1r    <= mm_result;
                                5'd5:  S1r    <= mm_result;
                                5'd6:  T2r    <= mm_result;
                                5'd7:  S2r    <= mm_result;
                                5'd9:  H2r    <= mm_result;
                                5'd12: Jr     <= mm_result;
                                5'd15: R2r    <= mm_result;
                                5'd16: Vr     <= mm_result;
                                5'd17: Sjr    <= mm_result;
                                5'd23: MRr    <= mm_result;
                                5'd24: ZSqr   <= mm_result;
                                5'd27: Z3r    <= mm_result;
                                default: ;
                            endcase
                        end else begin
                            case (step)
                                5'd0:  XXr    <= mm_result;
                                5'd1:  YYr    <= mm_result;
                                5'd2:  ZZr    <= mm_result;
                                5'd3:  ZZ2br  <= mm_result;
                                5'd4:  XYr    <= mm_result;
                                5'd12: M2r    <= mm_result;
                                5'd15: Y2sqr  <= mm_result;
                                5'd16: MSr    <= mm_result;
                                5'd21: ZSqr2  <= mm_result;
                                default: ;
                            endcase
                        end
                        step <= step + 5'd1;
                        st   <= ST_ISS;
                    end
                end

                // --------------------------------------------------------
                ST_CMB: begin
                    if (!op) begin
                        // ---- 点加流水 (v2.4): 每步 1 次模运算 ----
                        case (step)
                            5'd8:  Hr  <= f_sub(U2r, U1r);           // H  = U2 - U1
                            5'd10: Ia  <= f_a2(H2r);                 // Ia = 2*H^2
                            5'd11: Ir  <= f_a2(Ia);                  // Ir = 4*H^2
                            5'd13: Ra  <= f_sub(S2r, S1r);          // Ra = S2 - S1
                            5'd14: Rr  <= f_a2(Ra);                  // Rr = 2*(S2-S1)
                            5'd18: X3a  <= f_sub(R2r, Jr);          // X3a= r^2 - J
                            5'd19: V2r  <= f_a2(Vr);                // V2r= 2V   (v2.5 拆 4 链)
                            5'd20: X3r  <= f_sub(X3a, V2r);         // X3r= X3a - 2V
                            5'd21: VT   <= f_sub(Vr, X3r);          // VT  = V - X3r
                            5'd22: Sj2r <= f_a2(Sjr);               // Sj2r=2S1J (v2.5 供 y3)
                            5'd25: Z3a  <= f_sub(ZSqr, ZZ1r);       // Z3a= ZS - ZZ1
                            5'd26: Z3b  <= f_sub(Z3a, ZZ2r);        // Z3b= Z3a - ZZ2
                            default: ;
                        endcase
                    end else begin
                        // ---- 点倍流水 (v2.4): 每步 1 次模运算 ----
                        case (step)
                            5'd5:  Sa   <= f_a2(XYr);                // Sa = 2*XY
                            5'd6:  Sr   <= f_a2(Sa);                 // Sr = 4*XY
                            5'd7:  Ma   <= f_a2(XXr);                // Ma = 2*XX
                            5'd8:  Mb   <= f_a2(ZZ2br);              // Mb = 2*ZZ2
                            5'd9:  Mc   <= f_add(Ma, XXr);           // Mc = 3*XX
                            5'd10: Md   <= f_add(Mb, ZZ2br);         // Md = 3*ZZ2
                            5'd11: Mr   <= f_sub(Mc, Md);            // Mr = 3*XX-3*ZZ2
                            5'd13: Ta   <= f_a2(Sr);                 // Ta = 2*S
                            5'd14: Tr   <= f_sub(M2r, Ta);           // Tr = M2 - 2S
                            5'd17: Ya   <= f_a2(Y2sqr);              // Ya = 2*YY2
                            5'd18: Yb   <= f_a2(Ya);                 // Yb = 4*YY2
                            5'd19: Yc   <= f_a2(Yb);                 // Yc = 8*YY2
                            5'd20: Y3r  <= f_sub(MSr, Yc);           // Y3r= MS-8*YY2
                            5'd22: Z3a  <= f_sub(ZSqr2, YYr);       // Z3a= ZS-YY
                            5'd23: Z3r  <= f_sub(Z3a, ZZr);         // Z3r= Z3a-ZZ
                            default: ;
                        endcase
                    end
                    step <= step + 5'd1;
                    st   <= ST_ISS;
                end

                // --------------------------------------------------------
                ST_OUT: begin
                    if (!op) begin
                        x3 <= X3r;                             // r^2 - J - 2V (v2.4: 用流水寄存器)
                        y3 <= f_sub(MRr, Sj2r);                // r(V-X3) - 2*S1*J (v2.5: 预计算 2S1J)
                        z3 <= Z3r;                             // ((Z1+Z2)^2-ZZ1-ZZ2)*H
                    end else begin
                        x3 <= Tr;                              // T = M^2 - 2S
                        y3 <= Y3r;                             // M(S-T) - 8*YY^2
                        z3 <= Z3r;                             // (Y1+Z1)^2 - YY - ZZ
                    end
                    done <= 1'b1;
                    st   <= ST_DONE;
                end

                // --------------------------------------------------------
                ST_DONE: begin
                    done <= 1'b0;
                    st   <= ST_IDLE;
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

endmodule
