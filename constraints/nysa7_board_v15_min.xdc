# nysa7_board_v15_min.xdc -- minimal synth-safe constraints (experiment v5)
# ONLY what synthesis needs: clock period + IO pin/standard.
# Deliberately OMITTED (all are impl-time, and implicated in the
# .Xil/<top>_propImpl.xdc write that correlates with synth finalization hangs):
#   - the Tcl `if` block for clk50 generated clock
#   - create_generated_clock clk50
#   - set_false_path rst_n / jtag / dp_if
#   - set_property CLOCK_DEDICATED_ROUTE FALSE
# These are re-applied at implementation from nysa7_board_v15.xdc.

set_property PACKAGE_PIN E3      [get_ports {clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {clk}]
create_clock -name clk -period 10.000 -waveform {0.000 5.000} [get_ports {clk}]

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
