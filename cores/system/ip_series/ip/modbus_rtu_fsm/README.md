# gw2a_ips_modbus_rtu_fsm

Modbus RTU slave framing over a byte pipe: 3.5T silence detect, address filter, CRC16 check, exception responses

- Series: `ips` (ip_series_20k), family `iface`.
- Core RTL: `src/ips_modbus_rtu_fsm.v`; testbench `sim/tb_ips_modbus_rtu_fsm.v`; independent golden model `models/ips_modbus_rtu_fsm.py`.
- Packaged wrapper: `gw2a_ips_modbus_rtu_fsm.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `2799D226` == golden model digest `2799D226`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 301 LUT-class, 0 DSP-class (budget 380 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
