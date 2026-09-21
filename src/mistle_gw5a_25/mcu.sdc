create_clock -name mcu_clk -period 50 -waveform {0 25} [get_ports {mcu_clk}] -add
