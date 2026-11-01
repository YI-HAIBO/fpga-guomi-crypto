// =============================================================================
// 模块名称 : sm2_nm_arb
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-11
// 视角     : rtl-designer
// 功能     : 共享 mod-n 乘法仲裁器 — N 个请求者时分复用 1 个 sm2_nmul
//
// 背景     : sm2_sign 内 2 个 sm2_nmul 实例 (ninv 内部 + sign 本路), 与 sm2_mm_arb
//            完全同构, 仅内含的乘法器不同 (mod n 而非 Montgomery)。
//            详见 docs/Phase8_共享montmul_微规格书_v1.md
//
// 协议     : 与 sm2_mm_arb 相同 (nm_req 保持到 nm_done 当拍撤, a/b 期间稳定)
// 时序     : 每次乘法比"直连 nmul"多 1 拍 (仲裁器插入一级)
// =============================================================================

`timescale 1ns / 1ps

module sm2_nm_arb #(
    parameter N = 2                 // 请求者数 (sm2_sign 内为 2)
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [N-1:0]     req,
    input  wire [N*256-1:0] a_flat,
    input  wire [N*256-1:0] b_flat,
    output wire [N-1:0]     nm_done,
    output wire [N*256-1:0] result_flat,
    output wire             busy
);

    // =========================================================================
    // 解包扁平总线
    // =========================================================================
    wire [255:0] a_arr [0:N-1];
    wire [255:0] b_arr [0:N-1];
    genvar gi;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : gunpack
            assign a_arr[gi] = a_flat[gi*256 +: 256];
            assign b_arr[gi] = b_flat[gi*256 +: 256];
        end
    endgenerate

    // =========================================================================
    // 唯一的 mod-n 乘法器
    // =========================================================================
    reg         nm_start;
    reg  [255:0] nm_a;
    reg  [255:0] nm_b;
    wire [255:0] nm_res;
    wire        nm_dn;

    sm2_nmul u_nm (
        .clk(clk), .rst_n(rst_n), .start(nm_start),
        .a(nm_a), .b(nm_b), .result(nm_res), .done(nm_dn)
    );

    // =========================================================================
    // FSM
    // =========================================================================
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_RUN  = 2'd1;

    reg [1:0]  st;
    reg [3:0]  owner;

    reg [3:0] owner_next;
    integer k;
    always @(*) begin
        owner_next = 4'd0;
        for (k = N - 1; k >= 0; k = k - 1)
            if (req[k]) owner_next = k[3:0];
    end

    always @(*) begin
        nm_a = 256'd0;
        nm_b = 256'd0;
        for (k = 0; k < N; k = k + 1)
            if (owner == k[3:0]) begin
                nm_a = a_arr[k];
                nm_b = b_arr[k];
            end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            owner    <= 4'd0;
            nm_start <= 1'b0;
        end else begin
            case (st)
                S_IDLE: begin
                    nm_start <= 1'b0;
                    if (req != {N{1'b0}}) begin
                        owner    <= owner_next;
                        nm_start <= 1'b1;
                        st       <= S_RUN;
                    end
                end
                S_RUN: begin
                    nm_start <= 1'b0;
                    if (nm_dn) begin
                        st <= S_IDLE;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    wire [N-1:0] dn_onehot = ({{(N-1){1'b0}}, 1'b1} << owner);
    assign nm_done = (st == S_RUN) ? (dn_onehot & {N{nm_dn}}) : {N{1'b0}};

    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : groute
            assign result_flat[gi*256 +: 256] =
                ((st == S_RUN) && (owner == gi[3:0])) ? nm_res : 256'd0;
        end
    endgenerate

    assign busy = (st != S_IDLE);

endmodule
