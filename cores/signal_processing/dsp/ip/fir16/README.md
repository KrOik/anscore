# gw2a_dsp_fir16

16-tap symmetric FIR filter, 8-bit unsigned samples, 8 unique coefficients
(symmetric fold: tap k pairs with tap 15-k), saturating output, shift-add
constant products (0 DSP).

- Core: `fir16` (`src/fir16.v`)
- Validated: selftest unit 3 (FIR), digest `20038C18`
- Board evidence: `doc/board_uart_la.txt` (on-board UART report decoded via LA)

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| rst_n | in | 1 | - | active-low reset |
| in_valid | in | 1 | - | sample strobe |
| sample_in | in | 8 | no | unsigned sample |
| y_out | out | 8 | no | saturating filter output |
| out_valid | out | 1 | - | output strobe, 1 beat latency |

## Parameters

| name | default |
|---|---|
| C0..C7 | 1,2,4,8,16,32,32,16 |
| OUT_SHIFT | 8 |

## Notes

- Tap coefficients: taps 0..7 = C0..C7, taps 8..15 = C7..C0 (symmetric).
- Default coefficients implement a mild lowpass; sum(C)*2/2^OUT_SHIFT sets DC
  gain. Defaults sum to 256 >> 8 = unity.
- Constant products constant-fold into shift-add trees; no DSP inferred.
- Independent golden: `tools/golden_model.py` (convolution model).
