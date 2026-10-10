# dut_hdmi.sdc -- timing constraints for dut_hdmi_top (nextpnr-himbaechel).
# Single pin clock: hdmi_clk (MS5351 CLK2, 125.875 MHz). pix_clk is a fabric
# /5 (25.175 MHz) promoted by the tool -- no SDC generated-clock needed;
# the PnR report must show its achieved Fmax >= 25.175 MHz with margin.
# PASS = 0 setup/hold errors on all domains (see rtl/README.md).
create_clock -name hdmi_clk -period 7.94453 [get_ports {hdmi_clk}]

# Async-reset-tree note: the first full PnR (async u_out regs) failed with
# 10 hold violations on a reset-derived pseudo-clock (fabric CLEAR tree
# skew); converting the serializer block to sync release (2FF in hdmi)
# removed that clock. If PnR still reports holds on the pix fabric clock,
# they are skew-vs-fast-data on real paths (all observed so far: the UART
# txbuf read mux): see rtl/README.md "PnR hold" note -- candidates are
# --tmg-ripup (router hold-fixing), dropping the 64-bit observation bus to
# compact placement, and, only for protocol-separated paths, targeted
# set_false_path endpoints (SDC needs -to; bare -from is rejected).
