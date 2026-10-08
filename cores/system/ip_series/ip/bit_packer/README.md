# gw2a_ips_bit_packer

MSB-first bit packer turning N-bit fields of arbitrary width into a byte-aligned output burst

- Series: `ips` (ip_series_20k), family `pkt`.
- Core RTL: `src/ips_bit_packer.v`; testbench `sim/tb_ips_bit_packer.v`; independent golden model `models/ips_bit_packer.py`.
- Packaged wrapper: `gw2a_ips_bit_packer.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `7B33E327` == golden model digest `7B33E327`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 164 LUT-class, 0 DSP-class (budget 260 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
