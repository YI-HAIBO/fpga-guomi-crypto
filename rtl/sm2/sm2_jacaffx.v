// =============================================================================
// 模块名称 : sm2_jacaffx
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-02
// 视角     : rtl-designer
// 功能     : Jacobian -> 仿射 x  (只输出 x, 因为 SM2 签名/验签只需要 x 坐标)
//
// 域约定 (与 sm2_montmul.v / sm2_consts.py 一致):
//   M(v) = v*R mod p ,  R = 2^256 mod p
//   montmul(a,b) = a*b*R^-1 mod p
//   to_mont(plain v)   = montmul(v, R^2)
//   from_mont(M(v))    = montmul(m, 1)
//
// 输入 / 输出:
//   (x_in, z_in) 是 Jacobian 坐标的 Montgomery 形式 (X = x*z^2, Z = z)
//   x_out 是**仿射 x 的 Montgomery 形式** M(x), 可直接与 to_mont(plain x) 比对,
//   调用方无需再做 from_mont。
//
// 推导 (关键, 写错一个 R 因子就会静默出错):
//   目标  x_out = M(x) = (X/z^2)*R = x*R
//   1) t1 = montmul(z_in, z_in) = M(z^2) = z^2*R
//   2) z2p = from_mont(t1)      = z^2             (plain)
//   3) inv = sm2_modinv(z2p)    = 1/z^2           (plain)
//      ** sm2_modinv 的契约: 输入/输出都是 plain, 内部自行 to_mont/from_mont。
//         若把 M(z^2) 直接喂进去, 得到的是 1/(z^2*R) 而非 1/z^2, 会差一个 R 因子。
//   4) w   = to_mont(inv)       = M(1/z^2) = R/z^2
//   5) x_out = montmul(x_in, w) = (X*R)*(R/z^2)*R^-1 = (X/z^2)*R = M(x)   ✓
//   经检验第 5 步结果已经就是 M(x), **不要再 from_mont**。
//
// 依赖     : sm2_montmul, sm2_modinv
// 时序     : 4 次 Montgomery 乘 + 1 次域逆。
//             Montgomery 乘 ≈ 1e3 cycles, 但 sm2_modinv 走费马 a^(p-2) ≈ 115506 cycles,
//             **整块周期由这次域逆决定**, 故本块 ≈ 1.2e5 cycles (约 1.2 ms @100MHz)。
//             (v1.0 原注释写「≈ 3e3 cycles」只数了乘法, 漏算域逆, 已订正)
// 边界     : z_in == 0 (无穷远) 时直接输出 0 并 done, 由调用方按无穷远处理
// =============================================================================

`timescale 1ns / 1ps

module sm2_jacaffx (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire [255:0] x_in,            // Jacobian X (Montgomery)
    input  wire [255:0] z_in,            // Jacobian Z (Montgomery); 0 = 无穷远
    output reg  [255:0] x_out,           // 仿射 x 的 Montgomery 形式 M(x)
    output reg          done,

    // -- Phase 8: 共享 Montgomery 乘法请求端口 --
    // 本路 (jacaffx 自己的 4 次乘)
    output reg          mm_req,
    output reg  [255:0] mm_a,
    output reg  [255:0] mm_b,
    input  wire [255:0] mm_result,
    input  wire         mm_done,
    // 透传 u_iv (sm2_modinv) 的请求, 由 sm2_sign 层的 sm2_mm_arb 服务
    output wire         iv_mm_req,
    output wire [255:0] iv_mm_a,
    output wire [255:0] iv_mm_b,
    input  wire [255:0] iv_mm_result,
    input  wire         iv_mm_done
);

    // =========================================================================
    // 常数
    // =========================================================================
    localparam [255:0] R2_MOD_P = 256'h0000000400000002000000010000000100000002ffffffff0000000200000003; // R^2 mod p

    // =========================================================================
    // 子模块
    // =========================================================================
    // Phase 8: 本模块的 sm2_montmul 已上提到 sm2_sign 层的 sm2_mm_arb 共享

    reg          iv_start;
    reg  [255:0] iv_a;
    wire [255:0] iv_res;
    wire         iv_done;
    sm2_modinv u_iv (
        .clk(clk), .rst_n(rst_n), .start(iv_start),
        .a_in(iv_a), .result(iv_res), .done(iv_done),
        // 透传 modinv 的共享乘法请求到 sm2_sign 层
        .mm_req(iv_mm_req), .mm_a(iv_mm_a), .mm_b(iv_mm_b),
        .mm_result(iv_mm_result), .mm_done(iv_mm_done)
    );

    // =========================================================================
    // 状态
    // =========================================================================
    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_Z2   = 3'd1;   // t1 = montmul(z, z)
    localparam [2:0] S_Z2W  = 3'd2;   // z2p = from_mont(t1)
    localparam [2:0] S_INV  = 3'd3;   // inv = 1/z^2
    localparam [2:0] S_INVW = 3'd4;   // w = to_mont(inv)
    localparam [2:0] S_W    = 3'd5;   // x_out = montmul(x_in, w)
    localparam [2:0] S_DONE = 3'd6;

    reg [2:0] st;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            mm_req    <= 1'b0;
            mm_a      <= 256'd0;
            mm_b      <= 256'd0;
            iv_start  <= 1'b0;
            iv_a      <= 256'd0;
            x_out     <= 256'd0;
            done      <= 1'b0;
        end else begin
            // iv_start 每拍默认清零 (mm_req 由 mm_done 划界, 不在这里清)
            iv_start  <= 1'b0;

            case (st)

                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        if (z_in == 256'd0) begin
                            x_out <= 256'd0;
                            done  <= 1'b1;
                            st    <= S_IDLE;                 // 无穷远, 跳过后续
                        end else begin
                            mm_a     <= z_in;
                            mm_b     <= z_in;
                            mm_req   <= 1'b1;
                            st       <= S_Z2;
                        end
                    end
                end

                S_Z2: begin
                    if (mm_done) begin
                        // req 保持: 同一块内只留最后一次赋值 (mm_req<=1)
                        mm_a   <= mm_result;      // t1 = M(z^2)
                        mm_b   <= 256'd1;         // from_mont -> z^2 (plain)
                        mm_req <= 1'b1;
                        st     <= S_Z2W;
                    end
                end

                S_Z2W: begin
                    if (mm_done) begin
                        mm_req <= 1'b0;
                        iv_a     <= mm_result;      // z^2 (plain)
                        iv_start <= 1'b1;
                        st       <= S_INV;
                    end
                end

                S_INV: begin
                    if (iv_done) begin
                        mm_a   <= iv_res;         // inv = 1/z^2 (plain)
                        mm_b   <= R2_MOD_P;       // to_mont -> w = M(1/z^2)
                        mm_req <= 1'b1;
                        st     <= S_INVW;
                    end
                end

                S_INVW: begin
                    if (mm_done) begin
                        // req 保持: 换 a/b 继续下一次乘
                        mm_a   <= x_in;
                        mm_b   <= mm_result;      // w
                        mm_req <= 1'b1;
                        st     <= S_W;
                    end
                end

                // 结果已是 M(x) (见文件头推导第 5 步), 不再 from_mont
                S_W: begin
                    if (mm_done) begin
                        mm_req <= 1'b0;
                        x_out <= mm_result;
                        done  <= 1'b1;
                        st    <= S_IDLE;
                    end
                end

                default: begin
                    st <= S_IDLE;
                end
            endcase
        end
    end

endmodule
