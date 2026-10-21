# gw2a_ips_dot_mac8

8-lane fixed-point dot product tree with saturation, one vector per cycle throughput

- Series: `ips` (ip_series_20k), family `arith`.
- Core RTL: `src/ips_dot_mac8.v`; testbench `sim/tb_ips_dot_mac8.v`; independent golden model `models/ips_dot_mac8.py`.
- Packaged wrapper: `gw2a_ips_dot_mac8.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `1DF76A4A` == golden model digest `1DF76A4A`; 6 literal mutants all detected (4 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 374 LUT-class, 1 DSP-class (budget 380 / 2).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
