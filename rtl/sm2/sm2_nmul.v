// =============================================================================
// 模块名称 : sm2_nmul
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.1  (修正 255 步漏掉 b.bit255 的缺陷, 见文件尾"修正历史")
// 日期     : 2026-10-02
// 视角     : rtl-designer
// 功能     : 标量域 (mod n) 模乘  result = a * b mod n     —— 普通整数表示 (非 Montgomery)
// 曲线     : sm2p256v1, n = 0xFFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFF7203DF6B21C6052B53BBF40939D54123
// 算法     : 256 步 shift-and-add
//              acc = 0; A = a; B = b;
//              repeat 256: if (B[0]) acc += A;  A += A (mod n);  B >>= 1;
//              因为 acc < n 且 A < n, 每步只需一次条件减 n (a+b < 2n)
// 为什么不用 Montgomery: 标量域 (mod n) 只在签名/验签里做少量乘法
//             (k^{-1} 的费马幂、u1/u2 计算), 用 256-back 循环换取
//             组合逻辑最浅 (257-bit 加法 + 条件减), 比 512-bit 组合乘法
//             时序友好得多。
// 时序     : 256 步 ≈ 512 cycles
// 修正历史 : v1.1 — v1.0 的 cnt 是 8 位且初值 255, cnt 递减到 0 即输出,
//            实际只跑了 255 步, b 的 bit255 从未被吸收 (随机向量 50% 出错)。
//            改为 9 位 cnt 初值 256, 保证 256 步完整。
// =============================================================================

`timescale 1ns / 1ps

module sm2_nmul (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,            // 启动脉冲
    input  wire [255:0] a,               // plain, < n
    input  wire [255:0] b,               // plain, < n
    output reg  [255:0] result,          // a*b mod n, plain
    output reg          done             // 完成脉冲 (1 cycle)
);

    // =========================================================================
    // 曲线阶 n
    // =========================================================================
    localparam [255:0] NN = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123;

    // =========================================================================
    // 组合模加 (mod n): x+y < 2n < 2^257, 溢出位或越界时减一次 n 即可
    // =========================================================================
    function [255:0] f_addn;
        input [255:0] x;
        input [255:0] y;
        reg [256:0] e;
        begin
            e = {1'b0, x} + {1'b0, y};
            f_addn = (e[256] || (e[255:0] >= NN)) ? (e[255:0] - NN) : e[255:0];
        end
    endfunction

    // =========================================================================
    // FSM
    // =========================================================================
    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_RUN  = 3'd1;
    localparam [2:0] S_OUT  = 3'd2;

    // cnt 必须 9 位: 初值 256, 递减到 0 表示 256 步全部做完。
    // 8 位初值 255 只能跑 255 步, 会漏掉 b 的 bit255 (v1.0 的实际缺陷)。
    reg [8:0]   cnt;
    reg [2:0]  st;
    reg [255:0] acc;
    reg [255:0] Areg;
    reg [255:0] Breg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= S_IDLE;
            acc     <= 256'd0;
            Areg    <= 256'd0;
            Breg    <= 256'd0;
            cnt     <= 8'd0;
            result  <= 256'd0;
            done    <= 1'b0;
        end else begin
            case (st)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        acc  <= 256'd0;
                        Areg <= a;
                        Breg <= b;
                        cnt  <= 9'd256;          // 256 步: bit255..bit0 全部吸收
                        st   <= S_RUN;
                    end
                end

                S_RUN: begin
                    if (cnt == 9'd0) begin
                        result <= acc;
                        st     <= S_OUT;
                    end else begin
                        // if (Breg[0]) acc += Areg;
                        if (Breg[0]) acc <= f_addn(acc, Areg);
                        // Areg = 2*Areg mod n
                        Areg <= f_addn(Areg, Areg);
                        // Breg >>= 1
                        Breg <= {1'b0, Breg[255:1]};
                        cnt  <= cnt - 9'd1;
                    end
                end

                S_OUT: begin
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
