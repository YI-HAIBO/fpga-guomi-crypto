// =============================================================================
// 模块名称 : sm4_trng_subsys
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.3 (Phase 0.5.1 接入 sm4_engine_sys v4.0 参数开关)
// 日期     : 2026-10-04
// 视角     : rtl-designer (葛逻辑)
// 功能     : SM4 + TRNG 子系统集成
//           功能 A: 外部密钥单块加/解密 (直接调用 sm4_engine / sm4_engine_sys)
//           功能 B: TRNG 生成密钥 + SM4 加/解密 (调用 trng + sm4_engine / sm4_engine_sys)
//           输出同时返回 used_key (本次实际使用的密钥), 便于复算/回写
//
// 时钟     : clk_l400 (400 MHz), 单时钟域, 无 CDC (TRNG 简化版同频运行)
// 时序     : 外部密钥: ~68 cycles (baseline) / ~33 cycles (systolic v4.0)
//             TRNG 密钥: ~280 cycles (含 SM3 DRBG 116c)
//
// 参考     : phase1/接口表_v1.md §4.1 / §5.3
//           sm4_engine.v (v1.0, 6/6 PASS, baseline)
//           sm4_engine_sys.v (v4.0, 9/9 PASS, Phase 0.5.1 变体, 1.94× 加速)
//           trng_sm3.v (v2.0, 6/6 PASS, SM3 DRBG)
//
// v1.2 变更 (Phase 2.9 三引擎子系统级签核):
//   - **默认 TRNG 源固化**为 trng_sm3.v (v2.0), 即 Phase 2.9 起所有生产路径
//     使用 SM3 DRBG 版本, trng.v v1.0 仅作回归基线对照保留
//   - sm4_trng_subsys 的实例化 `trng u_trng(...)` 语义不变:
//     两个源文件模块名同为 trng 且端口一一对应, 编译时选择对应源文件即可
//   - 修复 Phase 2.4 暴露的 "前 3 字重复" 密钥模式缺陷 (T3/T4 实测确认):
//       v1.0: 0x064495ef575a6087064495ef575a6087  (4 字中 3 字重复)
//       v2.0: 0xa9e0ca8a3d4e229a60d6c38186d58f0a  (4 字互不相同)
//   - 编译命令: iverilog -g2005 -o out.vvp tb_sm4_trng_subsys.v
//                       sm4_trng_subsys.v trng_sm3.v sm4_engine.v sm3_engine.v
//   - Phase 2.9 签核: 三引擎 TB 6/6 PASS (v2.0 主路径 + v1.0 对照, 均通过)
//
// v1.3 变更 (Phase 0.5.1 变体接入, 2026-10-04):
//   - 新增模块级参数 `USE_SM4_SYS` (默认 0=baseline, 1=systolic v4.0):
//       USE_SM4_SYS = 0 → 实例化 sm4_engine     (v1.0 baseline, 64 cycles/block)
//       USE_SM4_SYS = 1 → 实例化 sm4_engine_sys (v4.0 systolic, 33 cycles/block, 1.94×)
//   - 两个 SM4 引擎端口 100% 兼容, 通过 generate-if 静态选择, 零额外开销
//   - 兼容两种编译方式:
//       a) 编译时不传参数: 默认 baseline (USE_SM4_SYS=0), 行为与 v1.2 完全一致
//       b) 编译时传参 -Psm4_trng_subsys.USE_SM4_SYS=1: 启用 systolic v4.0
//   - TRNG 侧不变 (仍为 trng_sm3 v2.0), 仅 SM4 引擎可切换
//   - Phase 0.5.1 签核: sm4_engine_sys v4.0 独立模块 9/9 仿真 PASS,
//                       Phase 3 综合 Setup +2.105 ns @ 100 MHz, LUT 7756 (5.76%)
//
// 设计说明 :
//   - start 为单周期脉冲, 触发一次完整请求
//   - gen_key=1 时, 从 TRNG 请求 16 字节 (128-bit) 作为密钥
//   - decrypt=1 时, data_in 视为密文
//   - done 为单周期脉冲, 指示结果就绪
//   - used_key 在 done 期间保持有效
//   - USE_SM4_SYS=1 时, 单块 SM4 延迟从 64→33 cycles, 端到端加速 ~1.9×
// =============================================================================

`timescale 1ns / 1ps

module sm4_trng_subsys #(
    parameter USE_SM4_SYS = 0   // 0=sm4_engine v1.0 (baseline), 1=sm4_engine_sys v4.0 (systolic)
) (
    input  wire         clk,
    input  wire         rst_n,

    // 命令接口
    input  wire         start,          // 启动一次加/解密
    input  wire         gen_key,        // 1=从 TRNG 生成密钥, 0=使用 ext_key
    input  wire         decrypt,        // 0=加密, 1=解密
    input  wire [127:0] ext_key,        // 外部密钥 (gen_key=0 时使用)
    input  wire [127:0] data_in,        // 128-bit 明文或密文

    // 结果输出
    output wire [127:0] data_out,       // 128-bit 输出
    output wire [127:0] used_key,       // 本次实际使用的密钥
    output wire         done,           // 单次完成脉冲
    output wire         busy,           // 处理中
    output wire [7:0]   err_code        // 错误码 (0x00=正常, 0x01=TRNG HT 失败)
);

    // =========================================================================
    // FSM
    // =========================================================================
    localparam S_IDLE      = 3'd0;
    localparam S_TRNG_REQ  = 3'd1;   // 向 TRNG 发请求脉冲
    localparam S_TRNG_WAIT = 3'd2;   // 等待 TRNG 数据 (data_last)
    localparam S_SM4_RUN   = 3'd3;   // 触发 SM4 (sm4_start 脉冲)
    localparam S_SM4_WAIT  = 3'd4;   // 等待 SM4 完成
    localparam S_OUTPUT    = 3'd5;   // done 脉冲输出

    reg  [2:0]  state;
    reg  [127:0] key_buf;
    reg  [127:0] data_buf;
    reg           dec_buf;
    reg  [127:0] result_buf;
    reg  [7:0]   err_buf;

    // =========================================================================
    // 子模块端口 (TRNG)
    // =========================================================================
    wire        trng_req_rdy;
    wire        trng_data_vld;
    wire [127:0] trng_data_out;
    wire        trng_data_last;
    wire        trng_busy;
    wire [7:0]  trng_err_code;

    // =========================================================================
    // 子模块端口 (SM4)
    // =========================================================================
    wire [127:0] sm4_result;
    wire        sm4_done;
    wire        sm4_busy;

    // =========================================================================
    // 连续赋值: 脉冲生成 + 数据路径
    // =========================================================================
    // TRNG 请求脉冲: 仅在 S_TRNG_REQ 有效 (1 cycle)
    wire        trng_req_vld   = (state == S_TRNG_REQ);
    // v1.1 修复: req_bytes 改为 8'd1 (单块 128-bit 交付)
    //   trng_sm3 (v2.0) 每次交付 1 个 128-bit 块, 不再按字节计数
    //   SM4 密钥 = 128-bit = 1 块, 故请求 1 块即可
    wire [7:0]  trng_req_bytes = 8'd1;
    // TRNG 数据接收: S_TRNG_WAIT 期间持续握手
    wire        trng_data_rdy  = (state == S_TRNG_WAIT);

    // SM4 启动脉冲: 仅在 S_SM4_RUN 有效 (1 cycle)
    wire        sm4_start      = (state == S_SM4_RUN);

    // =========================================================================
    // 子模块实例化
    // =========================================================================
    trng u_trng (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_vld   (trng_req_vld),
        .req_rdy   (trng_req_rdy),
        .req_bytes (trng_req_bytes),
        .data_vld  (trng_data_vld),
        .data_rdy  (trng_data_rdy),
        .data_out  (trng_data_out),
        .data_last (trng_data_last),
        .busy      (trng_busy),
        .done      (),
        .err_code  (trng_err_code)
    );

    // =========================================================================
    // SM4 引擎实例化 (v1.3: generate-if 参数开关)
    // =========================================================================
    // USE_SM4_SYS = 0 → sm4_engine     (v1.0 baseline, 64 cycles/block)
    // USE_SM4_SYS = 1 → sm4_engine_sys (v4.0 systolic, 33 cycles/block, 1.94×)
    // 两模块端口 100% 兼容, 通过 generate 静态选择, 无额外运行时开销
    generate
        if (USE_SM4_SYS == 1) begin : gen_sm4_sys
            sm4_engine_sys u_sm4 (
                .clk       (clk),
                .rst_n     (rst_n),
                .start     (sm4_start),
                .key       (key_buf),
                .plaintext (data_buf),
                .decrypt   (dec_buf),
                .ciphertext(data_buf),
                .result    (sm4_result),
                .done      (sm4_done),
                .busy      (sm4_busy)
            );
        end else begin : gen_sm4_base
            sm4_engine u_sm4 (
                .clk       (clk),
                .rst_n     (rst_n),
                .start     (sm4_start),
                .key       (key_buf),
                .plaintext (data_buf),
                .decrypt   (dec_buf),
                .ciphertext(data_buf),
                .result    (sm4_result),
                .done      (sm4_done),
                .busy      (sm4_busy)
            );
        end
    endgenerate

    // =========================================================================
    // FSM 主逻辑
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            key_buf    <= 128'd0;
            data_buf   <= 128'd0;
            dec_buf    <= 1'b0;
            result_buf <= 128'd0;
            err_buf    <= 8'h00;
        end else begin
            case (state)
                S_IDLE: begin
                    err_buf <= 8'h00;
                    if (start) begin
                        data_buf <= data_in;
                        dec_buf  <= decrypt;
                        if (gen_key) begin
                            // TRNG 密钥: 发请求
                            state <= S_TRNG_REQ;
                        end else begin
                            // 外部密钥: 直接进 SM4
                            key_buf <= ext_key;
                            state   <= S_SM4_RUN;
                        end
                    end
                end

                S_TRNG_REQ: begin
                    // trng_req_vld 已在组合逻辑断言, 等一拍让 TRNG 采样
                    state <= S_TRNG_WAIT;
                end

                S_TRNG_WAIT: begin
                    // trng_data_rdy 已在组合逻辑持续为 1
                    // 捕获 TRNG 错误码
                    if (trng_err_code != 8'h00) err_buf <= trng_err_code;
                    if (trng_data_vld && trng_data_last) begin
                        // data_out 为最后一拍数据, 作为密钥
                        key_buf <= trng_data_out;
                        state   <= S_SM4_RUN;
                    end
                end

                S_SM4_RUN: begin
                    // sm4_start 已在组合逻辑断言, 等一拍让 SM4 采样
                    state <= S_SM4_WAIT;
                end

                S_SM4_WAIT: begin
                    if (sm4_done) begin
                        result_buf <= sm4_result;
                        state      <= S_OUTPUT;
                    end
                end

                S_OUTPUT: begin
                    // done 脉冲持续 1 cycle
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // 输出逻辑
    // =========================================================================
    assign done      = (state == S_OUTPUT);
    assign busy      = (state != S_IDLE);
    assign data_out  = result_buf;
    assign used_key  = key_buf;
    assign err_code  = err_buf;

endmodule
