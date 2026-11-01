#=============================================================================
# nysa7_tvla.xdc  --  sm4_tvla_top 侧信道采集顶层约束
#
# 器件/板卡 : xc7a200tsbg484-2  /  Digilent Nexys A7-200T
# 目标      : TVLA / CPA 采集 (触发对齐 + UART 明文注入 + 密文回读校验)
#
# 版本: v1.0 (2026-10-25)
#   引脚全部复用自已验证的 constraints/nysa7_board_v15.xdc v1.2:
#     - clk   = E3   (板载 100 MHz 有源晶振, LVCMOS33)  [已上板验证]
#     - led   = N14 R18 V17 U17 U16 H17 W16 V15 (bank 14 LVCMOS12) [已上板验证]
#   新增:
#     - uart_rxd/uart_txd = C4 / D4  (Digilent Master.xdc, USB 转串口 FT232H)
#     - trigger           = C17      (JA 排针首脚, 接示波器外部触发通道)
#
#-----------------------------------------------------------------------------
# UART 波特率说明 (重要)
#-----------------------------------------------------------------------------
# sm4_tvla_top 的 UART 位周期 = 16*OV 个 clk。OV 直接决定波特率:
#     baud = 100e6 / (16*OV)
#     OV = 6   ->  96  clks/bit -> 1 041 667 baud (仿真用, 太快, USB 串口易失败)
#     OV = 54  -> 864  clks/bit ->   115 741 baud (推荐: 对 115200, 误差 +0.47%)
#     OV = 107 -> 1712 clks/bit ->    58 411 baud
#   上板请用 OV=54 + 115200 8N1。本文件不改变 OV, 只在 README 里说明。
#
#-----------------------------------------------------------------------------
# 时序说明 (与 board_v15 的关键差别)
#-----------------------------------------------------------------------------
#   本顶层只用 clk(100 MHz) 一个时钟域, 没有 clk50 分频, 因此:
#     1. 不需要 create_generated_clock  (避免 board_v15 v1.0 那类
#        "生成时钟静默失效 -> 4.7 万个 FF 无约束" 的坑);
#     2. 全部寄存器都挂在 clk_IBUF 传播的时钟上, check_timing 应报
#        no_clock = 0。若综合后仍出现 no_clock > 0, 说明端口名写错, 必须修。
#=============================================================================

#---- 1. 时钟: 板载 100 MHz ---------------------------------------------------
set_property PACKAGE_PIN E3      [get_ports {clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {clk}]
create_clock -name clk -period 10.000 -waveform {0.000 5.000} [get_ports {clk}]
# IBUF 与 BUFG 不在同一半侧时 place 会报 [Place 30-574], 关闭专用路由检查
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets clk_IBUF]

#---- 2. 时钟输入延迟 (FPGA 输入端参考时钟延迟) -------------------------------
set_input_delay -clock clk -max 2.000 [get_ports {clk}]
set_input_delay -clock clk -min 0.500 [get_ports {clk}]

#---- 3. UART (FT232H, bank 13 LVCMOS33) -------------------------------------
#   uart_rxd: FT232H -> FPGA  (FPGA 收明文/密钥)
#   uart_txd: FPGA -> FT232H  (FPGA 回读密文, 供主机校验 + 判断一帧结束)
set_property PACKAGE_PIN C4  [get_ports {uart_rxd}]
set_property IOSTANDARD LVCMOS33 [get_ports {uart_rxd}]
set_property PACKAGE_PIN D4  [get_ports {uart_txd}]
set_property IOSTANDARD LVCMOS33 [get_ports {uart_txd}]

# uart_rxd 是异步输入, 由 uart_rx 内部单 flops 采样 (位周期 >= 864 clks,
# 远慢于 clk, 采样裕量充足)。为避免综合器按同步路径做 IO 延迟检查而产生
# 无意义告警, 对该端口显式标注 min/max 输入延迟。
set_input_delay  -clock clk -max 4.000 [get_ports {uart_rxd}]
set_input_delay  -clock clk -min 1.000 [get_ports {uart_rxd}]
set_output_delay -clock clk -max 4.000 [get_ports {uart_txd}]
set_output_delay -clock clk -min 1.000 [get_ports {uart_txd}]

#---- 4. 示波器外部触发线 (JA 排针, bank 13 LVCMOS33) ------------------------
#   trigger 在每块明文加密开始的一拍拉高, 作为示波器 CH1 外触发源。
#   它不承担任何功能回传, 只需保证不引入关键路径。
set_property PACKAGE_PIN C17 [get_ports {trigger}]
set_property IOSTANDARD LVCMOS33 [get_ports {trigger}]
set_output_delay -clock clk -max 4.000 [get_ports {trigger}]
set_output_delay -clock clk -min 1.000 [get_ports {trigger}]

#---- 5. LED (bank 14 LVCMOS12), 复用 v15 已验证分配 -------------------------
set_property PACKAGE_PIN N14 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS12 [get_ports {led[0]}]
set_property PACKAGE_PIN R18 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS12 [get_ports {led[1]}]
set_property PACKAGE_PIN V17 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS12 [get_ports {led[2]}]
set_property PACKAGE_PIN U17 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS12 [get_ports {led[3]}]
set_property PACKAGE_PIN U16 [get_ports {led[4]}]
set_property IOSTANDARD LVCMOS12 [get_ports {led[4]}]
set_property PACKAGE_PIN H17 [get_ports {led[5]}]
set_property IOSTANDARD LVCMOS12 [get_ports {led[5]}]
set_property PACKAGE_PIN W16 [get_ports {led[6]}]
set_property IOSTANDARD LVCMOS12 [get_ports {led[6]}]
set_property PACKAGE_PIN V15 [get_ports {led[7]}]
set_property IOSTANDARD LVCMOS12 [get_ports {led[7]}]

# LED 负载极轻 (LED + 限流电阻), 输出延迟取周期的 1/4 作裕量
set_output_delay -clock clk -max 5.000 [get_ports {led[*]}]
set_output_delay -clock clk -min 1.000 [get_ports {led[*]}]

#---- 6. 不需要的路径 --------------------------------------------------------
# trigger 与 led 都是纯观测输出, 无反馈路径, 无需 false_path。
# 刻意不写任何 false_path: 本设计只有一个 clk 域, 全部路径都应受时序约束。
