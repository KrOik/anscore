# gw2a_ips_int8_mac_array

8x8 int8 multiply-accumulate array with per-row bias and int32 saturating accumulation

- Series: `ips` (ip_series_20k), family `nn`.
- Core RTL: `src/ips_int8_mac_array.v`; testbench `sim/tb_ips_int8_mac_array.v`; independent golden model `models/ips_int8_mac_array.py`.
- Packaged wrapper: `gw2a_ips_int8_mac_array.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `4399E880` == golden model digest `4399E880`; 6 literal mutants all detected (3 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 663 LUT-class, 4 DSP-class (budget 700 / 4).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
