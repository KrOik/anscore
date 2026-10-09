# gw2a_ips_key_slot_kmu

Eight key slots with write-once load, access-permission binding and zeroisation on violation

- Series: `ips` (ip_series_20k), family `sec`.
- Core RTL: `src/ips_key_slot_kmu.v`; testbench `sim/tb_ips_key_slot_kmu.v`; independent golden model `models/ips_key_slot_kmu.py`.
- Packaged wrapper: `gw2a_ips_key_slot_kmu.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `4852461D` == golden model digest `4852461D`; 6 literal mutants all detected (3 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 309 LUT-class, 0 DSP-class (budget 340 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
