// =============================================================================
// 模块名称 : sm3_sm2_pipe
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.1 (B2: 内部 TRNG 生成 k, 硬件拒采样闭环)
// 日期     : 2026-10-04
// 视角     : rtl-designer
// 功能     : SM3 + SM2 签名流水线
//           消息流式输入 -> GB/T 32905 填充 -> 多块 SM3 链式压缩 -> e
//           -> [可选] 内部 TRNG 生成 k + 拒采样 -> sm2_sign 标准式签名 -> (r, s)
// 接口     : byte-streaming (valid/rdy) + start/done
// 依赖     : sm3_engine v3.0, sm2_sign v2.2, trng_sm3 v2.0 (USE_INTERNAL_TRNG=1 时)
// 时序     : SM3 = 244 cyc/block, SM2 = ~120k cyc, TRNG k 生成 ~400 cyc
//           单笔签名总时延 ≈ ceil(msg_len+9, 64)/64 * 244 + 400*(1+retry) + 120000 cycles
// 参考     : docs/Phase0_5_4_SM3_SM2_签名流水线_微规格书_v1.md
//           .workbuddy/tmp/sm3_sm2_ref.py
// 合规     : GB/T 32905-2016 (填充) + GB/T 32918.2-2016 (标准式)
// =============================================================================

`timescale 1ns / 1ps

module sm3_sm2_pipe #(
    parameter K_MAX_RETRY       = 4,  // k 拒绝采样上限 (仅 USE_INTERNAL_TRNG=1 时有效)
    parameter USE_INTERNAL_TRNG = 0   // 1: 内部 TRNG 生成 k, 0: k 由外部提供 (B1 兼容)
) (
    input  wire         clk,
    input  wire         rst_n,

    // 命令接口 (start 拉高 1 拍, 其余参数须在 start 前一拍稳定)
    input  wire         start,
    input  wire [31:0]  msg_len,     // 消息字节数, 0..2^24-1
    input  wire [255:0] d_in,        // 私钥 d, 1 <= d < n
    input  wire [255:0] k_in,        // 随机数 k, 1 <= k < n (USE_INTERNAL_TRNG=0 时使用)

    // 消息字节流 (valid/rdy 握手)
    input  wire [7:0]   msg_data,
    input  wire         msg_vld,
    output wire         msg_rdy,

    // 结果输出
    output wire [255:0] e_out,        // SM3 最终哈希 e (即 chain_state)
    output reg  [255:0] r_out,
    output reg  [255:0] s_out,
    output reg          sig_ok,
    output reg  [7:0]   err,         // bit 0: k_in 越界; bit 1: sm2_sign err; bit 2: k 拒采样耗尽
    output reg          done
);

    // =========================================================================
    // 常量
    // =========================================================================
    localparam [255:0] NN = 256'hfffffffeffffffffffffffffffffffff7203df6b21c6052b53bbf40939d54123;
    localparam [255:0] IV = 256'h7380166f4914b2b9172442d7da8a0600a96f30bc163138aae38dee4db0fb0e4e;

    // =========================================================================
    // FSM (4-bit 以容纳 B2 新增 k 生成状态)
    // =========================================================================
    localparam [3:0] S_IDLE        = 4'd0;
    localparam [3:0] S_RECV_BYTE   = 4'd1;  // 接收 msg 字节
    localparam [3:0] S_HASH_RECV   = 4'd2;  // 等待 sm3_engine 完成 (来自 S_RECV_BYTE)
    localparam [3:0] S_PAD_BYTE    = 4'd3;  // 写入填充字节
    localparam [3:0] S_HASH_PAD    = 4'd4;  // 等待 sm3_engine 完成 (来自 S_PAD_BYTE)
    localparam [3:0] S_SIGN        = 4'd5;  // 触发 sm2_sign
    localparam [3:0] S_SIGN_WAIT   = 4'd6;  // 等待 sm2_sign 完成
    localparam [3:0] S_OUT         = 4'd7;  // 输出 done
    // B2 新增: k 生成状态 (USE_INTERNAL_TRNG=1 时启用)
    localparam [3:0] S_KGEN_REQ_A  = 4'd8;   // 请求 TRNG 第一块 (k[255:128])
    localparam [3:0] S_KGEN_RECV_A = 4'd9;   // 接收 TRNG 第一块
    localparam [3:0] S_KGEN_REQ_B  = 4'd10;  // 请求 TRNG 第二块 (k[127:0])
    localparam [3:0] S_KGEN_RECV_B = 4'd11;  // 接收 TRNG 第二块
    localparam [3:0] S_KGEN_CHECK  = 4'd12;  // 检查 k 合法性 (1 <= k < n)

    reg [3:0] state;

    // =========================================================================
    // 消息块缓冲
    // =========================================================================
    reg  [511:0] blk_buf;        // 512-bit 块缓冲
    reg  [6:0]   byte_off;       // 当前块内的下一个字节位置, 0..63
    reg  [31:0]  bytes_recv;     // 已接收的 msg 字节数
    reg  [31:0]  msg_len_r;      // 锁存的 msg_len

    // =========================================================================
    // 填充控制
    // =========================================================================
    // pad_phase: 0=0x80, 1=k1 zeros, 2=length(8B), 3=k2 zeros
    reg  [1:0]   pad_phase;
    reg  [6:0]   pad_left;       // 当前 phase 剩余字节数
    reg  [6:0]   pad_k1;         // 长度前补零字节数
    reg  [6:0]   pad_k2;         // 长度后补零字节数 (跨块时 56, 同块时 0)
    reg  [2:0]   pad_idx;        // 长度 phase 内的字节索引 0..7

    // =========================================================================
    // SM3 引擎链式压缩
    // =========================================================================
    reg  [255:0] chain_state;
    reg          hash_start;
    wire [255:0] hash_out;
    wire         hash_done;
    wire         hash_busy;

    sm3_engine u_sm3 (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (hash_start),
        .msg_block  (blk_buf),
        .prev_state (chain_state),
        .out_state  (hash_out),
        .done       (hash_done),
        .busy       (hash_busy)
    );

    // =========================================================================
    // TRNG 实例 (B2 新增, USE_INTERNAL_TRNG=1 时启用)
    // =========================================================================
    wire         trng_req_vld;
    wire         trng_req_rdy;
    wire [7:0]   trng_req_bytes;
    wire         trng_data_vld;
    wire         trng_data_rdy;
    wire [127:0] trng_data_out;
    wire         trng_busy;
    wire         trng_done;
    wire [7:0]   trng_err_code;

    // B2: k 生成缓冲 (256-bit, 由两次 TRNG 输出拼接)
    reg  [255:0] k_buf;
    reg  [3:0]   retry_cnt;

    // TRNG 请求信号: 仅在 S_KGEN_REQ_A 或 S_KGEN_REQ_B 时有效
    assign trng_req_vld   = USE_INTERNAL_TRNG ? ((state == S_KGEN_REQ_A) || (state == S_KGEN_REQ_B)) : 1'b0;
    assign trng_req_bytes = 8'd32;   // 请求 32 字节 (TRNG v2.0 实际输出 128 bit, 忽略此值)
    assign trng_data_rdy  = 1'b1;   // 总是接受数据

    generate
    if (USE_INTERNAL_TRNG == 1) begin : gen_trng
        trng u_trng (
            .clk       (clk),
            .rst_n     (rst_n),
            .req_vld   (trng_req_vld),
            .req_rdy   (trng_req_rdy),
            .req_bytes (trng_req_bytes),
            .data_vld  (trng_data_vld),
            .data_rdy  (trng_data_rdy),
            .data_out  (trng_data_out),
            .busy      (trng_busy),
            .done      (trng_done),
            .err_code  (trng_err_code)
        );
    end else begin : gen_no_trng
        assign trng_req_rdy  = 1'b0;
        assign trng_data_vld = 1'b0;
        assign trng_data_out = 128'd0;
        assign trng_busy     = 1'b0;
        assign trng_done     = 1'b0;
        assign trng_err_code = 8'd0;
    end
    endgenerate

    // =========================================================================
    // k 选择: USE_INTERNAL_TRNG=1 用 k_buf, 否则用 k_in
    // =========================================================================
    wire [255:0] k_use     = USE_INTERNAL_TRNG ? k_buf : k_in;
    wire         k_invalid = (k_use == 256'd0) || (k_use >= NN);

    // =========================================================================
    // SM2 签名
    // =========================================================================
    reg          sign_start;
    wire [255:0] sm2_r;
    wire [255:0] sm2_s;
    wire         sm2_err;
    wire         sign_done;

    sm2_sign u_sm2 (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (sign_start),
        // v3.0 SIGN-ONLY: op/qx/qy/r/s 端口已删除
        .d_in   (d_in),
        .e_in   (chain_state),
        .k_in   (k_use),
        .r_out  (sm2_r),
        .s_out  (sm2_s),
        .err    (sm2_err),
        .done   (sign_done)
    );

    // =========================================================================
    // 位长度 = msg_len * 8 (64-bit, GB/T 32905 要求 big-endian)
    // =========================================================================
    wire [63:0] bit_length = {32'd0, msg_len_r} << 3;

    // 长度字节 (大端, index 0 = MSB, index 7 = LSB)
    wire [7:0] len_b0 = bit_length[63:56];
    wire [7:0] len_b1 = bit_length[55:48];
    wire [7:0] len_b2 = bit_length[47:40];
    wire [7:0] len_b3 = bit_length[39:32];
    wire [7:0] len_b4 = bit_length[31:24];
    wire [7:0] len_b5 = bit_length[23:16];
    wire [7:0] len_b6 = bit_length[15:8];
    wire [7:0] len_b7 = bit_length[7:0];

    // =========================================================================
    // msg_rdy (仅在 S_RECV_BYTE 状态接收)
    // =========================================================================
    assign msg_rdy = (state == S_RECV_BYTE);

    // e_out 是最终链式状态 (SM3 最终哈希)
    assign e_out = chain_state;

    // =========================================================================
    // 填充字节生成器 (组合逻辑)
    // =========================================================================
    reg [7:0] pad_byte_out;
    always @(*) begin
        if (pad_phase == 2'd0) begin
            pad_byte_out = 8'h80;                    // 起始填充字节
        end else if (pad_phase == 2'd1) begin
            pad_byte_out = 8'h00;                    // k1 zeros
        end else if (pad_phase == 2'd2) begin        // length (8 bytes big-endian)
            case (pad_idx)
                3'd0:      pad_byte_out = len_b0;
                3'd1:      pad_byte_out = len_b1;
                3'd2:      pad_byte_out = len_b2;
                3'd3:      pad_byte_out = len_b3;
                3'd4:      pad_byte_out = len_b4;
                3'd5:      pad_byte_out = len_b5;
                3'd6:      pad_byte_out = len_b6;
                default:   pad_byte_out = len_b7;
            endcase
        end else begin
            pad_byte_out = 8'h00;                    // k2 zeros (cross-block)
        end
    end

    // =========================================================================
    // 主 FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            blk_buf     <= 512'd0;
            byte_off    <= 7'd0;
            bytes_recv  <= 32'd0;
            msg_len_r   <= 32'd0;
            pad_phase   <= 2'd0;
            pad_left    <= 7'd0;
            pad_k1      <= 7'd0;
            pad_k2      <= 7'd0;
            pad_idx     <= 3'd0;
            chain_state <= IV;
            r_out       <= 256'd0;
            s_out       <= 256'd0;
            sig_ok      <= 1'b0;
            err         <= 8'd0;
            done        <= 1'b0;
            hash_start  <= 1'b0;
            sign_start  <= 1'b0;
            // B2 新增
            k_buf       <= 256'd0;
            retry_cnt   <= 4'd0;
        end else begin
            // 默认: 清除单拍脉冲
            hash_start <= 1'b0;
            sign_start <= 1'b0;
            done       <= 1'b0;

            case (state)
                // -------------------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        // 锁存命令
                        msg_len_r   <= msg_len;
                        bytes_recv  <= 32'd0;
                        chain_state <= IV;
                        blk_buf     <= 512'd0;
                        byte_off    <= 7'd0;
                        pad_phase   <= 2'd0;
                        pad_idx     <= 3'd0;
                        r_out       <= 256'd0;
                        s_out       <= 256'd0;
                        sig_ok      <= 1'b0;
                        err         <= 8'd0;

                        if (!USE_INTERNAL_TRNG) begin
                            // B1 路径: 外部 k, 立即检查合法性
                            if (k_invalid) begin
                                err   <= 8'h01;
                                done  <= 1'b1;
                                state <= S_IDLE;
                            end else if (msg_len == 32'd0) begin
                                pad_k1   <= 7'd55;
                                pad_k2   <= 7'd0;
                                pad_left <= 7'd1;
                                state    <= S_PAD_BYTE;
                            end else begin
                                state <= S_RECV_BYTE;
                            end
                        end else begin
                            // B2 路径: 内部 k, 跳过合法性检查 (稍后在 S_KGEN_CHECK 检查)
                            if (msg_len == 32'd0) begin
                                pad_k1   <= 7'd55;
                                pad_k2   <= 7'd0;
                                pad_left <= 7'd1;
                                state    <= S_PAD_BYTE;
                            end else begin
                                state <= S_RECV_BYTE;
                            end
                        end
                    end
                end

                // -------------------------------------------------------------
                S_RECV_BYTE: begin
                    if (msg_vld) begin
                        // 写入块缓冲, byte_off 递增
                        blk_buf <= {blk_buf[503:0], msg_data};
                        bytes_recv <= bytes_recv + 32'd1;
                        if (byte_off == 7'd63) begin
                            hash_start <= 1'b1;
                            byte_off   <= 7'd0;
                            state      <= S_HASH_RECV;
                        end else begin
                            byte_off <= byte_off + 7'd1;
                        end
                    end else if (bytes_recv == msg_len_r) begin
                        // 消息接收完毕, 启动填充
                        // byte_off <= 55: 同块收尾 (pad_k2 = 0)
                        // byte_off >= 56: 跨块 (pad_k2 = 56)
                        if (byte_off <= 7'd55) begin
                            pad_k1 <= 7'd55 - byte_off;
                            pad_k2 <= 7'd0;
                        end else begin
                            pad_k1 <= 7'd63 - byte_off;
                            pad_k2 <= 7'd56;
                        end
                        pad_phase <= 2'd0;
                        pad_left  <= 7'd1;
                        state     <= S_PAD_BYTE;
                    end
                end

                // -------------------------------------------------------------
                S_HASH_RECV: begin
                    if (hash_done) begin
                        $display("[DEBUG S_HASH_RECV] bytes_recv=%0d blk_buf=%h chain_state=%h", bytes_recv, blk_buf, chain_state);
                        chain_state <= hash_out;
                        blk_buf     <= 512'd0;
                        byte_off    <= 7'd0;
                        if (bytes_recv < msg_len_r) begin
                            // 还有 msg 字节要收
                            state <= S_RECV_BYTE;
                        end else begin
                            // 消息已收完且当前块正好在块边界
                            // 启动填充 (byte_off = 0, 必为同块收尾)
                            pad_k1    <= 7'd55;
                            pad_k2    <= 7'd0;
                            pad_phase <= 2'd0;
                            pad_left  <= 7'd1;
                            state     <= S_PAD_BYTE;
                        end
                    end
                end

                // -------------------------------------------------------------
                // S_PAD_BYTE phase 顺序 (GB/T 32905 严格):
                //   phase 0: 0x80 (1 字节)
                //   phase 1: k1 zeros (填满当前块到 byte_off==63, 触发 hash)
                //   phase 3: k2 zeros (跨块时, 新块开头 56 字节补零, 同块时=0)
                //   phase 2: length 8 字节大端 (最后 8 字节, 位置 56..63, 触发最终 hash)
                // 关键: length 必须在 k2 zeros 之后 (跨块时 k2 在新块开头, length 在新块末尾)
                // -------------------------------------------------------------
                S_PAD_BYTE: begin
                    if (pad_left == 7'd0) begin
                        // 当前 phase 已耗尽, 推进下一个
                        if (pad_phase == 2'd2) begin
                            // 填充完成
                            if (USE_INTERNAL_TRNG) begin
                                // B2: 进入 k 生成流程
                                retry_cnt <= 4'd0;
                                k_buf     <= 256'd0;
                                state     <= S_KGEN_REQ_A;
                            end else begin
                                state <= S_SIGN;
                            end
                        end else begin
                            case (pad_phase)
                                2'd0: begin
                                    pad_phase <= 2'd1;
                                    pad_left  <= pad_k1;
                                end
                                2'd1: begin
                                    pad_phase <= 2'd3;   // k2 zeros 先 (跨块时新块开头)
                                    pad_left  <= pad_k2; // 同块时 pad_k2=0 会立即跳过
                                end
                                2'd3: begin
                                    pad_phase <= 2'd2;   // 然后写 length 8 字节
                                    pad_left  <= 7'd8;
                                    pad_idx   <= 3'd0;
                                end
                                default: begin
                                    pad_phase <= 2'd2;
                                    pad_left  <= 7'd0;
                                end
                            endcase
                        end
                    end else begin
                        // 输出一个填充字节
                        blk_buf <= {blk_buf[503:0], pad_byte_out};
                        pad_left <= pad_left - 7'd1;
                        if (pad_phase == 2'd2) pad_idx <= pad_idx + 3'd1;
                        if (byte_off == 7'd63) begin
                            hash_start <= 1'b1;
                            byte_off   <= 7'd0;
                            state      <= S_HASH_PAD;
                        end else begin
                            byte_off <= byte_off + 7'd1;
                        end
                    end
                end

                // -------------------------------------------------------------
                S_HASH_PAD: begin
                    if (hash_done) begin
                        $display("[DEBUG S_HASH_PAD] blk_buf=%h chain_state=%h", blk_buf, chain_state);
                        chain_state <= hash_out;
                        blk_buf     <= 512'd0;
                        byte_off    <= 7'd0;
                        state       <= S_PAD_BYTE;   // 继续填充 (可能是填充的中间块)
                    end
                end

                // -------------------------------------------------------------
                // B2 新增: k 生成状态 (USE_INTERNAL_TRNG=1 时启用)
                // TRNG v2.0 每次输出 128 bit, 需两次请求拼接成 256-bit k
                // -------------------------------------------------------------
                S_KGEN_REQ_A: begin
                    // 等待 TRNG 就绪 (req_rdy=1 表示 S_IDLE), req_vld 已在组合逻辑置 1
                    if (trng_req_rdy) begin
                        state <= S_KGEN_RECV_A;
                    end
                end

                S_KGEN_RECV_A: begin
                    if (trng_data_vld) begin
                        // 高 128 位: {trng_data_out, k_buf[127:0]}
                        k_buf <= {trng_data_out, k_buf[127:0]};
                        state <= S_KGEN_REQ_B;
                    end
                end

                S_KGEN_REQ_B: begin
                    if (trng_req_rdy) begin
                        state <= S_KGEN_RECV_B;
                    end
                end

                S_KGEN_RECV_B: begin
                    if (trng_data_vld) begin
                        // 低 128 位: {k_buf[255:128], trng_data_out}
                        k_buf <= {k_buf[255:128], trng_data_out};
                        state <= S_KGEN_CHECK;
                    end
                end

                S_KGEN_CHECK: begin
                    if (k_invalid) begin
                        // k 不合法 (k=0 或 k>=n), 重试或报错
                        if (retry_cnt < K_MAX_RETRY) begin
                            retry_cnt <= retry_cnt + 4'd1;
                            state     <= S_KGEN_REQ_A;   // 重试
                        end else begin
                            err   <= 8'h04;              // k 拒采样耗尽
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end
                    end else begin
                        state <= S_SIGN;
                    end
                end

                // -------------------------------------------------------------
                S_SIGN: begin
                    sign_start <= 1'b1;
                    state      <= S_SIGN_WAIT;
                end

                // -------------------------------------------------------------
                S_SIGN_WAIT: begin
                    if (sign_done) begin
                        r_out  <= sm2_r;
                        s_out  <= sm2_s;
                        // v3.0 SIGN-ONLY: sm2_sign 无 sig_ok 输出, 成功=err==0
                        sig_ok <= (sm2_err == 1'b0);
                        if (sm2_err) err <= 8'h02;
                        state  <= S_OUT;
                    end
                end

                // -------------------------------------------------------------
                S_OUT: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                // -------------------------------------------------------------
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
