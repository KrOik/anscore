# gw2a_dsp_dds_nco

32-bit phase accumulator DDS/NCO, 256x16 sine LUT inferred as BSRAM,
16-bit sine + square outputs, zero DSP.

- Core: `dds_nco` (`src/dds_nco.v`)
- Validated: selftest unit 2 (DDS), digest `0F185BED`
- Board evidence: `doc/board_uart_la.txt` (on-board UART report decoded via LA)

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| rst_n | in | 1 | - | active-low reset |
| run | in | 1 | - | accumulate enable |
| tuning_word | in | 32 | no | phase increment per clk_en beat |
| sine_out | out | 16 | yes | Q1.15 sine sample, registered (1-beat lag) |
| square_out | out | 1 | - | phase_acc[31], 50% duty |
| phase_out | out | 32 | no | diagnostic tap |

## Parameters

| name | default |
|---|---|
| LUT_FILE | "sine256.mem" |

## Notes

- `sine256.mem` ships in this directory; `$readmemh` resolves it relative to
  the build working directory (override `LUT_FILE` if integrating elsewhere).
- Output frequency = tuning_word * f_clk_en / 2^32.
- LUT infers one SPX9 BSRAM on GW2A-18C.
- Independent golden: `tools/golden_model.py`.
