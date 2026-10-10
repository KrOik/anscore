# gw2a_ips_secded64_ecc

SECDED(72,64) Hamstone encoder and decoder: corrects single-bit, detects double-bit, reports syndrome

- Series: `ips` (ip_series_20k), family `path`.
- Core RTL: `src/ips_secded64_ecc.v`; testbench `sim/tb_ips_secded64_ecc.v`; independent golden model `models/ips_secded64_ecc.py`.
- Packaged wrapper: `gw2a_ips_secded64_ecc.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `A87CC194` == golden model digest `A87CC194`; 6 literal mutants all detected (3 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 333 LUT-class, 0 DSP-class (budget 420 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
