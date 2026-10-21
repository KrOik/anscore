# gw2a_ips_barrel_align

64-bit barrel shifter and bit-offset aligner for unaligned word extraction from a stream

- Series: `ips` (ip_series_20k), family `path`.
- Core RTL: `src/ips_barrel_align.v`; testbench `sim/tb_ips_barrel_align.v`; independent golden model `models/ips_barrel_align.py`.
- Packaged wrapper: `gw2a_ips_barrel_align.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `94B54E27` == golden model digest `94B54E27`; 6 literal mutants all detected (3 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 340 LUT-class, 0 DSP-class (budget 340 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
