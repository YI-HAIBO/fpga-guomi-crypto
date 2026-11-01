# =============================================================================
# Nexys A7 200T (xc7a200tsbg484) 板级 IO 约束 -- v3_board 专用
# =============================================================================
# 版本: v1.0 (2026-10-08)
# 设计: 齐流晶
#
# 目标器件: xc7a200tsbg484
# 对应 RTL: rtl/sm4/sm4_engine_masked_v3_board.v
#
# 【相对 nysa7_selfTest_v1.xdc 的变更】
#   新增一行:
#     set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets clk_IBUF]
#
# 【为什么要加】
#   v3_board 综合后 clk_IBUF 被放到 IOB_X1Y187, BUFG 被放到 BUFGCTRL_X0Y31,
#   两者不在芯片同半侧 (规则 rule_gclkio_bufg)。Vivado 2026.1 在 place_design
#   阶段报 [Place 30-574] Poor placement for routing between an IO pin and BUFG,
#   并以 ERROR 中止 placer, 无法出 .bit。
#   Vivado 报错信息里直接给出了官方解法:
#     < set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets clk_IBUF] >
#   该约束把专用时钟路由规则降级为 warning, 允许 IBUF->BUFG 走非专用路径,
#   代价是时钟插入延迟增加 (对板级 100 MHz 自测而言可接受)。
#
# 【与 nysa7_selfTest_v1.xdc 的差异仅在最后一行】
#   其余引脚分配、IO 标准、false_path 守卫完全一致, 便于回归比对。
# =============================================================================

# -----------------------------------------------------------------------------
# 系统时钟 (板载 100 MHz 有源晶振) - 守卫约束放宽至 12ns
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN E3      [get_ports {clk}];
set_property IOSTANDARD LVCMOS33 [get_ports {clk}];
create_clock -period 12.000 -name sys_clk [get_ports {clk}];

# 允许 clk_IBUF -> BUFG 走非专用时钟路由 (见文件头【为什么要加】段)
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets clk_IBUF]

# -----------------------------------------------------------------------------
# LED LD0..LD7 (高电平点亮, bank 14 LVCMOS12)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN N14 [get_ports {led[0]}];
set_property IOSTANDARD LVCMOS12 [get_ports {led[0]}];

set_property PACKAGE_PIN R18 [get_ports {led[1]}];
set_property IOSTANDARD LVCMOS12 [get_ports {led[1]}];

set_property PACKAGE_PIN V17 [get_ports {led[2]}];
set_property IOSTANDARD LVCMOS12 [get_ports {led[2]}];

set_property PACKAGE_PIN U17 [get_ports {led[3]}];
set_property IOSTANDARD LVCMOS12 [get_ports {led[3]}];

set_property PACKAGE_PIN U16 [get_ports {led[4]}];
set_property IOSTANDARD LVCMOS12 [get_ports {led[4]}];

set_property PACKAGE_PIN H17 [get_ports {led[5]}];
set_property IOSTANDARD LVCMOS12 [get_ports {led[5]}];

set_property PACKAGE_PIN W16 [get_ports {led[6]}];
set_property IOSTANDARD LVCMOS12 [get_ports {led[6]}];

set_property PACKAGE_PIN V15 [get_ports {led[7]}];
set_property IOSTANDARD LVCMOS12 [get_ports {led[7]}];

# -----------------------------------------------------------------------------
# 守卫约束: 抑制 LED 与未使用路径的时序检查
# -----------------------------------------------------------------------------
set_false_path -from [get_ports {led[0]}] -to [get_ports {led[7]}]
set_false_path -from [get_ports {led}] -to [get_ports {led}]

# 抑制可能影响综合的 JTAG/DP 路径
set_false_path -from [get_pins -hierarchical *jtag_*] -to [get_pins -hierarchical *jtag_*]
set_false_path -from [get_pins -hierarchical *dp_if_*] -to [get_pins -hierarchical *dp_if_*]
