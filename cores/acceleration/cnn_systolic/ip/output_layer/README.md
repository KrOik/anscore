# gw2a_cnn_output_layer

Channel accumulate + bias + shift + ReLU quantize stage.
- Core: `output_layer` (`src/output_layer.v`)
- Validated: selftest unit(s) 11 (OL), digest `46E9E19D`, board bitstream `mff00`

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| rst_n | in | 1 | - | active-low asynchronous control reset; data pipeline is flushed by the stream |
| clk_en | in | 1 | - | step enable; tie 1 for full rate |
| new_line_in | input | 1 | no | row sync from input_layer |
| page_y_out | input | PE_COL_NUM*PE_PAGE_NUM*PE_OUT_WIDTH | yes | partial sums [page][col] |
| final_out | output | PE_COL_NUM*OUT_WIDTH | no | quantized output |
| output_valid | output | 1 | no | result valid |
| new_line_out_1 | output | 1 | no | row marker |

## Parameters

| name | default |
|---|---|
| PE_PAGE_NUM | 2 |
| PE_COL_NUM | 2 |
| PE_ROW_NUM | 9 |
| PE_OUT_WIDTH | 20 |
| BIAS_WIDTH | 16 |
| ACC_WIDTH | 22 |
| SHIFT_KEY | 4 |
| OUT_WIDTH | 8 |
| CYCLE_PERIOD_OUT | 2 |
| CYCLE_PERIOD_IN | 1 |
| IMG_COL | 8 |
| WITH_RELU | 1 |
| BIAS_FILE | "bias_test.mem" |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

## Single output slot accumulation (2026-09-24)

`CYCLE_PERIOD_OUT=1` supports multiple input slots (`CYCLE_PERIOD_IN>1`).
It feeds back the preceding accumulator value directly; there is no extra
output-channel delay. The former implementation forced feedback to zero and
silently retained only the final input slot. A reproduced two-page example
returned 3 instead of the required sum -21. `CYCLE_PERIOD_OUT>1` still uses
the existing delayed feedback and all original digests are unchanged.

Run `scripts/test_cnn_output_optimization.ps1 -OutputDir <new-directory>` from
the repository root. It now checks thirteen parameter combinations, signed sums,
column alignment, pauses, all 16 legacy unit digests and complete UART output.
Bias initialization is binary (`$readmemb`), not hexadecimal.

At 27 MHz / clk_en=1, two physical captures across reprogramming passed 604
frames / 9664 signed output values for CPO=1, CPI=3, two pages and two columns.
The same board harness reproduces the old failure. Its routed LUT4 changes
478 -> 600, FF 524 -> 557, DSP/BSRAM remain 0/0. These are harness totals,
not isolated-core metrics. This is a correctness repair, not an area saving.

Legacy integration (mask 0x1800) also passes five complete UART reports:
OL `46E9E19D` and LAYR `9A9AEA61`; other units are explicitly disabled in this
board image and covered by full-mask simulation. Integrated resources are
3130 routed LUT4, 2868 FF, zero DSP and 12 BSRAM.
Evidence: `artifacts/ip_optimization_20260924/cnn_output/` from repository root.

## More than nine pages: physical verification pending

The working core now includes every input page in its three registered partial
sum groups. The previous fixed groups silently ignored pages with index >=9.
An independent 10-page test reproduced -44 instead of the required -33.
Tests for 9, 10, 12 and 16 pages and a signed saturation case pass, with all
original digests and valid timing preserved. The 10-page UART harness also
passes simulation; a 1117-LUT4 / zero-DSP board image is ready.

This additional change is **not yet board-accepted**: the identified JTAG USB
adapter has persistent bulk-transfer errors before programming. Its prepared
images and recovery logs are under `artifacts/ip_optimization_20260924/cnn_output_pages/`.
The physical results above belong to the earlier single-slot repair, not a
claim that more-than-nine-page operation has passed on hardware.
