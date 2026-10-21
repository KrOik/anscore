# gw2a_ips_scr_descrambler

Self-synchronising additive scrambler/descrambler pair over a 43-bit LFSR with error-multiplication bound

- Series: `ips` (ip_series_20k), family `path`.
- Core RTL: `src/ips_scr_descrambler.v`; testbench `sim/tb_ips_scr_descrambler.v`; independent golden model `models/ips_scr_descrambler.py`.
- Packaged wrapper: `gw2a_ips_scr_descrambler.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `7906435A` == golden model digest `7906435A`; 6 literal mutants all detected (4 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 158 LUT-class, 0 DSP-class (budget 160 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
