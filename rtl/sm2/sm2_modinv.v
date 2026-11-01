// =============================================================================
// 模块名称 : sm2_modinv
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-02
// 视角     : rtl-designer
// 功能     : 模逆 a^{-1} mod p  (费马小定理: a^{p-2} mod p)
// 曲线     : sm2p256v1 (GB/T 32918-2016)
//           p = 256'hfffffffeffffffffffffffffffffffffffffffff00000000ffffffffffffffff
// 算法     : MSB-first square-and-multiply, 全程 Montgomery 域
//            r = mont(1);  for i = 255 downto 0:  r = r*r; if e[i] r = r*a
//            其中 e = p - 2 (Montgomery 形式)
// 时序     : 256 次平方 + popcount(e) 次乘法 ≈ 510 次 Montgomery 乘
// =============================================================================

`timescale 1ns / 1ps

module sm2_modinv (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,            // 启动脉冲
    input  wire [255:0] a_in,             // 输入 (普通表示, 非 Montgomery 形式)
    output reg  [255:0] result,           // 输出 a^{-1} mod p (普通表示)
    output reg          done,             // 完成脉冲 (1 cycle)

    // -- Phase 8: 共享 Montgomery 乘法请求端口 (见 sm2_mm_arb) --
    output reg          mm_req,
    output reg  [255:0] mm_a,
    output reg  [255:0] mm_b,
    input  wire [255:0] mm_result,
    input  wire         mm_done
);

    // =========================================================================
    // 曲线常数
    // =========================================================================
    localparam [255:0] R_MONT_ONE = 256'h0000000100000000000000000000000000000000ffffffff0000000000000001; // mont(1) = R mod p
    localparam [255:0] R2_MOD_P   = 256'h0000000400000002000000010000000100000002ffffffff0000000200000003; // R^2 mod p, mont 转换常数
    localparam [255:0] EEXP       = 256'hfffffffeffffffffffffffffffffffffffffffff00000000fffffffffffffffd; // p - 2 = 256'hfffffffeffffffffffffffffffffffffffffffff00000000fffffffffffffffd

    // =========================================================================
    // Phase 8: Montgomery 乘法器改为共享请求 (sm2_mm_arb), 本模块不再例化
    // =========================================================================

    // =========================================================================
    // 状态
    // =========================================================================
    // 注意: 状态值最大到 11, 必须 4-bit 存储, 否则 3-bit 字面量被截断导致状态编码冲突
    localparam [3:0] ST_IDLE    = 4'd0;
    localparam [3:0] ST_INIT    = 4'd1;   // to_mont(a_in): modmul(a_in, R^2)
    localparam [3:0] ST_INIT_W  = 4'd2;
    localparam [3:0] ST_SQ      = 4'd3;   // r = r*r
    localparam [3:0] ST_SQ_W    = 4'd4;
    localparam [3:0] ST_MUL_ISS = 4'd5;   // 条件乘
    localparam [3:0] ST_MUL_W   = 4'd6;
    localparam [3:0] ST_NEXT    = 4'd7;   // 位指针推进
    localparam [3:0] ST_FOUT_W  = 4'd8;   // 结尾: from_mont -> modmul(r, 1)
    localparam [3:0] ST_OUT     = 4'd9;
    localparam [3:0] ST_DONE    = 4'd10;

    reg [3:0] st;
    reg [255:0] r;      // Montgomery 形式
    reg [255:0] aa;     // mont(a_in)
    reg [7:0]  idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= ST_IDLE;
            r         <= 256'd0;
            aa        <= 256'd0;
            idx       <= 8'd0;
            mm_req    <= 1'b0;
            mm_a      <= 256'd0;
            mm_b      <= 256'd0;
            result    <= 256'd0;
            done      <= 1'b0;
        end else begin
            case (st)
                ST_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        r         <= R_MONT_ONE;     // mont(1)
                        idx       <= 8'd255;
                        mm_a      <= a_in;
                        mm_b      <= R2_MOD_P;       // to_mont
                        mm_req    <= 1'b1;
                        st        <= ST_INIT_W;
                    end
                end

                // Phase 8: mm_req 保持到 mm_done, 不再需要"下一拍清 start"
                ST_INIT_W: begin
                    if (mm_done) begin
                        mm_req <= 1'b0;
                        aa     <= mm_result;         // mont(a_in)
                        st     <= ST_SQ;
                    end
                end

                ST_SQ: begin
                    mm_a   <= r;
                    mm_b   <= r;
                    mm_req <= 1'b1;
                    st     <= ST_SQ_W;
                end

                ST_SQ_W: begin
                    if (mm_done) begin
                        mm_req <= 1'b0;
                        r      <= mm_result;
                        st     <= ST_MUL_ISS;
                    end
                end

                ST_MUL_ISS: begin
                    if (EEXP[idx]) begin
                        mm_a   <= r;
                        mm_b   <= aa;
                        mm_req <= 1'b1;
                        st     <= ST_MUL_W;
                    end else begin
                        st <= ST_NEXT;
                    end
                end

                ST_MUL_W: begin
                    if (mm_done) begin
                        mm_req <= 1'b0;
                        r      <= mm_result;
                        st     <= ST_NEXT;
                    end
                end

                ST_NEXT: begin
                    if (idx == 8'd0) begin
                        mm_a   <= r;
                        mm_b   <= 256'd1;            // from_mont
                        mm_req <= 1'b1;
                        st     <= ST_FOUT_W;
                    end else begin
                        idx <= idx - 8'd1;
                        st  <= ST_SQ;
                    end
                end

                ST_FOUT_W: begin
                    if (mm_done) begin
                        mm_req <= 1'b0;
                        result <= mm_result;          // plain a^{-1}
                        done   <= 1'b1;
                        st     <= ST_OUT;
                    end
                end

                ST_OUT: begin
                    done <= 1'b0;
                    st   <= ST_IDLE;
                end

                default: begin
                    st <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
