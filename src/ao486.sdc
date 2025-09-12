create_clock -name clk50 -period 20 -waveform {0 10} [get_ports {clk50}]
create_clock -name clk_x1 -period 13.47 -waveform {0 6.734} [get_pins {video/fb/u_ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
create_clock -name memory_clk -period 3.37 -waveform {0 1.68} [get_pins {video/fb/pll_ddr3_inst/u_pll/PLL_inst/CLKOUT2}]

// create_clock -name clk_sys -period 50 -waveform {0 25} [get_pins {pll/u_pll/PLL_inst/CLKOUT0}]
//create_clock -name clk_sys -period 40 -waveform {0 20} [get_pins {pll/u_pll/PLL_inst/CLKOUT0}]
create_clock -name clk_sys -period 36.3636 -waveform {0 18.1818} [get_pins {pll/u_pll/PLL_inst/CLKOUT0}]
create_clock -name clk_sdram_x2 -period 18.1818 -waveform {0 9.0909} [get_pins {pll/u_pll/PLL_inst/CLKOUT1}]

create_clock -name clk_vga -period 16.667 -waveform {0 8.333} [get_pins {pll_vga/u_pll/PLL_inst/CLKOUT0}]
create_clock -name clk_audio -period 40.69 -waveform {0 20.345} [get_pins {pll_audio/u_pll/PLL_inst/CLKOUT0}]

set_clock_groups -asynchronous -group [get_clocks {clk_sys}] -group [get_clocks {clk_vga}]
set_clock_groups -asynchronous -group [get_clocks {clk_sys}] -group [get_clocks {clk_x1}]
set_clock_groups -asynchronous -group [get_clocks {clk_sys}] -group [get_clocks {clk50}]
set_clock_groups -asynchronous -group [get_clocks {clk_sys}] -group [get_clocks {memory_clk}]
set_clock_groups -asynchronous -group [get_clocks {clk_sys}] -group [get_clocks {clk_audio}]

set_clock_groups -asynchronous -group [get_clocks {clk50}] -group [get_clocks {clk_x1}]
set_clock_groups -asynchronous -group [get_clocks {clk50}] -group [get_clocks {clk_vga}]
set_clock_groups -asynchronous -group [get_clocks {clk50}] -group [get_clocks {memory_clk}]
