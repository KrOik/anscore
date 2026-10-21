# gw2a_ips_topk_argmax4

Unordered top-4 of 16 fixed-point scores with distinct-index handling and tie-break by index

- Series: `ips` (ip_series_20k), family `nn`.
- Core RTL: `src/ips_topk_argmax4.v`; testbench `sim/tb_ips_topk_argmax4.v`; independent golden model `models/ips_topk_argmax4.py`.
- Packaged wrapper: `gw2a_ips_topk_argmax4.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `1C16DD59` == golden model digest `1C16DD59`; 6 literal mutants all detected (3 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 211 LUT-class, 0 DSP-class (budget 320 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
