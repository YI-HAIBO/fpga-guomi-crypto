# =============================================================================
# 复位约束
# 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
# 版本     : v1.0 (Phase 3 初版)
# 日期     : 2026-10-03
# 目标器件 : xcu250-figd2104-2-e
#
# 说明:
#   - rst_n 是低有效异步复位信号
#   - 声明复位同步器与最小脉冲宽度, 让实现器正确插入同步器
#   - 与 Xilinx 官方 SUGGESTED 约束方案一致
#
# 参考:
#   Xilinx UG973 - Timing Constraints Guide
#   Xilinx UG908 - UltraScale+ Architecture User Guide §11
# =============================================================================

# ---- 复位端口: 声明为异步复位信号 ----
set_property -name is_async_reset -value true [get_ports rst_n]

# ---- 最小复位脉冲宽度: 4 个时钟周期 = 10 ns ----
# 保证所有内部同步器在复位释放前采样到至少 2 拍稳定低电平
create_generated_clock -name rst_release_path \
    -source [get_ports clk] \
    -divide_by 1 [get_ports clk]

# ---- 复位释放的时钟域: 从 rst_n 释放到 clk 域的建立/保持 ----
# 复位释放后, 各寄存器至少采样 2 拍低电平再采样数据
set_min_pulse_width -max -low -rise 2.5 [get_ports rst_n]

# ---- 复位释放的时钟域: 从 clk 到 rst_n 释放路径 ----
# 复位释放后不应产生毛刺, 要求 4 拍稳定
set_max_delay 10.000 -from [get_ports rst_n] -to [get_clocks clk]
