# gw2a_ips_spi_slave_reg

SPI mode 0-3 slave, 8/16-bit frame, register-indexed read/write with CS-edge alignment

- Series: `ips` (ip_series_20k), family `iface`.
- Core RTL: `src/ips_spi_slave_reg.v`; testbench `sim/tb_ips_spi_slave_reg.v`; independent golden model `models/ips_spi_slave_reg.py`.
- Packaged wrapper: `gw2a_ips_spi_slave_reg.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `A53B7AF1` == golden model digest `A53B7AF1`; 6 literal mutants all detected (3 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 212 LUT-class, 0 DSP-class (budget 300 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
