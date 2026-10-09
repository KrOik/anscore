# gw2a_ips_one_wire_master

1-Wire master with reset/presence, slot timing generation and sampling, CRC8 over 9-byte scratchpad

- Series: `ips` (ip_series_20k), family `iface`.
- Core RTL: `src/ips_one_wire_master.v`; testbench `sim/tb_ips_one_wire_master.v`; independent golden model `models/ips_one_wire_master.py`.
- Packaged wrapper: `gw2a_ips_one_wire_master.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `2191E358` == golden model digest `2191E358`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 128 LUT-class, 0 DSP-class (budget 340 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
