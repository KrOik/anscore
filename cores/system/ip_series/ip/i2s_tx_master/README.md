# gw2a_ips_i2s_tx_master

I2S stereo transmit master with programmable BCLK divider and right-justified or standard alignment

- Series: `ips` (ip_series_20k), family `iface`.
- Core RTL: `src/ips_i2s_tx_master.v`; testbench `sim/tb_ips_i2s_tx_master.v`; independent golden model `models/ips_i2s_tx_master.py`.
- Packaged wrapper: `gw2a_ips_i2s_tx_master.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `B7B81C4A` == golden model digest `B7B81C4A`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 127 LUT-class, 0 DSP-class (budget 260 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
