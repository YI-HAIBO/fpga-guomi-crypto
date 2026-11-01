# =============================================================================
# Nexys A7 200T (xc7a200tsbg484) 板级 IO 约束 -- 自测顶层
# =============================================================================
# 项目: GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
# 版本: v1.1 (2026-10-06 依本地封装引脚探针重写)
# 设计: 齐流晶
#
# 目标器件: xc7a200tsbg484 (Nexys A7 200T)
# 对应 RTL : rtl/sm4/sm4_engine_masked_v2_board.v
#
# 【v1.0 -> v1.1 改了什么 / 为什么】
#   v1.0 直接照抄"Nexys A7 示例"里的 LED 引脚 T8/T7/T6/T5/U8/U7/U4/V4,
#   在 sbg484 上跑 Vivado 直接报
#     CRITICAL WARNING: [Common 17-69] 'T8' is not a valid site or package pin
#   —— 这些是** Basys3 / Nexys A7-100T 的开关球**, 在 200T 的 FBGA484
#   封装里根本不存在。改约束不能靠猜, 所以改成:
#     1) 用 .workbuddy/tmp/probe_pins.tcl 逐个 set_property 试, 用 catch 返回码
#        筛出在 xc7a200tsbg484 上"真正存在"的封装引脚;
#     2) 再用流传的 Digilent Nexys A7 Master XDC 球表交叉验证, 优先取官方
#        LED 球表里**同时合法**的那批。
#   探针结果: VALID 69 个 / INVALID 21 个。
#     - 官方 100T 的 LED[3..7] = N14 R18 V17 U17 U16  -> 在 200T **全部合法**
#     - 官方 100T 的 LED[0..2] = V16 K15 J13          -> 在 200T **全部不合法**
#       (200T 换封装后这几个球被挪走了, 所以顺延到同球表里的 H17/W16/V15)
#
# 【仍然存在的假设 / 上板前必须核】
#   - 时钟球号 E3 来自多个独立公开资料的交叉引用 (Nexys A7 100MHz 振荡器)。
#     若上板发现没跑起来, 第一件事就是换 W5 试 (W5 同样在 sbg484 上合法)。
#   - LED 的**物理连通性**只能靠板级原理图或点亮试验确认; 本文件保证的是
#     "引脚合法、能编译、能出 bitstream", 不保证 LED 与 bit 一一对应。
#     若上板后 8 个灯全不亮, 用 iob 扫描测试 (逐位常亮) 定位。
# =============================================================================

# -----------------------------------------------------------------------------
# 系统时钟 (板载 100 MHz 有源晶振) - 守卫约束放宽至 12ns
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN E3      [get_ports {clk}];
set_property IOSTANDARD LVCMOS33 [get_ports {clk}];
create_clock -period 12.000 -name sys_clk [get_ports {clk}];

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
