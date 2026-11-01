// =============================================================================
// sm4_engine_masked_v2_board.v -- 板级自测顶层 (B-3/B-4 签核引擎上板验证)
// =============================================================================
// 版本: 1.0
// 日期: 2026-10-06
// 设计: 齐流晶 (FPGA Full-Flow Lead)
//
// 【目标器件】xc7a200tsbg484 (Nexys A7 200T)
//   原因: 本机 Vivado BASIC 许可 **不支持 UltraScale+** (Vivado 报
//         ERROR [Device 21-9575] "This license doesn't cover the device you
//         selected")，仅覆盖 Series7。工程原定 xcu250 (Alveo U250) 无法在本机
//         完成 P&R，故板级验证重定向到本机许可 + 物理存在的 xc7a200tsbg484。
//
// 【引脚最小化】本顶层只有 2 组外部引脚: clk + led[7:0]
//   目的: 降低上板约束出错概率。复位用**内部上电复位计数器**，不用按键；
//         测试序列**自动跑完 8 个块**，无需外部激励。
//
// 【测试内容】
//   key 固定 = 0123456789ABCDEF FEDCBA9876543210
//   pt[i]   = PT0 XOR (i * 0x0101..01)          (8 块, 每字节 +i)
//   期望密文由 gmssl 参考实现离线生成
//   (rtl/sm4/board_kat_vectors.vh, 由 .workbuddy/tmp/gen_board_vectors.py 产出)
//   锚点自检: blk0 的 pt 就是标准向量 0123456789ABCDEF...，
//             期望 ct 应为 681EDF34D206965E86B3E94F536E4246
//
// 【LED 约定】(Nexys A7 LED 为高电平点亮)
//   运行中 : LED[3:0] = 当前块号 (blk_idx)，LED[7:4] = 1111
//   结束   : 全部通过 -> LED = 8'hC3
//            任一失败 -> LED = 8'hE1
//
// 【时序】clk 100 MHz (板载 100MHz 振荡器), 引擎首块 ~33 cycles,
//         单块总周期 < 1000 cycles, 8 块 < 10^4 cycles ≈ 100 us。
// =============================================================================

`timescale 1ns / 1ps

module sm4_engine_masked_v2_board (
    input  wire       clk,    // 板载 100 MHz (PACKAGE_PIN W5, LVCMOS33)
    output wire [7:0] led     // LD0..LD7 (LVCMOS12)
);

    // KAT 向量: 期望密文 / 第 i 块明文 (gmssl 离线生成, 锚点已对齐标准向量)
    `include "board_kat_vectors.vh"

    // =========================================================================
    // 内部上电复位 (不用外部按键引脚)
    // =========================================================================
    // 注意: 全部 FSM/状态寄存器都带初值。
    //   - 仿真里寄存器上电为 X, 没有初值会让 blk_idx 停在 X, 永久走 case 的
    //     default 分支 (此坑 2026-10-06 实测踩到)。
    //   - FPGA 上 reg 初值综合为上电初值, 不影响硬件行为。
    reg [31:0]  por_cnt   = 32'd0;
    wire        rst_n;

    reg [3:0]   st        = 4'd0;
    reg [2:0]   blk_idx   = 3'd0;
    reg         start_reg = 1'b0;
    reg         fail_flag = 1'b0;
    reg [3:0]   pass_cnt  = 4'd0;
    reg [127:0] pt_cur    = 128'h00000000000000000000000000000000;

    always @(posedge clk) begin
        if (por_cnt != 32'd4095) por_cnt <= por_cnt + 32'd1;
    end
    assign rst_n = (por_cnt == 32'd4095);

    // =========================================================================
    // 测试 FSM
    // =========================================================================
    localparam [3:0] ST_LOAD  = 4'd0;   // 装载明文
    localparam [3:0] ST_START = 4'd1;   // 断言 start
    localparam [3:0] ST_PULSE = 4'd2;   // 拉低 start
    localparam [3:0] ST_WAIT  = 4'd3;   // 等 done
    localparam [3:0] ST_HOLD  = 4'd4;   // 收尾

    // 字面量宽度铁律 (2026-10-06 实测踩坑): N'h 后必须恰好 N/4 个 hex 字符。
    // 这里原本少写一个 F 变成 31 位 -> iverilog 静默按 124 bit 解析再零扩展到
    // 128 bit, key 被整体挪位成 00123456789abcdeffedcba9876543210,
    // 结果 8 块 KAT 全挂且**零 warning**, 只能逐拍打印才看出来。
    // 可用 .workbuddy/tmp/chk_widths_board.py 复核。
    localparam [127:0] KEY_CONST = 128'h0123456789ABCDEFFEDCBA9876543210;

    always @(posedge clk) begin
        if (!rst_n) begin
            st        <= ST_LOAD;
            blk_idx   <= 3'd0;
            start_reg <= 1'b0;
            fail_flag <= 1'b0;
            pass_cnt  <= 4'd0;
            pt_cur    <= 128'h00000000000000000000000000000000;
        end else begin
            case (st)
                ST_LOAD: begin
                    pt_cur <= bv_pt_of(blk_idx);
                    st     <= ST_START;
                end
                ST_START: begin
                    start_reg <= 1'b1;
                    st        <= ST_PULSE;
                end
                ST_PULSE: begin
                    start_reg <= 1'b0;
                    st        <= ST_WAIT;
                end
                ST_WAIT: begin
                    if (done) begin
                        if (result !== bv_exp_ct(blk_idx)) fail_flag <= 1'b1;
                        else                                pass_cnt <= pass_cnt + 4'd1;
                        blk_idx <= blk_idx + 3'd1;
                        st      <= (blk_idx == 3'd7) ? ST_HOLD : ST_LOAD;
                    end
                end
                ST_HOLD: ;
                default: st <= ST_LOAD;
            endcase
        end
    end

    // =========================================================================
    // LED 指示
    // =========================================================================
    reg [7:0] led_r;
    always @(posedge clk) begin
        if (!rst_n)                  led_r <= 8'h00;
        else if (st == ST_HOLD)      led_r <= fail_flag ? 8'hE1 : 8'hC3;
        // 注意: blk_idx 只有 3 位 (块号 0..7), 位选必须贴紧 [2:0]；
        // 写成 [3:0] 会越界选中 blk_idx[2] 之外的一段并触发 iverilog 告警。
        else                         led_r <= {4'hF, blk_idx[2:0]};
    end
    assign led = led_r;

    // =========================================================================
    // DUT: B-3/B-4 签核的掩码 SM4 引擎
    // =========================================================================
    wire        done;
    wire        busy;
    wire [127:0] result;

    sm4_engine_masked_v2 u_engine (
        .clk               (clk),
        .rst_n             (rst_n),

        .start             (start_reg),
        .key               (KEY_CONST),
        .plaintext         (pt_cur),
        .decrypt           (1'b0),
        .ciphertext        (pt_cur),   // 解密用, 本次为加密置零路

        .result            (result),
        .done              (done),
        .busy              (busy),

        // B-3 掩码控制: 内部表刷新通路 (外部注入关闭)
        .masked_en         (1'b1),
        .sbox_mask_ext_en  (1'b0),
        .sbox_mask_c_ext   (8'h00),
        .sbox_mask_tbl_ext (2048'h0),

        // 观测端口 (板级不需要, 悬空)
        .sbox_addr_tap     (),
        .sbox_mask_c_tap   (),
        .sbox_mask_valid   ()
    );

endmodule
