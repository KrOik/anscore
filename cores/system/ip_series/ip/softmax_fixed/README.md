# gw2a_ips_softmax_fixed

Max-subtract, exp LUT, reciprocal-normalise softmax over 16 fixed-point logits

- Series: `ips` (ip_series_20k), family `nn`.
- Core RTL: `src/ips_softmax_fixed.v`; testbench `sim/tb_ips_softmax_fixed.v`; independent golden model `models/ips_softmax_fixed.py`.
- Packaged wrapper: `gw2a_ips_softmax_fixed.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `AEBA358B` == golden model digest `AEBA358B`; 6 literal mutants all detected (4 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 174 LUT-class, 1 DSP-class (budget 520 / 2).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
