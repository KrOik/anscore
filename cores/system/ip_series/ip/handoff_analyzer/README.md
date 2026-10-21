# gw2a_ips_handoff_analyzer

Valid/ready interface analyser: max handoff edges, dead cycles, underrun and overrun ledger per burst

- Series: `ips` (ip_series_20k), family `obs`.
- Core RTL: `src/ips_handoff_analyzer.v`; testbench `sim/tb_ips_handoff_analyzer.v`; independent golden model `models/ips_handoff_analyzer.py`.
- Packaged wrapper: `gw2a_ips_handoff_analyzer.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `E13533FB` == golden model digest `E13533FB`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 149 LUT-class, 0 DSP-class (budget 260 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
