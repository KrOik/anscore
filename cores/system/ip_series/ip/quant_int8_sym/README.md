# gw2a_ips_quant_int8_sym

Symmetric quantise and dequantise pair with programmable scale, round-half-away and clipping

- Series: `ips` (ip_series_20k), family `nn`.
- Core RTL: `src/ips_quant_int8_sym.v`; testbench `sim/tb_ips_quant_int8_sym.v`; independent golden model `models/ips_quant_int8_sym.py`.
- Packaged wrapper: `gw2a_ips_quant_int8_sym.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `E2BBA84A` == golden model digest `E2BBA84A`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 220 LUT-class, 1 DSP-class (budget 300 / 1).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
