# gw2a_ips_gpio_irq_bank

32-bit GPIO bank with direction, polarity, edge/level interrupt, sticky status and clear-on-write

- Series: `ips` (ip_series_20k), family `ctrl`.
- Core RTL: `src/ips_gpio_irq_bank.v`; testbench `sim/tb_ips_gpio_irq_bank.v`; independent golden model `models/ips_gpio_irq_bank.py`.
- Packaged wrapper: `gw2a_ips_gpio_irq_bank.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `DF13819D` == golden model digest `DF13819D`; 6 literal mutants all detected (5 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 290 LUT-class, 0 DSP-class (budget 300 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
