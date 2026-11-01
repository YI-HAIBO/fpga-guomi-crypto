# =============================================================================
# IO 约束 - PCIe / JTAG / LED / 按键 (占位模板)
# 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
# 版本     : v1.0 (Phase 3 占位)
# 日期     : 2026-10-03
# 目标器件 : xcu250-figd2104-2-e (Alveo U250)
#
# 状态: 占位模板.
#   - Alveo U250 使用 QFP-2104 封装, 引脚命名规则 (如 XN*, XM*) 需查
#     UG1066 (Alveo U250 Accelerator Card Product Guide)
#   - PCIe Gen4 x16 差分对由 GT 硬 IP 内部处理, 不在顶层用户端口
#   - 实际 IO 引脚约束需在硬件平台上位前完成
#
# 使用方式:
#   - 本文件当前不参与 Phase 3 smoke 综合 (顶层 sm4_trng_subsys 无 IO 引脚)
#   - 上真实硬件前必须补齐 IO 约束, 否则 bitstream 无法下载
# =============================================================================

# =============================================================================
# JTAG - 已由 Xilinx 硬 IP 处理, 无需用户约束
# =============================================================================
# create_cfg_pipe -type cfgp0 [get_ports {TCK, TMS, TDI, TDO, TDO2, INIT_B, DONE}]

# =============================================================================
# PCIe Gen4 x16 差分对 - 由 GT 硬 IP 处理, 用户侧约束占位
# =============================================================================
# 待硬件平台确定后补齐:
#   set_property PACKAGE_PIN "..." [get_ports pcie_smt16_refclk_p]
#   set_property IOSTANDARD LVDS  [get_ports pcie_smt16_refclk_p]
#   set_property PACKAGE_PIN "..." [get_ports pcie_smt16_refclk_n]
#   ... (16 lane PCIe differential pairs)

# =============================================================================
# 板级用户 IO (LED / 按键 / 拨码开关) - 上硬件前补齐
# =============================================================================
# 例:
#   set_property PACKAGE_PIN "P21" [get_ports led_r[0]]
#   set_property IOSTANDARD LVCMOS18 [get_ports led_r[0]]

# =============================================================================
# 复位输入 rst_n - 顶层端口, 上硬件前指定引脚
# =============================================================================
# 例:
#   set_property PACKAGE_PIN "V6" [get_ports rst_n]
#   set_property IOSTANDARD LVCMOS18 [get_ports rst_n]
#   set_property PULLUP TRUE [get_ports rst_n]

# =============================================================================
# 主时钟 clk - 顶层端口, 上硬件前指定引脚
# =============================================================================
# 例:
#   set_property PACKAGE_PIN "R8" [get_ports clk]
#   set_property IOSTANDARD LVCMOS18 [get_ports clk]
