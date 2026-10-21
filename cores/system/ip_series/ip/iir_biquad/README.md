# gw2a_ips_iir_biquad

Direct-form II biquad IIR section, transposed dual accumulators, saturation on state update

- Series: `ips` (ip_series_20k), family `arith`.
- Core RTL: `src/ips_iir_biquad.v`; testbench `sim/tb_ips_iir_biquad.v`; independent golden model `models/ips_iir_biquad.py`.
- Packaged wrapper: `gw2a_ips_iir_biquad.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `5C61A108` == golden model digest `5C61A108`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 216 LUT-class, 2 DSP-class (budget 420 / 2).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
