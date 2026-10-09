# gw2a_ips_mdio_master

Ethernet PHY MDIO master, preamble/start/op/PA/PHYAD/REGAD/TURN/data FSM with turnaround tri-state

- Series: `ips` (ip_series_20k), family `iface`.
- Core RTL: `src/ips_mdio_master.v`; testbench `sim/tb_ips_mdio_master.v`; independent golden model `models/ips_mdio_master.py`.
- Packaged wrapper: `gw2a_ips_mdio_master.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `C6DC6F3C` == golden model digest `C6DC6F3C`; 6 literal mutants all detected (3 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 151 LUT-class, 0 DSP-class (budget 300 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
