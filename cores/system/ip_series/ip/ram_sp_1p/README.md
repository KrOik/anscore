# gw2a_ips_ram_sp_1p

Single-port RAM wrapper with byte write enable, optional registered read and BSRAM inference contract

- Series: `ips` (ip_series_20k), family `path`.
- Core RTL: `src/ips_ram_sp_1p.v`; testbench `sim/tb_ips_ram_sp_1p.v`; independent golden model `models/ips_ram_sp_1p.py`.
- Packaged wrapper: `gw2a_ips_ram_sp_1p.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `0BF2AA2E` == golden model digest `0BF2AA2E`; 6 literal mutants all detected (2 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 165 LUT-class, 0 DSP-class (budget 200 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
