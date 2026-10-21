# gw2a_ips_ct_compare

Length and content comparison that is time- and energy-constant, with early-exit resistance

- Series: `ips` (ip_series_20k), family `sec`.
- Core RTL: `src/ips_ct_compare.v`; testbench `sim/tb_ips_ct_compare.v`; independent golden model `models/ips_ct_compare.py`.
- Packaged wrapper: `gw2a_ips_ct_compare.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `44967A5D` == golden model digest `44967A5D`; 6 literal mutants all detected (5 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 161 LUT-class, 0 DSP-class (budget 180 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
