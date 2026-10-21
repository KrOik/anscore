# gw2a_ips_i2s_rx_slave

I2S stereo receive slave with word-select edge detect, valid framing and dropped-frame counter

- Series: `ips` (ip_series_20k), family `iface`.
- Core RTL: `src/ips_i2s_rx_slave.v`; testbench `sim/tb_ips_i2s_rx_slave.v`; independent golden model `models/ips_i2s_rx_slave.py`.
- Packaged wrapper: `gw2a_ips_i2s_rx_slave.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `25A60BCC` == golden model digest `25A60BCC`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 100 LUT-class, 0 DSP-class (budget 260 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
