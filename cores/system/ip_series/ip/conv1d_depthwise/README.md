# gw2a_ips_conv1d_depthwise

Depthwise separable 1-D conv with programmable tap count, per-channel multiplier and shift

- Series: `ips` (ip_series_20k), family `nn`.
- Core RTL: `src/ips_conv1d_depthwise.v`; testbench `sim/tb_ips_conv1d_depthwise.v`; independent golden model `models/ips_conv1d_depthwise.py`.
- Packaged wrapper: `gw2a_ips_conv1d_depthwise.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `EE73D473` == golden model digest `EE73D473`; 6 literal mutants all detected (5 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 156 LUT-class, 1 DSP-class (budget 460 / 1).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
