# gw2a_dsp_cordic

16-stage pipelined CORDIC, Q2.14 fixed point, rotation + vectoring modes,
shift-add only (0 DSP).

- Core: `cordic` (`src/cordic.v`)
- Validated: selftest units 0 (CRDR) / 1 (CRDV), digests `5B8CCF9D` / `4A4E2D09`
- Board evidence: `doc/board_uart_la.txt` (on-board UART report decoded via LA)

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| rst_n | in | 1 | - | active-low reset |
| mode | in | 1 | - | 0=rotation, 1=vectoring |
| in_valid | in | 1 | - | input strobe |
| x_in | in | IW | yes | Q2.14 |
| y_in | in | IW | yes | Q2.14 |
| z_in | in | IW | yes | phase rad*2^14 (rotation); initial angle offset (vector) |
| x_out | out | IW | yes | rot: 1.6468*cos; vec: 1.6468*hypot |
| y_out | out | IW | yes | rot: 1.6468*sin |
| z_out | out | ZW | yes | vec: atan2(y,x)*2^14 rad |
| out_valid | out | 1 | - | aligned with outputs, latency STAGES+1 beats |

## Parameters

| name | default |
|---|---|
| IW | 16 |
| ZW | 18 |
| STAGES | 16 |

## Notes

- Outputs carry the intrinsic CORDIC gain ~1.6468; scale downstream or fold
  into the application (golden model already accounts for it).
- Rotation with `|z_in| > pi/2` is pre-rotated by +/-pi; the signed 16-bit
  Q2.14 input covers approximately [-2,2) radians. Vectoring uses an 18-bit
  angle output and folds negative x to support all input quadrants.
- Independent golden: `tools/golden_model.py` (fixed-point recurrence,
  constants generated with Python math).

## 2026-09-24 optimization

Each x/y stage now shares an adder/subtractor using conditional operand
inversion and carry-in. Default isolated LUT1-4 falls 3,046 -> 2,197 (-27.9%);
1,002 FF, zero DSP/BRAM and pipeline behavior are unchanged. Latency is 17
enabled periods between input acceptance and output edges for STAGES=16.

Validation: all 1,057 Yosys equivalence cells proven under an async2sync reset
model; 4,096 independent vectors plus bubbles, pauses and asynchronous reset;
all original DSP digests and UART report pass. The complete DSP board design
uses 10,585 -> 8,583 LUT4, with post-route Fmax estimates 90.87 -> 61.79 MHz.
This is an area optimization at the 27 MHz target, not a frequency improvement.

Full-rate board test captured 11 complete streams, each with 32 adjacent
mixed-mode inputs. Every x/y/z value matches the independent model; hardware
checks 17-cycle port latency and one-cycle output cadence. Evidence at
repository `artifacts/ip_optimization_20260924/cordic/`, reproduction commands
in `docs/IP_OPTIMIZATION_STATUS.md`.
