# gw2a_dsp_pid_core

Discrete PID controller with shift-based gains, integrator anti-windup clamp,
and output clamp. Constant products use shift-add only (0 DSP).

- Core: `pid_core` (`src/pid_core.v`)
- Validated: selftest unit 4 (PID), digest `5C690862`
- Board evidence: `doc/board_uart_la.txt` (on-board UART report decoded via LA)

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| rst_n | in | 1 | - | active-low reset |
| in_valid | in | 1 | - | error sample strobe |
| err_in | in | 16 | yes | error input |
| u_out | out | 16 | yes | control output, clamped to +/-OUT_LIM |
| out_valid | out | 1 | - | output strobe, 1 beat latency |

## Parameters

| name | default | meaning |
|---|---|---|
| KP_MUL/KP_SH | 96 / 6 | Kp = 96/64 = 1.5 |
| KI_MUL/KI_SH | 4 / 6  | Ki = 4/64 = 0.0625 |
| KD_MUL/KD_SH | 32 / 6 | Kd = 32/64 = 0.5 |
| I_LIM | 16000 | integrator clamp (anti-windup) |
| OUT_LIM | 32000 | output clamp |

## Notes

- Update per clk_en beat: u(k) = Kp*e(k) + I + Kd*(e(k)-e(k-1)),
  I clamped to +/-I_LIM after each integrate step (anti-windup).
- Gains are compile-time (mul,shift) pairs; small gain-LUT at integration
  boundary is the intended extension if runtime gain change is needed.
- Independent golden: `tools/golden_model.py` (difference-equation model).
