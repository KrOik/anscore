# gw2a_cnn_activation_lut

Registered lookup through a file-initialized ROM. The shipped default table
maps unsigned addresses to `min(address, 255)`; despite its filename, it is
not a sigmoid table. Custom table contents determine the activation function.
- Core: `activation_lut` (`src/activation_lut.v`)
- Validated: selftest unit(s) 9 (ALUT), digest `830A5F5F`, board bitstream `mff00`

## Ports

| port | dir | width | signed | note |
|---|---|---|---|---|
| clk | in | 1 | - | system clock |
| in_valid | input | 1 | no | input beat valid |
| val_in | input | INPUT_WIDTH | no | LUT address / value |
| out_valid | output | 1 | no | result valid (1-cycle latency) |
| confidence_out | output | OUTPUT_WIDTH | no | activation result |

## Parameters

| name | default |
|---|---|
| INPUT_WIDTH | 13 |
| OUTPUT_WIDTH | 8 |
| CONV_POSITIVE | 1 |
| LUT_FILE | "sigmoid_lut_8bit_to_8bit_h.mem" |

Packed array ports are flattened LSB-first: element `i` occupies bits `[i*W +: W]`.

`CONV_POSITIVE` is currently unused in RTL; changing it does not change the
lookup or reinterpret signed addresses. There is no reset. Output data is
unspecified before the first valid sample and holds during invalid cycles;
out_valid follows in_valid through one register.

Fresh default-table audit: all 8192 addresses plus 482 invalid cycles pass for
each CONV_POSITIVE value (0/1), against an independent unsigned saturation
oracle. Evidence: `artifacts/ip_optimization_20260924/cnn_activation_audit/`.
An isolated logic-ROM experiment frees four BRAMs at a cost of two LUTs and
eight additional FFs; it is not accepted into production or board-validated.
