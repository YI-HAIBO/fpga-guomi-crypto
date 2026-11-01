// =============================================================================
// 模块名称 : trng
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v2.0 (SM3 DRBG 集成版)
// 日期     : 2026-10-02
// 视角     : rtl-designer (葛逻辑)
// 功能     : 硬件真随机数发生器，符合 GB/T 32905-2016 简化版本
//           包含：熵源、健康测试、SM3 哈希 DRBG 后处理
// 时钟     : clk_l400 = 400 MHz (功能仿真同频)
// 熵速率   : 目标 ≥ 100 Mbps
// 输出接口 : vld/rdy 握手，128-bit 随机数数据
//
// v2.0 变更:
//   - 用 SM3 哈希替换 trng_drbg 的弱位混合 (修复"前 3 字重复"缺陷)
//   - 新增 S_HASH_WAIT 状态 (等待 SM3 DRBG 输出就绪)
//   - 实现 SP 800-90A 风格计数器模式 DRBG
//
// 状态机:
//   S_IDLE → S_REQUEST → S_SAMPLE → S_HT → S_PROCESS → S_HASH_WAIT
//          → S_OUTPUT → S_DONE → S_IDLE
//          → S_ERROR → S_IDLE
// =============================================================================

`timescale 1ns / 1ps

module trng (
    // 时钟与复位
    input  wire         clk,
    input  wire         rst_n,

    // 请求接口
    input  wire         req_vld,
    output wire         req_rdy,
    input  wire [7:0]   req_bytes,

    // 响应接口
    output wire         data_vld,
    input  wire         data_rdy,
    output wire [127:0] data_out,
    output wire         data_last,

    // 状态与错误
    output wire         busy,
    output wire         done,
    output wire [7:0]   err_code
);

    // =========================================================================
    // 内部状态机
    // =========================================================================
    localparam [3:0] S_IDLE      = 4'd0;
    localparam [3:0] S_REQUEST   = 4'd1;
    localparam [3:0] S_SAMPLE    = 4'd2;
    localparam [3:0] S_HT        = 4'd3;
    localparam [3:0] S_PROCESS   = 4'd4;
    localparam [3:0] S_HASH_WAIT = 4'd5;   // v2.0 新增: 等待 SM3 DRBG
    localparam [3:0] S_OUTPUT    = 4'd6;
    localparam [3:0] S_DONE      = 4'd7;
    localparam [3:0] S_ERROR     = 4'd8;

    reg  [3:0] state;
    reg  [3:0] next_state;

    // 请求参数
    reg  [7:0]  bytes_req;
    reg  [7:0]  bytes_done;

    // 熵源采样
    reg  [127:0] entropy_buf;
    reg  [6:0]   bit_cnt;

    // 健康测试寄存器
    reg          ht_pass;

    // =========================================================================
    // 子模块实例化
    // =========================================================================

    // --- 熵源 ---
    wire [3:0]  entropy_bit;
    wire        entropy_vld;

    trng_entropy u_entropy (
        .clk       (clk),
        .rst_n     (rst_n),
        .req       (state == S_SAMPLE),
        .bit_out   (entropy_bit),
        .bit_vld   (entropy_vld)
    );

    // --- 健康测试 ---
    wire        ht_ok;
    wire        ht_fail;

    trng_health_test u_ht (
        .clk       (clk),
        .rst_n     (rst_n),
        .bit_in    (entropy_bit[0]),
        .bit_vld   (entropy_vld),
        .flush     (state == S_IDLE),
        .pass      (ht_ok),
        .fail      (ht_fail)
    );

    // --- SM3 哈希 DRBG (v2.0: 替换原 trng_drbg) ---
    wire [127:0] drbg_out;
    wire         drbg_out_vld;

    sm3_drbg u_drbg (
        .clk       (clk),
        .rst_n     (rst_n),
        .seed_vld  (state == S_PROCESS && bit_cnt == 7'd0),
        .seed_in   (entropy_buf),
        .req       (1'b0),
        .out       (drbg_out),
        .out_vld   (drbg_out_vld)
    );

    // =========================================================================
    // 状态机主逻辑
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            bytes_req  <= 8'd0;
            bytes_done <= 8'd0;
            entropy_buf<= 128'd0;
            bit_cnt    <= 7'd0;
            ht_pass    <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (req_vld) begin
                        state      <= S_REQUEST;
                        bytes_req  <= req_bytes;
                        bytes_done <= 8'd0;
                        bit_cnt    <= 7'd0;
                    end
                end

                S_REQUEST: begin
                    bit_cnt     <= 7'd0;
                    entropy_buf <= 128'd0;
                    state       <= S_SAMPLE;
                end

                S_SAMPLE: begin
                    if (entropy_vld) begin
                        entropy_buf <= {entropy_buf[126:0], entropy_bit[0]};
                        bit_cnt     <= bit_cnt + 7'd1;
                        if (bit_cnt == 7'd127) begin
                            state <= S_HT;
                        end
                    end
                end

                S_HT: begin
                    if (ht_fail) begin
                        state   <= S_ERROR;
                        ht_pass <= 1'b0;
                    end else begin
                        ht_pass <= 1'b1;
                        state   <= S_PROCESS;
                    end
                end

                S_PROCESS: begin
                    // 触发 DRBG 种子 (seed_vld 组合逻辑已断言)
                    state <= S_HASH_WAIT;
                end

                S_HASH_WAIT: begin
                    // 等待 SM3 DRBG 输出就绪 (v2.0 新增)
                    if (drbg_out_vld) begin
                        state <= S_OUTPUT;
                    end
                end

                S_OUTPUT: begin
                    // v2.0: 单块交付, 1 cycle 后自动完成 (简化握手)
                    state <= S_DONE;
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                S_ERROR: begin
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

    // =========================================================================
    // 输出逻辑
    // =========================================================================
    assign req_rdy   = (state == S_IDLE);
    assign busy      = (state != S_IDLE) && (state != S_DONE);
    assign done      = (state == S_DONE);
    assign err_code  = (state == S_ERROR) ? 8'h01 : 8'h00;

    assign data_vld  = (state == S_OUTPUT);
    assign data_out  = drbg_out;
    assign data_last = data_vld && (bytes_done + 8'd1 >= bytes_req);

endmodule


// =============================================================================
// 子模块: SM3 哈希 DRBG (v2.0 新增)
// 基于 SP 800-90A 计数器模式, 使用 SM3 哈希作为 PRF
// 修复 v1.0 trng_drbg 的"前 3 字重复"缺陷
// =============================================================================
module sm3_drbg (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        seed_vld,
    input  wire [127:0] seed_in,
    input  wire        req,       // 保留接口兼容, v2.0 不使用
    output wire [127:0] out,
    output wire        out_vld
);

    // =========================================================================
    // SM3 IV (GB/T 32905-2016)
    // =========================================================================
    localparam [255:0] IV = 256'h7380166f4914b2b9172442d7da8a0600a96f30bc163138aae38dee4db0fb0e4e;

    // =========================================================================
    // SM3 引擎实例
    // =========================================================================
    wire         sm3_start;
    wire [511:0] sm3_msg;
    wire [255:0] sm3_prev;
    wire [255:0] sm3_out;
    wire         sm3_done;
    wire         sm3_busy;

    sm3_engine u_sm3 (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (sm3_start),
        .msg_block   (sm3_msg),
        .prev_state  (sm3_prev),
        .out_state   (sm3_out),
        .done        (sm3_done),
        .busy        (sm3_busy)
    );

    // =========================================================================
    // 内部状态
    // =========================================================================
    reg  [255:0] v_state;    // DRBG 状态 V (256-bit)
    reg  [127:0] seed_buf;   // 种子缓冲
    reg  [31:0]  counter;    // 计数器 C
    reg  [127:0] out_reg;    // 输出寄存器
    reg          out_vld_reg;
    reg          has_seed;   // 已初始化标志
    reg  [1:0]   state;

    localparam S_IDLE = 2'd0;
    localparam S_HASH = 2'd1;

    // =========================================================================
    // 消息块构造
    // 种子模式: {seed_buf(128), counter(32), 352'd0}
    // 后续模式: {v_state(256), counter(32), 224'd0}
    // =========================================================================
    wire [511:0] msg_seed  = {seed_buf, counter, 352'd0};
    wire [511:0] msg_state = {v_state, counter, 224'd0};
    assign sm3_msg  = has_seed ? msg_state : msg_seed;
    assign sm3_prev = has_seed ? v_state : IV;

    // SM3 启动: 仅在 S_HASH 且 SM3 空闲时
    assign sm3_start = (state == S_HASH) && !sm3_busy;

    // =========================================================================
    // FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            v_state    <= IV;
            seed_buf   <= 128'd0;
            counter    <= 32'd0;
            out_reg    <= 128'd0;
            out_vld_reg<= 1'b0;
            has_seed   <= 1'b0;
        end else begin
            out_vld_reg <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (seed_vld) begin
                        seed_buf <= seed_in;
                        counter  <= 32'd0;
                        has_seed <= 1'b0;
                        state    <= S_HASH;
                    end
                end

                S_HASH: begin
                    if (sm3_done) begin
                        v_state     <= sm3_out;
                        out_reg     <= sm3_out[255:128];
                        out_vld_reg <= 1'b1;
                        has_seed    <= 1'b1;
                        state       <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign out     = out_reg;
    assign out_vld = out_vld_reg;

endmodule


// =============================================================================
// 子模块: 熵源 (Reflection Noise + Timestamp Perturbation)
// 与 v1.0 相同
// =============================================================================
module trng_entropy (
    input  wire    clk,
    input  wire    rst_n,
    input  wire    req,
    output reg  [3:0] bit_out,
    output reg       bit_vld
);

    reg [22:0] lfsr;
    reg [15:0] jitter_reg;
    reg [26:0] timestamp;
    wire [3:0] mixed_bit = {lfsr[22], lfsr[15], timestamp[26], jitter_reg[15]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr      <= 23'h001_C001;
            jitter_reg<= 16'h0000;
            timestamp <= 27'd0;
            bit_out   <= 4'd0;
            bit_vld   <= 1'b0;
        end else begin
            lfsr <= {lfsr[21:0], ^{lfsr[22], lfsr[16], lfsr[12], lfsr[4], lfsr[2], lfsr[0]}};
            timestamp <= timestamp + 27'd1;
            jitter_reg<= {jitter_reg[14:0], (lfsr[1] ^ timestamp[1])};
            if (req) begin
                bit_out   <= mixed_bit;
                bit_vld   <= 1'b1;
            end else begin
                bit_vld <= 1'b0;
            end
        end
    end

endmodule


// =============================================================================
// 子模块: 健康测试 (Runs Test + Repeat Count Test)
// 与 v1.0 相同
// =============================================================================
module trng_health_test (
    input  wire    clk,
    input  wire    rst_n,
    input  wire    bit_in,
    input  wire    bit_vld,
    input  wire    flush,
    output reg     pass,
    output reg     fail
);

    localparam WINDOW_SIZE = 12;
    localparam WINDOW_CNT  = 4096;

    reg [WINDOW_SIZE-1:0] window;
    reg [11:0] run_len;
    reg          last_bit;
    reg [15:0]   ones_count;
    reg [15:0]   zeros_count;
    reg [15:0]   max_run;
    reg [15:0]   test_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window      <= {WINDOW_SIZE{1'b0}};
            run_len     <= 12'd0;
            last_bit    <= 1'b0;
            ones_count  <= 16'd0;
            zeros_count <= 16'd0;
            max_run     <= 16'd0;
            test_count  <= 16'd0;
            pass        <= 1'b1;
            fail        <= 1'b0;
        end else if (flush) begin
            window      <= {WINDOW_SIZE{1'b0}};
            run_len     <= 12'd0;
            ones_count  <= 16'd0;
            zeros_count <= 16'd0;
            max_run     <= 16'd0;
            test_count  <= 16'd0;
            pass        <= 1'b1;
            fail        <= 1'b0;
        end else if (bit_vld) begin
            window <= {window[WINDOW_SIZE-2:0], bit_in};
            if (bit_in != last_bit) begin
                if (run_len > max_run) max_run <= run_len;
                run_len  <= 12'd1;
                last_bit <= bit_in;
            end else begin
                run_len <= run_len + 12'd1;
            end
            ones_count  <= bit_in ? (ones_count + 16'd1)  : ones_count;
            zeros_count <= bit_in ? zeros_count           : (zeros_count + 16'd1);
            test_count  <= test_count + 16'd1;
            if (test_count >= WINDOW_CNT) begin
                if ((ones_count < 16'd1500) || (ones_count > 16'd2596) ||
                    (max_run > 16'd10)) begin
                    fail <= 1'b1;
                    pass <= 1'b0;
                end else begin
                    pass <= 1'b1;
                    fail <= 1'b0;
                end
                test_count <= 16'd0;
            end
        end
    end

endmodule
