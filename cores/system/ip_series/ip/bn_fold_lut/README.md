# gw2a_ips_bn_fold_lut

Batch-norm folding helper: computes folded weight and bias per channel with fixed-point rounding

- Series: `ips` (ip_series_20k), family `nn`.
- Core RTL: `src/ips_bn_fold_lut.v`; testbench `sim/tb_ips_bn_fold_lut.v`; independent golden model `models/ips_bn_fold_lut.py`.
- Packaged wrapper: `gw2a_ips_bn_fold_lut.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `65D60F2E` == golden model digest `65D60F2E`; 6 literal mutants all detected (4 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 110 LUT-class, 1 DSP-class (budget 360 / 2).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
