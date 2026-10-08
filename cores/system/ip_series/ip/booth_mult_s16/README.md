# gw2a_ips_booth_mult_s16

Signed 16x16 Booth multiplier, 4-stage pipelined, 2's complement product with overflow flag

- Series: `ips` (ip_series_20k), family `arith`.
- Core RTL: `src/ips_booth_mult_s16.v`; testbench `sim/tb_ips_booth_mult_s16.v`; independent golden model `models/ips_booth_mult_s16.py`.
- Packaged wrapper: `gw2a_ips_booth_mult_s16.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `4EF92B53` == golden model digest `4EF92B53`; 6 literal mutants all detected (5 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 331 LUT-class, 0 DSP-class (budget 500 / 1).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
