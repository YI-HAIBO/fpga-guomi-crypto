# =============================================================================
# Nexys A7 200T (xc7a200tsbg484) 板级 IO 约束 -- gm_crypto_board_v15
# =============================================================================
# 版本: v1.2 (2026-10-25) - 修正 clk50 生成时钟 pin 引用 + 清理无效 false_path
# 设计: 齐流晶
#
# 目标器件: xc7a200tsbg484
# 对应 RTL : rtl/subsys/gm_crypto_board_v15.v
#
# -----------------------------------------------------------------------------
# 【v1.0 -> v1.1 变更】
# -----------------------------------------------------------------------------
# 旧版 (v1.0) 有一个致命的约束错误: clk50 生成时钟从未被真正建立。
#
#   create_generated_clock -name clk50 -source [get_ports clk] -divide_by 2 \
#       [get_pins u_clkb/ck_div_q]
#
#   在综合日志里打出两行错误:
#     [Vivado 12-508] No pins matched 'u_clkb/ck_div_q'
#     [Vivado 12-4739] create_generated_clock:No valid object(s) found
#                     for '-objects [get_pins u_clkb/ck_div_q]'
#
# 原因: u_clkb 是 BUFG_HOLD 实例, 只有 I/O 两个端口, 根本没有名为 ck_div_q
# 的 pin。真实分频寄存器是顶层的 clk50_q (gm_crypto_board_v15.v 定义), 综合
# 后 netlist 里叫 clk50_q_reg/Q。整个 DUT (pcie_front_subsys 及其所有子模块)
# 都是 clk50 域 (~47530 个 FF), 结果全部落在"无时钟约束"状态, 时序报告里
# 只有 1 个受约束端点, WNS=9.245 ns 是完全假的。
#
# 这也很可能是 impl 两次在 Phase 5.1 崩 0xC0000005 的诱因 —— 无时序代价函数
# 的 routing 在 22938 Slice (68.57%) 拥塞下极易失控。
#
# v1.1 的修法是: 用 -hierarchical 通配符定位真实分频寄存器 pin, 找不到则
# 打 WARNING 而不是静默忽略; 顺带把所有 u_dut/* 前缀的 false_path 全部
# 清理 (顶层没有 u_dut 前缀, 这些约束在旧版也全部 No pins matched 但没
# 打 WARNING 是因为 false_path 找不到 pin 只是静默失败)。
#
# -----------------------------------------------------------------------------
# 【引脚来源】(与 v1.0 相同)
#   全部引脚复用自 nysa7_v3_board_v1.xdc / nysa7_selfTest_v1.xdc 的已验证集:
#     - clk   = E3  (板载 100 MHz 有源晶振, LVCMOS33)
#     - led[0..7] = N14 R18 V17 U17 U16 H17 W16 V15 (bank 14 LVCMOS12)
#   这批引脚已在 v3_board.bit 上实编译通过, 未引入任何新球号。
#
# 【时钟约束】
#   clk100 = 100 MHz (10 ns)  -> 真实板载晶振频率
#   clk50  = clk100 / 2 (20 ns) -> create_generated_clock -divide_by 2
#   约束落在分频寄存器 clk50_q 输出, Vivado 自动沿 BUFG_HOLD 传播到 clk50。
#   50 MHz = Phase 4 wrap12 签核目标频率 (20 ns), 约束与实际工况完全一致。
#
# 【CLOCK_DEDICATED_ROUTE FALSE】
#   IBUF (clk) 与 BUFG_HOLD 不在同一半侧时 place 报 [Place 30-574],
#   需降级专用时钟路由为 warning。对板级 50 MHz 自测可接受。
#
# 【v1.1 保留的 false_path】
#   - rst_n: POR 同步释放 (posedge clk50 的 por_cnt 计到 65534 后置 1),
#     释放后恒为 1, 无有意义的时序路径。
#   - JTAG/DP: Xilinx 内部 debug port, 与设计无关。
#   其他旧版 false_path (hb_cnt/p_addr/prng/*ok/sticky -> led) 全部移除:
#     * led 是纯输出端口, 无返回路径, 无需 false_path
#     * prng / p_addr / p_data / cnt_rr / probe_step 全部在 clk50 域, 是
#       正常时序路径, 加 false_path 反而会放开 mux 链时序检查
# =============================================================================

# -----------------------------------------------------------------------------
# 1. 系统时钟 (板载 100 MHz 有源晶振)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN E3      [get_ports {clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {clk}]
create_clock -name clk -period 10.000 -waveform {0.000 5.000} [get_ports {clk}]

# IBUF -> BUFG_HOLD 允许走非专用时钟路由 (见文件头)
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets clk_IBUF]

# -----------------------------------------------------------------------------
# 2. 生成时钟 clk50 = clk / 2 (50 MHz)
# -----------------------------------------------------------------------------
# v1.1: 用 -hierarchical 通配符找分频寄存器, 兼容层次扁平化。
# 找不到则打 WARNING, 不静默 —— 否则下次又得从 47530 个无时钟约束 FF 里
# 反推这个约束为什么没生效。
# v1.2: 硬编码 pin 名。v1.1 的 if/else + puts 分支在 XDC 处理阶段
# 两个分支的 puts 都没出现在日志里 (静默失效), 导致 clk50 从未建立,
# 15312 个时钟脚全部 no_clock, WNS 只在 1 个端点上算出来 (+9.072 ns 假象)。
# 实测: 手工执行本行后 no_clock=0 / unconstrained_endpoints=0, 真实
# WNS=-0.612 ns (88 failing endpoints) 才暴露出来。
create_generated_clock -name clk50 -source [get_ports clk] -divide_by 2 \
    [get_pins clk50_q_reg/Q]

# -----------------------------------------------------------------------------
# 3. LED LD0..LD7 (bank 14 LVCMOS12)
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# 4. 守卫约束
# -----------------------------------------------------------------------------
# rst_n 是同步释放 (posedge clk50 的 por_cnt 计满后置 1, 保持恒为 1),
# 释放后不会再次翻转, 从 rst_n 扇出的路径不参与常规 setup/hold 分析。
# v1.1 修正: 旧版写 [get_pins u_dut/rst_n] 是虚构 pin (u_dut 是 DUT 实例,
# rst_n 是顶层信号, 不在 u_dut 下面), 完全静默失效。
set_false_path -from [get_pins -hierarchical -quiet *rst_n_reg/Q]

# Xilinx 内部 JTAG/DP, 与设计无关
set_false_path -from [get_pins -hierarchical -quiet *jtag_*] -to [get_pins -hierarchical -quiet *jtag_*]
set_false_path -from [get_pins -hierarchical -quiet *dp_if_*] -to [get_pins -hierarchical -quiet *dp_if_*]

# -----------------------------------------------------------------------------
# 5. LED 输出延迟 (v1.2 新增: check_timing 报 no_output_delay = 8)
#    led[7:0] 由 clk50 域寄存器直驱, 板上为 LED+限流电阻, 负载极轻。
#    取 5 ns (周期的 1/4) 作为板级走线 + LED 侧裕量, 属保守估计。
# -----------------------------------------------------------------------------
set_output_delay -clock clk50 -max 5.000 [get_ports {led[*]}]
set_output_delay -clock clk50 -min 1.000 [get_ports {led[*]}]
