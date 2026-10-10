# gw2a_ips_timer4_pwm_cap

Four-channel timer block: period PWM with duty update glitch-free, plus input capture and compare IRQ

- Series: `ips` (ip_series_20k), family `ctrl`.
- Core RTL: `src/ips_timer4_pwm_cap.v`; testbench `sim/tb_ips_timer4_pwm_cap.v`; independent golden model `models/ips_timer4_pwm_cap.py`.
- Packaged wrapper: `gw2a_ips_timer4_pwm_cap.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `A4D07E14` == golden model digest `A4D07E14`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 318 LUT-class, 0 DSP-class (budget 420 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
