# gw2a_ips_delay_tap

Programmable 0..255-cycle delay line that carries valid/ready payload without bubble re-alignment

- Series: `ips` (ip_series_20k), family `path`.
- Core RTL: `src/ips_delay_tap.v`; testbench `sim/tb_ips_delay_tap.v`; independent golden model `models/ips_delay_tap.py`.
- Packaged wrapper: `gw2a_ips_delay_tap.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `55C70332` == golden model digest `55C70332`; 6 literal mutants all detected (5 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 232 LUT-class, 0 DSP-class (budget 260 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
