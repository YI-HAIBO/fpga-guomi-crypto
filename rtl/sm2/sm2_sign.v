// =============================================================================
// 模块名称 : sm2_sign
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v3.0  (SIGN-ONLY 裁剪版 — 去掉验签路径以突破 xc7a200t 拥塞墙)
//                   v3.0 变更 (2026-10-21, 方案 A):
//                     1. 删除 u_pa (sm2_point_add) 实例 — 该模块独占 54K cells/33%,
//                        且只被验签路径 (R'=[u1]G+[u2]Q 点加) 使用, 签名路径从不进入.
//                     2. 删除验签状态: S_PM2/S_PM2W/S_PAD/S_PADW/S_PADL/S_CHK/S_CHK2.
//                     3. 删除验签寄存器: qx_m/qy_m/x3_plain/u1_r/u2_r/pad2_*/pad3_*/chk_sum.
//                     4. 删除验签端口: op/qx_in/qy_in/r_in/s_in/sig_ok.
//                     5. MM_ARB 从 N=5 降到 N=4: 路序 [0]=modinv [1]=jacaffx
//                        [2]=pm.pa(pmul透传) [3]=sign本路 (原 [2] sign.pa 已删).
//                     6. NM_ARB 保持 N=2: [0]=ninv [1]=sign本路 (签名仍需 k^{-1}).
//                     7. op 端口删除后, S_IDLE 不再分支, e_r 无条件锁存.
//                   保留功能 (签名, GB/T 32918.2 第 6 章):
//                     (x1,y1) = [k]G ;  r = (e + x1) mod n ;  s = k^{-1}*(e + d*r) mod n
//                     r==0 或 r+k==n 或 s==0 -> err=1 (上层重选 k)
//                   验签功能由软件/上位机完成 — 本芯片定位为签名机.
//                   (v2.2 历史: 修 verify 路径 jacaffx/e_r 锁存两处缺陷; v2.1 补
//                    Jacobian->仿射; v2.0 曾把 Jacobian X 当仿射 x 用导致签名全错)
// 日期     : 2026-10-21
// 视角     : rtl-designer
// 依赖     : sm2_pmul, sm2_ninv, sm2_jacaffx, sm2_mm_arb(N=4), sm2_nm_arb(N=2)
// 时序     : 签名 ≈ 0.12M cycles (mod n 模逆占大头)
// =============================================================================
`timescale 1ns / 1ps

module sm2_sign (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,            // 启动脉冲
    input  wire [255:0] d_in,            // 私钥 (plain, 1 <= d < n)
    input  wire [255:0] e_in,            // 摘要 e (plain)
    input  wire [255:0] k_in,            // 随机数 k (plain, 1 <= k < n)
    output reg  [255:0] r_out,           // 签名 r (plain)
    output reg  [255:0] s_out,           // 签名 s (plain)
    output reg          err,             // 输入/签名非法
    output reg          done            // 完成脉冲 (1 cycle)
);

    // =========================================================================
    // 常数
    // =========================================================================
    localparam [255:0] NN       = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123;
    localparam [255:0] R2_MOD_P = 256'h0000000400000002000000010000000100000002ffffffff0000000200000003; // R^2 mod p
    // 基点 G (GB/T 32918.2), plain 形式; 转 Montgomery 靠 mul(v, R^2),
    // **不硬编码 mont(Gx)** — 避免手抄 256'h 常量时出错(本项目踩过的坑)
    localparam [255:0] GX_PLAIN = 256'h32c4ae2c1f1981195f9904466a39c9948fe30bbff2660be1715a4589334c74c7;
    localparam [255:0] GY_PLAIN = 256'hbc3736a2f4f6779c59bdcee36b692153d0a9877cc62a474002df32e52139f0a0;

    // =========================================================================
    // 组合模加 (mod n)
    // =========================================================================
    function [255:0] f_nadd;
        input [255:0] x;
        input [255:0] y;
        reg [256:0] e;
        begin
            e = {1'b0, x} + {1'b0, y};
            f_nadd = (e[256] || (e[255:0] >= NN)) ? (e[255:0] - NN) : e[255:0];
        end
    endfunction

    // =========================================================================
    // 子模块 (v3.0: u_pa 已删除)
    //
    // Phase 8 (2026-10-11): 引擎内共享乘法器。本模块原有的 sm2_montmul u_mm 与
    // sm2_nmul u_nm 已删除, 连同 4 个活跃 montmul (jacaffx / jacaffx 内的 modinv /
    // pmul 内 point_add / 本模块) 与 2 个 nmul (ninv 内 / 本模块) 全部上提到本层,
    // 由 u_mm_arb (N=4) 与 u_nm_arb (N=2) 时分复用。所有子模块调用由本 FSM 顺序
    // 发起, 请求在时间上互斥, 仲裁器仅作防御。
    // =========================================================================
    reg          pm_start;
    reg  [255:0] pm_scalar, pm_x, pm_y;
    wire [255:0] pm_xo, pm_yo, pm_zo;
    wire         pm_inf, pm_done;

    // pmul 内 point_add 的 montmul 请求透传 (仲裁器路 [2])
    wire         mm_pp_req;
    wire [255:0] mm_pp_a, mm_pp_b, mm_pp_result;
    wire         mm_pp_done;

    sm2_pmul u_pm (
        .clk(clk), .rst_n(rst_n), .start(pm_start),
        .scalar(pm_scalar), .px(pm_x), .py(pm_y),
        .x_out(pm_xo), .y_out(pm_yo), .z_out(pm_zo),
        .inf_flag(pm_inf), .done(pm_done),
        .pa_mm_req(mm_pp_req), .pa_mm_a(mm_pp_a), .pa_mm_b(mm_pp_b),
        .pa_mm_result(mm_pp_result), .pa_mm_done(mm_pp_done)
    );

    reg          ni_start;
    reg  [255:0] ni_a;
    wire [255:0] ni_res;
    wire         ni_done;

    // ninv 内 nmul 的请求透传 (nm 仲裁器路 [0])
    wire         nm_ni_req;
    wire [255:0] nm_ni_a, nm_ni_b, nm_ni_result;
    wire         nm_ni_done;

    sm2_ninv u_ni (
        .clk(clk), .rst_n(rst_n), .start(ni_start),
        .a(ni_a), .result(ni_res), .done(ni_done),
        .nm_req(nm_ni_req), .nm_a(nm_ni_a), .nm_b(nm_ni_b),
        .nm_result(nm_ni_result), .nm_done(nm_ni_done)
    );

    // sign 本路的 mod-n 乘请求 (nm 仲裁器路 [1])
    reg          nm_req;
    reg  [255:0] nm_a, nm_b;
    wire [255:0] nm_result;
    wire         nm_done;

    // sign 本路的 Montgomery 乘请求 (mm 仲裁器路 [3])
    reg          mm_req;
    reg  [255:0] mm_x, mm_y;
    wire [255:0] mm_result;
    wire         mm_done;

    // Jacobian -> 仿射 x (SM2 只需要 x 坐标)
    reg          jc_start;
    reg  [255:0] jc_x1, jc_z1;
    wire [255:0] jc_xo;
    wire         jc_done;

    // jacaffx 本路 (仲裁器路 [1]) 与其内部 modinv 的请求透传 (仲裁器路 [0])
    wire         mm_jc_req,  mm_iv_req;
    wire [255:0] mm_jc_a,    mm_iv_a;
    wire [255:0] mm_jc_b,    mm_iv_b;
    wire [255:0] mm_jc_result, mm_iv_result;
    wire         mm_jc_done,   mm_iv_done;

    sm2_jacaffx u_jc (
        .clk(clk), .rst_n(rst_n), .start(jc_start),
        .x_in(jc_x1), .z_in(jc_z1), .x_out(jc_xo), .done(jc_done),
        .mm_req(mm_jc_req), .mm_a(mm_jc_a), .mm_b(mm_jc_b),
        .mm_result(mm_jc_result), .mm_done(mm_jc_done),
        .iv_mm_req(mm_iv_req), .iv_mm_a(mm_iv_a), .iv_mm_b(mm_iv_b),
        .iv_mm_result(mm_iv_result), .iv_mm_done(mm_iv_done)
    );

    // =========================================================================
    // Phase 8: 共享乘法仲裁器 (v3.0: N=5 → N=4, sign.pa 路删除)
    //   mm 路序: [0]=modinv(jc 内) [1]=jacaffx [2]=pm.pa(pmul 透传) [3]=sign 本路
    //   nm 路序: [0]=ninv(内)      [1]=sign 本路
    // =========================================================================
    wire [3:0]     mm_req_bus = {mm_req, mm_pp_req, mm_jc_req, mm_iv_req};
    wire [1023:0]  mm_a_flat  = {mm_x, mm_pp_a, mm_jc_a, mm_iv_a};
    wire [1023:0]  mm_b_flat  = {mm_y, mm_pp_b, mm_jc_b, mm_iv_b};
    wire [1023:0]  mm_result_flat;
    wire [3:0]     mm_done_bus;

    assign mm_iv_result  = mm_result_flat[0*256 +: 256];
    assign mm_jc_result  = mm_result_flat[1*256 +: 256];
    assign mm_pp_result  = mm_result_flat[2*256 +: 256];
    assign mm_result     = mm_result_flat[3*256 +: 256];

    assign mm_iv_done = mm_done_bus[0];
    assign mm_jc_done = mm_done_bus[1];
    assign mm_pp_done = mm_done_bus[2];
    assign mm_done    = mm_done_bus[3];

    sm2_mm_arb #(.N(4)) u_mm_arb (
        .clk(clk), .rst_n(rst_n),
        .req(mm_req_bus),
        .a_flat(mm_a_flat), .b_flat(mm_b_flat),
        .mm_done(mm_done_bus), .result_flat(mm_result_flat),
        .busy()
    );

    wire [1:0]     nm_req_bus = {nm_req, nm_ni_req};
    wire [511:0]   nm_a_flat  = {nm_a, nm_ni_a};
    wire [511:0]   nm_b_flat  = {nm_b, nm_ni_b};
    wire [511:0]   nm_result_flat;
    wire [1:0]     nm_done_bus;

    assign nm_ni_result = nm_result_flat[0*256 +: 256];
    assign nm_result    = nm_result_flat[1*256 +: 256];
    assign nm_ni_done = nm_done_bus[0];
    assign nm_done    = nm_done_bus[1];

    sm2_nm_arb #(.N(2)) u_nm_arb (
        .clk(clk), .rst_n(rst_n),
        .req(nm_req_bus),
        .a_flat(nm_a_flat), .b_flat(nm_b_flat),
        .nm_done(nm_done_bus), .result_flat(nm_result_flat),
        .busy()
    );

    // =========================================================================
    // 状态 (v3.0: 验签状态已删除)
    // =========================================================================
    localparam [4:0] S_IDLE    = 5'd0;
    localparam [4:0] S_TOM     = 5'd1;   // 发起 Montgomery 调用 (源由 mm_op 选)
    localparam [4:0] S_TOW     = 5'd2;   // 等 Montgomery done
    localparam [4:0] S_PM1     = 5'd3;   // 发起点乘 [k]G
    localparam [4:0] S_PM1W    = 5'd4;
    localparam [4:0] S_RCALC   = 5'd10;  // r = (x1 + e) mod n , 同时发起 k^{-1}
    localparam [4:0] S_AFTERNI = 5'd11;  // mod n 模逆完成 -> 路由
    localparam [4:0] S_NMREQ   = 5'd12;  // 发起 mod n 模乘
    localparam [4:0] S_NMW     = 5'd13;  // 等 mod n 模乘 done
    localparam [4:0] S_FIN     = 5'd15;
    localparam [4:0] S_JC      = 5'd16;  // 发起点 (Jacobian -> 仿射 x) 调用
    localparam [4:0] S_JCW     = 5'd17;  // 等仿射转换 done

    // Montgomery 调用类型 (v3.0: MM_QX/MM_QY/MM_X3 已删除)
    localparam [3:0] MM_GX = 4'd0;   // to_mont(Gx)      -> gx_m
    localparam [3:0] MM_GY = 4'd1;   // to_mont(Gy)      -> gy_m
    localparam [3:0] MM_X1 = 4'd4;   // from_mont([k]G.X)-> x1_plain

    // mod n 操作类型 (v3.0: NM_SI/NM_U1/NM_U2 已删除)
    localparam [3:0] NM_KI = 4'd0;   // ninv(k_r)  -> ki_r
    localparam [3:0] NM_DR = 4'd2;   // d_r * r_val            -> t1_r
    localparam [3:0] NM_KT = 4'd3;   // ki_r * tval_r          -> s_val

    reg [4:0] st;
    reg [3:0] mm_op;
    reg [3:0] nm_op;

    // ---- 输入锁存 (运算跨约 3x10^5 拍, 端口值必须先锁存) ----
    reg [255:0] d_r, e_r, k_r;

    // ---- 中间量 (v3.0: qx_m/qy_m/x3_plain/u1_r/u2_r/pad2_*/pad3_*/chk_sum 已删除) ----
    reg [255:0] gx_m, gy_m;               // Montgomery 形式基点
    reg [255:0] x1_plain;                 // from_mont 结果, plain
    reg [255:0] r_val, s_val;             // 签名 r / s
    reg [255:0] ki_r;                     // k^{-1} mod n
    reg [255:0] t1_r;                     // d*r mod n (tval_r 的中间量)
    reg [255:0] tval_r;                   // (e + d*r) mod n
    reg [255:0] pad1_x, pad1_y, pad1_z;   // [k]G 的 Jacobian

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            mm_op     <= 4'd0;
            nm_op     <= 4'd0;
            d_r       <= 256'd0;
            e_r       <= 256'd0;
            k_r       <= 256'd0;
            gx_m      <= 256'd0;
            gy_m      <= 256'd0;
            x1_plain  <= 256'd0;
            r_val     <= 256'd0;
            s_val     <= 256'd0;
            ki_r      <= 256'd0;
            t1_r      <= 256'd0;
            tval_r    <= 256'd0;
            pad1_x    <= 256'd0;
            pad1_y    <= 256'd0;
            pad1_z    <= 256'd0;
            r_out     <= 256'd0;
            s_out     <= 256'd0;
            err       <= 1'b0;
            done      <= 1'b0;
            pm_start  <= 1'b0;
            ni_start  <= 1'b0;
            nm_req    <= 1'b0;
            mm_req    <= 1'b0;
            jc_start  <= 1'b0;
            jc_x1     <= 256'd0;
            jc_z1     <= 256'd0;
        end else begin
            // 子模块启动脉冲每拍默认清零
            // 注: mm_req / nm_req 由 mm_done / nm_done 划界, 不能每拍清
            //     (Phase 8 共享仲裁器协议)
            pm_start  <= 1'b0;
            ni_start  <= 1'b0;
            jc_start  <= 1'b0;

            case (st)

                // =========================================================
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        d_r <= d_in;
                        e_r <= e_in;
                        k_r <= k_in;
                        if ((d_in == 256'd0) || (d_in == NN) ||
                            (k_in == 256'd0) || (k_in == NN)) begin
                            err <= 1'b1;
                            st  <= S_FIN;                 // 输入非法, 直接返回
                        end else begin
                            err    <= 1'b0;
                            r_out  <= 256'd0;
                            s_out  <= 256'd0;
                            mm_op  <= MM_GX;
                            st     <= S_TOM;
                        end
                    end
                end

                // =========================================================
                // Montgomery 调用: 发起
                // =========================================================
                S_TOM: begin
                    case (mm_op)
                        MM_GX:  begin mm_x <= GX_PLAIN;   mm_y <= R2_MOD_P;   end
                        MM_GY:  begin mm_x <= GY_PLAIN;   mm_y <= R2_MOD_P;   end
                        // MM_X1 的源是 sm2_jacaffx 的仿射输出 (M(x));
                        // 这里再乘 plain 1 做一次 from_mont 得到 plain x 参与 mod n 运算
                        MM_X1:  begin mm_x <= jc_xo;      mm_y <= 256'd1;     end  // from_mont
                        default: begin mm_x <= 256'd0;    mm_y <= 256'd0;     end
                    endcase
                    mm_req <= 1'b1;
                    st     <= S_TOW;
                end

                // =========================================================
                // Montgomery 调用: 采样 + 固定程序下一跳
                // =========================================================
                // 注意 (本项目踩过的坑): 同一 always 块里的所有非阻塞赋值都采样**边沿前**
                // 的旧值, 所以绝不能写 `mm_next <= X; st <= mm_next;`
                // (st 会拿到旧 mm_next)。下一跳一律用字面量直接赋给 st。
                S_TOW: begin
                    if (mm_done) begin
                        mm_req <= 1'b0;       // 撤 req, 防止仲裁器重复服务
                        // 固定程序: Gx -> Gy -> 开工 -> 模逆
                        case (mm_op)
                            MM_GX:  begin
                                gx_m  <= mm_result;
                                mm_op <= MM_GY;
                                st    <= S_TOM;
                            end
                            MM_GY:  begin
                                gy_m <= mm_result;
                                st   <= S_PM1;
                            end
                            MM_X1:  begin
                                x1_plain <= mm_result;
                                st       <= S_RCALC;
                            end
                            default: begin
                                st <= S_FIN;
                            end
                        endcase
                    end
                end

                // =========================================================
                // 点乘 1: [k]G
                // =========================================================
                S_PM1: begin
                    pm_scalar <= k_r;
                    pm_x      <= gx_m;
                    pm_y      <= gy_m;
                    pm_start  <= 1'b1;
                    st        <= S_PM1W;
                end

                S_PM1W: begin
                    if (pm_done) begin
                        pad1_x <= pm_xo;
                        pad1_y <= pm_yo;
                        pad1_z <= pm_zo;
                        st <= S_JC;                 // [k]G -> 取仿射 x 算 r
                    end
                end

                // =========================================================
                // Jacobian -> 仿射 x (源是 [k]G 的 Jacobian, pad1)
                // =========================================================
                S_JC: begin
                    jc_x1    <= pad1_x;
                    jc_z1    <= pad1_z;
                    jc_start <= 1'b1;
                    st       <= S_JCW;
                end

                S_JCW: begin
                    if (jc_done) begin
                        mm_op <= MM_X1;          // from_mont(jacaffx 的 M(x))
                        st    <= S_TOM;         // S_TOM 结束后在 S_TOW 里进 S_RCALC
                    end
                end

                // =========================================================
                // sign: r = (x1 + e) mod n , 同时发起 k^{-1} mod n
                // =========================================================
                S_RCALC: begin
                    r_val    <= f_nadd(x1_plain, e_r);
                    ni_a     <= k_r;
                    ni_start <= 1'b1;
                    st       <= S_AFTERNI;
                end

                // =========================================================
                // mod n 模逆完成 -> 决定第一条 mod n 乘法
                // =========================================================
                S_AFTERNI: begin
                    if (ni_done) begin
                        ki_r   <= ni_res;
                        nm_op  <= NM_DR;
                        st     <= S_NMREQ;
                    end
                end

                // =========================================================
                // mod n 模乘: 发起 -> 等待 -> 按 nm_op 决定下一跳
                // =========================================================
                S_NMREQ: begin
                    case (nm_op)
                        NM_KI: begin ni_a     <= k_r;      ni_start <= 1'b1; st <= S_AFTERNI; end
                        NM_DR: begin nm_a     <= d_r;      nm_b <= r_val;   nm_req <= 1'b1; st <= S_NMW; end
                        NM_KT: begin nm_a     <= ki_r;     nm_b <= tval_r;  nm_req <= 1'b1; st <= S_NMW; end
                        default: st <= S_FIN;
                    endcase
                end

                S_NMW: begin
                    if (nm_done) begin
                        nm_req <= 1'b0;       // 撤 req, 防止仲裁器重复服务
                        case (nm_op)
                            NM_DR: begin
                                t1_r    <= nm_result;                     // 未用, 仅占位
                                tval_r  <= f_nadd(nm_result, e_r);        // t = (d*r + e) mod n
                                nm_op   <= NM_KT;
                                st      <= S_NMREQ;
                            end
                            NM_KT: begin
                                s_val <= nm_result;                       // s = k^{-1} * t
                                r_out <= r_val;
                                s_out <= nm_result;
                                err   <= ((r_val == 256'd0) ||
                                          ((r_val + k_r) == NN) ||
                                          (nm_result == 256'd0)) ? 1'b1 : 1'b0;
                                st    <= S_FIN;
                            end
                            default: st <= S_FIN;
                        endcase
                    end
                end

                // =========================================================
                S_FIN: begin
                    done <= 1'b1;
                    st   <= S_IDLE;
                end

                default: begin
                    st <= S_IDLE;
                end
            endcase
        end
    end

endmodule
