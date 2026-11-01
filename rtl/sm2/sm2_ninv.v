// =============================================================================
// 模块名称 : sm2_ninv
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-02
// 视角     : rtl-designer
// 功能     : 标量域 (mod n) 模逆  result = a^{-1} mod n  (费马小定理 a^{n-2} mod n)
// 曲线     : sm2p256v1, n = 0xFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFF7203DF6B21C6052B53BBF40939D54123
// 算法     : MSB-first square-and-multiply, 全程 plain (mod n)
//              r = 1;  for i = 255 downto 0:  r = r*r mod n;  if EEXP[i] r = r*a mod n
//              EEXP = n - 2 = 0xFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFF7203DF6B21C6052B53BBF40939D54121
// 依赖     : sm2_nmul (mod n 模乘)
// 时序     : 256 次平方 + popcount(n-2) ≈ 383 次 mod n 乘 ≈ 196k cycles
//             (约 0.5 ms @400MHz)。模块级可接受; 若后续成为瓶颈可换扩展欧几里得 (~256 步)。
// 边界     : a == 0 时模逆不存在, 直接输出 0 并拉高 done (上层按错误分支处理)
// =============================================================================

`timescale 1ns / 1ps

module sm2_ninv (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,            // 启动脉冲
    input  wire [255:0] a,               // plain, 0 < a < n
    output reg  [255:0] result,          // a^{-1} mod n, plain; a==0 时为 0
    output reg          done,             // 完成脉冲 (1 cycle)

    // -- Phase 8: 共享 mod-n 乘法请求端口 (见 sm2_nm_arb) --
    output reg          nm_req,
    output reg  [255:0] nm_a,
    output reg  [255:0] nm_b,
    input  wire [255:0] nm_result,
    input  wire         nm_done
);

    // =========================================================================
    // 常数
    // =========================================================================
    localparam [255:0] NN   = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123;
    localparam [255:0] EEXP = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54121; // n - 2
    localparam [255:0] ONE  = 256'd1;

    // =========================================================================
    // Phase 8: sm2_nmul 已上提到 sm2_sign 层的 sm2_nm_arb 共享, 本模块不再例化
    // =========================================================================

    // =========================================================================
    // FSM
    // =========================================================================
    localparam [3:0] S_IDLE  = 4'd0;
    localparam [3:0] S_INIT  = 4'd1;   // r = 1, idx = 255, 排第一次乘法
    localparam [3:0] S_INITW = 4'd2;
    localparam [3:0] S_SQ    = 4'd3;   // r = r*r
    localparam [3:0] S_SQW   = 4'd4;
    localparam [3:0] S_MUL   = 4'd5;   // r = r*a (条件)
    localparam [3:0] S_MULW  = 4'd6;
    localparam [3:0] S_NEXT  = 4'd7;   // 位指针推进
    localparam [3:0] S_OUT   = 4'd8;

    reg [3:0] st;
    reg [255:0] r;
    reg [255:0] aa_buf;   // 底数 a 缓存
    reg [7:0]  idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            r         <= 256'd0;
            idx       <= 8'd0;
            nm_req    <= 1'b0;
            nm_a      <= 256'd0;
            nm_b      <= 256'd0;
            result    <= 256'd0;
            done      <= 1'b0;
        end else begin
            case (st)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        if (a == 256'd0) begin
                            result <= 256'd0;
                            done   <= 1'b1;
                            st     <= S_IDLE;
                        end else begin
                            r         <= ONE;      // r = 1
                            aa_buf    <= a;        // 底数整个运算期间不变
                            idx       <= 8'd255;
                            st        <= S_SQ;     // 直接进平方循环
                        end
                    end
                end

                // Phase 8: nm_req 保持到 nm_done, 不再需要"下一拍清 start"
                S_INITW: begin
                    if (nm_done) begin
                        nm_req <= 1'b0;
                        r      <= nm_result;       // aa = a mod n
                        st     <= S_SQ;
                    end
                end

                S_SQ: begin
                    nm_a   <= r;
                    nm_b   <= r;
                    nm_req <= 1'b1;
                    st     <= S_SQW;
                end

                S_SQW: begin
                    if (nm_done) begin
                        nm_req <= 1'b0;
                        r      <= nm_result;
                        st     <= S_MUL;
                    end
                end

                S_MUL: begin
                    if (EEXP[idx]) begin
                        nm_a   <= r;
                        nm_b   <= aa_buf;
                        nm_req <= 1'b1;
                        st     <= S_MULW;
                    end else begin
                        st <= S_NEXT;
                    end
                end

                S_MULW: begin
                    if (nm_done) begin
                        nm_req <= 1'b0;
                        r      <= nm_result;
                        st     <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    if (idx == 8'd0) begin
                        result <= r;
                        done   <= 1'b1;
                        st     <= S_IDLE;
                    end else begin
                        idx <= idx - 8'd1;
                        st  <= S_SQ;
                    end
                end

                default: begin
                    st <= S_IDLE;
                end
            endcase
        end
    end

endmodule
