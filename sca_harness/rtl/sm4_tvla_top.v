// =============================================================================
// sm4_tvla_top.v -- SM4 侧信道采集顶层 (Nexys A7 200T / xc7a200tsbg484-2)
// =============================================================================
// 用途: 把 SM4 引擎(掩码版或未掩码版)暴露成可用示波器/逻辑分析仪采集功耗的靶标。
//   - 主机经 USB-UART 送 16 字节明文, FPGA 跑一次加密, 在加密起点发 1 周期
//     trigger(Pmod JA1), 可选回读 16 字节密文(自校验/ pacing)。
//   - 示波器以 trigger 上升沿对齐, 采集整段加密的功耗轨迹。
//
// 协议 (主机->FPGA):
//   0xA5 <pt0..pt15>   加密一次; (echo 开时) 回 16 字节密文
//   0xA6 <key0..15>    装载新密钥(默认 0123...3210)
//   0xE0 / 0xE1        关闭/打开密文回读(echo)。默认开(请求-应答, 最稳)。
//   命令字节仅在 IDLE 态解释; 进入收明文/密钥态后 16 字节按原样收(免转义)。
//
// 引脚 (Nexys A7 官方 Master.xdc):
//   clk=E3(100MHz)  uart_txd=D4  uart_rxd=C4  trigger=JA1=C17  led=LD0..7
//
// 构建 USE_MASKED=1 -> sm4_engine_masked_v3 (被测掩码引擎)
//      USE_MASKED=0 -> sm4_engine           (未掩码正对照)
// 分别出两个 bit, TVLA/CPA 需两者对照(能攻破未掩码 / 攻不破掩码)。
//
// 编码: Verilog-2005 (iverilog -g2005 与 Vivado 2026.1 兼容)
// =============================================================================
`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// UART 接收 (16x 过采样, 每比特 OV 个 clk; OV=6 -> bit=96 clk -> ~1.04 Mbaud)
// -----------------------------------------------------------------------------
module uart_rx #(parameter OV = 6) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid
);
    localparam [15:0] BIT = 16 * OV;      // 每 bit 的 clk 数

    reg        rx_d   = 1'b1;
    reg        active = 1'b0;
    reg [15:0] bcnt   = 16'd0;            // 当前 bit 内的 clk 计数 0..BIT-1
    reg [4:0]  bitno  = 5'd0;             // 0=起始位, 1..8=数据位0..7, 9=停止位
    reg [7:0]  shreg  = 8'd0;

    // 起始沿一检测到就把采样栅格对齐到该帧: 先走半位到起始位中心,
    // 之后每个 BIT 一个采样点 = 各数据位中心。不再依赖自由运行的 ovtick。
    always @(posedge clk) begin
        if (!rst_n) begin
            rx_d <= 1'b1; active <= 1'b0; bcnt <= 16'd0; bitno <= 5'd0;
            shreg <= 8'd0; valid <= 1'b0; data <= 8'd0;
        end else begin
            rx_d  <= rx;
            valid <= 1'b0;
            if (!active) begin
                if (rx_d && !rx) begin                // 起始沿
                    active <= 1'b1;
                    bcnt   <= BIT/2 - 16'd1;          // 半位后到起始位中心
                    bitno  <= 5'd0;
                end
            end else if (bcnt == BIT - 16'd1) begin  // bit 中心采样点
                bcnt  <= 16'd0;
                if (bitno == 5'd0) begin
                    bitno <= 5'd1;                    // 起始位结束, 进入数据位0
                end else if (bitno <= 5'd8) begin
                    shreg <= {rx, shreg[7:1]};        // LSB 先发 -> 右移装入
                    bitno <= bitno + 5'd1;
                end else begin                        // bitno==9 停止位结束
                    valid  <= 1'b1;
                    data   <= shreg;
                    active <= 1'b0;
                end
            end else bcnt <= bcnt + 16'd1;
        end
    end
endmodule

// -----------------------------------------------------------------------------
// UART 发送 (每比特 16*OV 个 clk)
// -----------------------------------------------------------------------------
module uart_tx #(parameter OV = 6) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       start,
    output reg        tx,
    output wire       busy
);
    localparam [15:0] BIT = 16 * OV;
    reg        active = 1'b0;
    reg [15:0] bcnt   = 16'd0;      // 当前 bit 内的 clk 计数
    reg [4:0]  bitno  = 5'd0;       // 0=起始位, 1..8=数据位0..7, 9=停止位
    reg [7:0]  shreg  = 8'd0;
    assign busy = active;

    // 帧定长: start 起 bcmt 清零, 每帧恰好 10 个 bit = 10*BIT 个 clk,
    // busy 精确覆盖整个帧。计数器不跨帧残留, 避免停止位被下一帧截短。
    always @(posedge clk) begin
        if (!rst_n) begin
            active <= 1'b0; tx <= 1'b1; bcnt <= 16'd0; bitno <= 5'd0; shreg <= 8'd0;
        end else if (!active) begin
            tx   <= 1'b1;
            bcnt <= 16'd0;
            if (start) begin
                shreg  <= data;
                active <= 1'b1;
                tx     <= 1'b0;      // 起始位低电平, 占满一个 bit
                bitno  <= 5'd0;
            end
        end else if (bcnt == BIT - 16'd1) begin
            bcnt <= 16'd0;
            if (bitno <= 5'd7) begin                     // 送数据位 bitno
                tx    <= shreg[0];
                shreg <= {1'b0, shreg[7:1]};
                bitno <= bitno + 5'd1;
            end else if (bitno == 5'd8) begin            // 停止位高电平
                tx    <= 1'b1;
                bitno <= 5'd9;
            end else begin                               // bitno==9 帧结束
                active <= 1'b0;
                tx     <= 1'b1;
            end
        end else bcnt <= bcnt + 16'd1;
    end
endmodule

// -----------------------------------------------------------------------------
// 采集顶层
// -----------------------------------------------------------------------------
module sm4_tvla_top #(
    parameter USE_MASKED = 1,   // 1=掩码引擎(被测), 0=未掩码(正对照)
    parameter OV        = 6     // UART 过采样 (bit=16*OV clk)
) (
    input  wire       clk,
    input  wire       uart_rxd,
    output wire       uart_txd,
    output wire       trigger,
    output wire [7:0] led
);

    // ---- 内部上电复位 ----
    reg [11:0] por_cnt = 12'd0;
    wire       rst_n;
    always @(posedge clk) if (por_cnt != 12'hFFF) por_cnt <= por_cnt + 12'd1;
    assign rst_n = (por_cnt == 12'hFFF);

    // ---- UART ----
    wire [7:0] rx_data;
    wire       rx_valid;
    uart_rx #(.OV(OV)) u_rx (.clk(clk), .rst_n(rst_n), .rx(uart_rxd),
                             .data(rx_data), .valid(rx_valid));
    reg  [7:0] tx_data;
    reg        tx_start;
    wire       tx_busy;
    uart_tx #(.OV(OV)) u_tx (.clk(clk), .rst_n(rst_n), .data(tx_data),
                             .start(tx_start), .tx(uart_txd), .busy(tx_busy));

    // ---- 密钥/明文/回读开关 ----
    reg [127:0] key_reg = 128'h0123456789ABCDEFFEDCBA9876543210;
    reg [127:0] pt_reg  = 128'h0;
    reg         echo_en = 1'b1;

    // ---- 引擎 ----
    reg         eng_start;
    wire [127:0] eng_result;
    wire        eng_done;
    wire        eng_busy;

    generate
        if (USE_MASKED) begin : g_masked
            sm4_engine_masked_v3 u_eng (
                .clk(clk), .rst_n(rst_n),
                .start(eng_start), .key(key_reg), .plaintext(pt_reg),
                .decrypt(1'b0), .ciphertext(128'h0),
                .result(eng_result), .done(eng_done), .busy(eng_busy),
                .masked_en(1'b1), .sbox_mask_ext_en(1'b0),
                .sbox_mask_c_ext(8'h00), .sbox_mask_tbl_ext(2048'h0),
                .sbox_addr_tap(), .sbox_mask_c_tap(),
                .sbox_mask_valid(), .sbox_tbl_valid()
            );
        end else begin : g_unmasked
            sm4_engine u_eng (
                .clk(clk), .rst_n(rst_n),
                .start(eng_start), .key(key_reg), .plaintext(pt_reg),
                .decrypt(1'b0), .ciphertext(128'h0),
                .result(eng_result), .done(eng_done), .busy(eng_busy)
            );
        end
    endgenerate

    assign trigger = eng_start;   // 1 周期, 与引擎 start 对齐 -> 示波器触发点

    // ---- 协议 FSM (收 UART 字节) ----
    localparam [1:0] P_IDLE = 2'd0, P_PT = 2'd1, P_KEY = 2'd2;
    reg [1:0] pst = P_IDLE;
    reg [3:0] pidx = 4'd0;
    reg       pt_pending = 1'b0;   // 有一块明文待引擎处理
    reg       err_ovf = 1'b0;      // 溢出/失步标志(点亮 LED7)

    // 收明文时按大端(pt[0] 为最高字节)拼装
    always @(posedge clk) begin
        if (!rst_n) begin
            pst <= P_IDLE; pidx <= 4'd0; pt_pending <= 1'b0;
            pt_reg <= 128'h0; key_reg <= key_reg; echo_en <= 1'b1; err_ovf <= 1'b0;
        end else begin
            case (pst)
                P_IDLE: begin
                    if (rx_valid) begin
                        case (rx_data)
                            8'hA5: begin
                                if (pt_pending) err_ovf <= 1'b1;  // 上一块未取走
                                pidx <= 4'd0; pst <= P_PT;
                            end
                            8'hA6: begin pidx <= 4'd0; pst <= P_KEY; end
                            8'hE0: echo_en <= 1'b0;
                            8'hE1: echo_en <= 1'b1;
                            default: ;
                        endcase
                    end
                end
                P_PT: begin
                    if (rx_valid) begin
                        // 移位拼装: 首字节落到最高位(大端), 与人手写 hex 一致
                        pt_reg <= {pt_reg[119:0], rx_data};
                        if (pidx == 4'd15) begin
                            pst <= P_IDLE; pt_pending <= 1'b1;
                        end else begin
                            pidx <= pidx + 4'd1;
                        end
                    end
                end
                P_KEY: begin
                    if (rx_valid) begin
                        key_reg <= {key_reg[119:0], rx_data};
                        if (pidx == 4'd15) pst <= P_IDLE;
                        else               pidx <= pidx + 4'd1;
                    end
                end
                default: pst <= P_IDLE;
            endcase
        end
    end

    // ---- 引擎驱动 + 密文回读 FSM ----
    localparam [1:0] E_IDLE = 2'd0, E_RUN = 2'd2, E_TX = 2'd3;
    reg [1:0]  est = E_IDLE;
    reg [127:0] shift_reg = 128'h0;
    reg [3:0]  tx_cnt = 4'd0;
    // tx 子相位: 0=送一个字节, 1=等 busy 升起(吸收 registered busy 的 1 周期滞后),
    //            2=等 busy 落下(字节发完), 3=空闲保护(等 1 位宽空高, 保证接收端
    //            看到完整的停止位后再来下一个起始位, 否则连续字节会错位丢字)。
    reg [1:0]  tx_phase = 2'd0;
    reg [15:0] idle_cnt = 16'd0;
    localparam [15:0] IDLE_GAP = 16 * OV;    // 1 个 bit 宽的空闲保护

    always @(posedge clk) begin
        if (!rst_n) begin
            est <= E_IDLE; eng_start <= 1'b0; shift_reg <= 128'h0;
            tx_cnt <= 4'd0; tx_phase <= 2'd0; idle_cnt <= 16'd0;
            tx_data <= 8'h0; tx_start <= 1'b0;
        end else begin
            tx_start <= 1'b0;   // 默认
            case (est)
                E_IDLE: begin
                    eng_start <= 1'b0;
                    if (pt_pending && !eng_busy) begin
                        eng_start  <= 1'b1;   // 1 周期 start(=trigger)
                        pt_pending <= 1'b0;
                        est        <= E_RUN;
                    end
                end
                E_RUN: begin
                    eng_start <= 1'b0;
                    if (eng_done) begin
                        if (echo_en) begin
                            shift_reg <= eng_result;
                            tx_cnt    <= 4'd0;
                            tx_phase  <= 2'd0;
                            est       <= E_TX;
                        end else begin
                            est <= E_IDLE;
                        end
                    end
                end
                E_TX: begin
                    case (tx_phase)
                        2'd0: if (!tx_busy) begin
                            tx_data    <= shift_reg[127:120];   // 先发最高字节(与接收一致)
                            tx_start   <= 1'b1;
                            shift_reg  <= {shift_reg[119:0], 8'h00};
                            tx_phase   <= 2'd1;
                        end
                        2'd1: if (tx_busy) tx_phase <= 2'd2;
                        2'd2: if (!tx_busy) begin
                            tx_phase  <= 2'd3;      // 帧发完 -> 空闲保护
                            idle_cnt  <= 16'd0;
                            if (tx_cnt == 4'd15) begin est <= E_IDLE; tx_phase <= 2'd0; end
                            else                begin tx_cnt <= tx_cnt + 4'd1; end
                        end
                        2'd3: if (idle_cnt == IDLE_GAP - 16'd1) tx_phase <= 2'd0;
                              else idle_cnt <= idle_cnt + 16'd1;
                        default: tx_phase <= 2'd0;
                    endcase
                end
                default: est <= E_IDLE;
            endcase
        end
    end

    // ---- 心跳 + LED 状态 ----
    reg [23:0] hb = 24'd0;
    always @(posedge clk) begin
        if (!rst_n) hb <= 24'd0; else hb <= hb + 24'd1;
    end

    reg [7:0] led_r;
    always @(posedge clk) begin
        if (!rst_n) led_r <= 8'h00;
        else led_r <= {err_ovf, eng_busy, echo_en, pt_pending, est[1:0], hb[21:20]};
    end
    assign led = led_r;

endmodule
