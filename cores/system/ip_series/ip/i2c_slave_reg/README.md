# gw2a_ips_i2c_slave_reg

I2C 7-bit slave with 8-bit register index auto-increment and repeated-start safe state decode

- Series: `ips` (ip_series_20k), family `iface`.
- Core RTL: `src/ips_i2c_slave_reg.v`; testbench `sim/tb_ips_i2c_slave_reg.v`; independent golden model `models/ips_i2c_slave_reg.py`.
- Packaged wrapper: `gw2a_ips_i2c_slave_reg.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `6027DAAB` == golden model digest `6027DAAB`; 6 literal mutants all detected (3 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 313 LUT-class, 0 DSP-class (budget 420 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
