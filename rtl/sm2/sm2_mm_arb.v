// =============================================================================
// 模块名称 : sm2_mm_arb
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.0
// 日期     : 2026-10-11
// 视角     : rtl-designer
// 功能     : 共享 Montgomery 乘法仲裁器 — N 个请求者时分复用 1 个 sm2_montmul
//
// 背景     : sm2_sign 内 5 个活跃 sm2_montmul 实例 (sign 本路 / jacaffx / modinv /
//            2x point_add) 合计 ~43k cells, 是引擎面积主体 (sm2_sign ~152k cells)。
//            本模块把它们合并为 1 个乘法器 + 仲裁器, 每引擎省 ~33.5k cells。
//            详见 docs/Phase8_共享montmul_微规格书_v1.md
//
// 正确性前提: sm2_sign 的所有子模块调用由顶层 FSM 顺序发起, 5 路请求在时间上
//            互斥, 同一时刻最多 1 路 req。固定优先级仅作防御性设计。
//
// 协议 (请求者侧):
//   T      : 发射态置 mm_req<=1, mm_a<=X, mm_b<=Y
//   T+1    : 本仲裁器 S_IDLE 看到 req, 锁存 owner, 置 montmul.start<=1
//   T+2    : montmul 采样 start, 开始 3 phase x 8 iter (~33 拍)
//   T+35   : montmul done -> 本仲裁器向 owner 发 1 拍 mm_done 脉冲并路由 result
//            请求者在 if(mm_done) 当拍撤 mm_req 并采样 mm_result
//   满足时序: 每次乘法比"直连 montmul"多 1 拍 (仲裁器插入一级)
//
// 铁律:
//   1. mm_req 保持到 mm_done 当拍才撤 (等待态不要每拍清 req)
//   2. mm_a/mm_b 在 mm_req 有效期间必须稳定
//   3. 操作数用扁平化总线 (-g2005 禁止 memory 类型作模块端口)
// =============================================================================

`timescale 1ns / 1ps

module sm2_mm_arb #(
    parameter N = 5                 // 请求者数 (sm2_sign 内为 5)
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [N-1:0]     req,            // 位 i = 请求者 i 请求一次乘法
    input  wire [N*256-1:0] a_flat,         // 扁平化左操作数: [i*256 +: 256]
    input  wire [N*256-1:0] b_flat,         // 扁平化右操作数
    output wire [N-1:0]     mm_done,        // 1 拍完成脉冲, onehot 路由
    output wire [N*256-1:0] result_flat,    // 结果路由: 仅 owner 的切片有效
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
    // 唯一的 Montgomery 乘法器
    // =========================================================================
    reg         mm_start;
    reg  [255:0] mm_a;
    reg  [255:0] mm_b;
    wire [255:0] mm_res;
    wire        mm_dn;

    sm2_montmul u_mm (
        .clk(clk), .rst_n(rst_n), .start(mm_start),
        .a(mm_a), .b(mm_b), .result(mm_res), .done(mm_dn)
    );

    // =========================================================================
    // FSM: S_IDLE (选 owner, 发 start) -> S_RUN (等 montmul done)
    // =========================================================================
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_RUN  = 2'd1;

    reg [1:0]  st;
    reg [3:0]  owner;       // 锁存的选中者 (S_RUN 期间不变)

    // 固定优先级编码: req[0] 最高 — 从高到低覆盖, 留下最小序号
    reg [3:0] owner_next;
    integer k;
    always @(*) begin
        owner_next = 4'd0;
        for (k = N - 1; k >= 0; k = k - 1)
            if (req[k]) owner_next = k[3:0];
    end

    // 操作数 MUX (组合, 跟随 owner)
    always @(*) begin
        mm_a = 256'd0;
        mm_b = 256'd0;
        for (k = 0; k < N; k = k + 1)
            if (owner == k[3:0]) begin
                mm_a = a_arr[k];
                mm_b = b_arr[k];
            end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            owner    <= 4'd0;
            mm_start <= 1'b0;
        end else begin
            case (st)
                S_IDLE: begin
                    mm_start <= 1'b0;
                    if (req != {N{1'b0}}) begin
                        owner    <= owner_next;
                        mm_start <= 1'b1;      // 1 拍 start (下一拍 S_RUN 里清零)
                        st       <= S_RUN;
                    end
                end
                S_RUN: begin
                    mm_start <= 1'b0;
                    if (mm_dn) begin
                        st <= S_IDLE;          // done 当拍发 mm_done (组合), 下一拍重新仲裁
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // 完成脉冲: 与 montmul done 同拍, onehot 路由给 owner
    // =========================================================================
    wire [N-1:0] dn_onehot = ({{(N-1){1'b0}}, 1'b1} << owner);
    assign mm_done = (st == S_RUN) ? (dn_onehot & {N{mm_dn}}) : {N{1'b0}};

    // =========================================================================
    // 结果路由: 仅在 RUN 期间把 montmul 结果驱动到 owner 的切片
    // =========================================================================
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : groute
            assign result_flat[gi*256 +: 256] =
                ((st == S_RUN) && (owner == gi[3:0])) ? mm_res : 256'd0;
        end
    endgenerate

    assign busy = (st != S_IDLE);

endmodule
