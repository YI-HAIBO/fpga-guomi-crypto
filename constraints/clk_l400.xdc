# =============================================================================
# 时钟约束 - 主时钟 clk_l400
# 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
# 版本     : v1.0 (Phase 3 初版)
# 日期     : 2026-10-03
# 目标器件 : xcu250-figd2104-2-e (UltraScale+)
# 视角     : impl-engineer (凌约束)
#
# 说明:
#   - clk: 400 MHz 系统主时钟, 驱动全部 SM2/SM3/SM4/TRNG 引擎与调度器
#   - jitter 采用 U250 器件数据手册推荐值 (500 fs RJ + 200 fs DJ)
#   - 未做 PCIe 时钟域约束 (pcie_gt_usrclk), 该时钟随 GT 硬 IP 集成后另补
#
# 时钟频率来源:
#   Phase 1 架构与模块划分说明书_v1.md §3.2
#   Phase 1 静态可行性评估_v1.md §5
# =============================================================================

# ---- 主时钟: 400 MHz = 2.5 ns ----
create_clock -period 2.5 [get_ports clk]

# ---- 时钟波形: 50% duty cycle, 上升沿在 0ns ----
set_clock_waveform [get_clocks clk] 0.0 1.25

# ---- 时钟 jitter: U250 数据手册建议值 ----
# RJ (Random Jitter) 500 fs + DJ (Deterministic Jitter) 200 fs
set_clock_jitter [get_clocks clk] 0.700

# ---- 时钟不确定性 (margin): 20% 目标时钟周期 ----
# 综合与实现阶段用于吸收工艺偏差
set_clock_uncertainty -setup  0.500 [get_clocks clk]
set_clock_uncertainty -hold  0.300 [get_clocks clk]

# ---- 输入/输出延迟 (相对主时钟) ----
# 顶层输入信号从外部寄存器采样, 假设 30% 周期不确定; 输出到外部同样给余量
# Phase 3 smoke test 阶段无真实 IO, 这些约束作为默认余量, 硬件平台明确后覆盖
set_input_jitter  [get_clocks clk] 0.050
set_output_jitter [get_clocks clk] 0.050

# ---- 数据到时钟 / 时钟到数据 (占位) ----
# 真实数据在硬件引脚级确定后再细化到 IOBUF
set_max_delay 0.750 -from [get_ports rst_n] -to [get_clocks clk]

# ---- 保存时钟名称到属性, 供后续 TDC 复用 ----
set_property clock_group clk_l400 [get_clocks clk]
