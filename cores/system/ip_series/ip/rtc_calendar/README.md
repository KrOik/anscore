# gw2a_ips_rtc_calendar

Prescaler plus civil-time counter with month lengths, leap-year rule and alarm match

- Series: `ips` (ip_series_20k), family `ctrl`.
- Core RTL: `src/ips_rtc_calendar.v`; testbench `sim/tb_ips_rtc_calendar.v`; independent golden model `models/ips_rtc_calendar.py`.
- Packaged wrapper: `gw2a_ips_rtc_calendar.v` (this directory), verified to elaborate with the core.
- Verified: iverilog sim digest `100153F4` == golden model digest `100153F4`; 6 literal mutants all detected (6 by datapath change).
- Synthesized with `synth_gowin -noalu -family gw2a`: 203 LUT-class, 0 DSP-class (budget 340 / 0).
- Board evidence: DEFERRED.  This core has not been measured on silicon.
