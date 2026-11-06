# Resident 2:4 INT4 matrix inference

Keeps a compressed S4 matrix resident, caches one U8 vector and returns an S8
result per selected output row. In every four-column group only two positions
are represented. Zero stored weights permit fewer than two nonzero entries.
This is a compressed inference representation; it does not prune or train a
dense model, and makes no model-accuracy claim.

For the dense row obtained by expanding each compressed group:

```
acc[r] = bias[r] + sum_c((U8(x[c])-U8(cmd_x_zero))*S4(W[r,c]))
y[r] = sat_S8(RNE(acc[r]*U16(scale[r])/2^shift[r]) + S8(zero[r]))
```

RNE is exact nearest with ties to even, before adding the output zero. Clip
reports final S8 saturation; inexact reports discarded nonzero fractional bits.
Bias is S32, scale U16, shift 0..31, output zero S8. The 40-bit accumulator and
57-bit scaling product are exact throughout the supported input domain.

## Configuration representation

One rising-edge clock, synchronous active-high reset, no CE or CDC. Every public
transfer uses valid && ready. Sources hold their complete payload while stalled.
Configuration takes priority over an offered command. The held configuration
response must retire before another operation can start. Configuration cannot
change during a vector transaction. Config errors make no changes.

| c_op | Operation |
| --- | --- |
| 0 | Write one 11-bit group at c_row,c_group: {c_pattern,c_weights[7:0]}. Low nibble is the first position's S4 weight, high nibble the second. |
| 1 | Write c_bias/c_scale/c_shift/c_zero for c_row. |
| 2 | Invalidate all group prefixes and row metadata. Other fields ignored. |
| 3 | Unsupported opcode; error 2. |

| c_pattern | Ordered positions within the four-column group |
| --- | --- |
| 0 | 0,1 |
| 1 | 0,2 |
| 2 | 0,3 |
| 3 | 1,2 |
| 4 | 1,3 |
| 5 | 2,3 |
| 6,7 | Invalid; error 2 |

Each row has a configured consecutive group prefix. Writing group 0 starts a
new prefix of length one, invalidating every previously configured suffix.
Writing group equal to the current prefix length appends it. Rewriting an
already configured nonzero group leaves the prefix length unchanged. Skipping
over a group is rejected with error 3. Metadata is independent and survives
group-0 replacement. This avoids a resettable valid bit per memory word.

c_error: 0 success; 1 row/group out of static range; 2 unsupported opcode or
pattern; 3 noncontiguous write. Opcode 0 checks ranges, then pattern, then prefix.
Opcode 1 ignores group/pattern/weights. Reset and invalidate clear metadata and
prefix validity, leaving payload RAM bytes stale and inaccessible.

## Commands, input, output and recovery

MAX_ROWS 1..64, MAX_COLS 1..1024, TAG_W 1..32; defaults 8/64/16. Unsupported
static parameters fail elaboration. Runtime cmd_rows/cmd_cols select a nonzero
top-left submatrix. Before accepting input the core checks each used row's
metadata and at least ceil(cmd_cols/4) consecutive groups. Positions outside
cmd_cols in the final group contribute zero even if their stored weights are
nonzero. All other omitted coordinates are structurally zero.

After precheck, supply exactly cmd_cols U8 samples in ascending column order,
with s_last true only on the final beat. There is one vector in flight. Output
rows are ascending, m_row is the row index, m_tag is the command tag, and m_last
marks the final row. Every output field remains stable under backpressure;
the unchanged three-stage requantizer may overlap later row computation with
earlier output retirement. The next command is admitted only after the final
result retires. RAM weights and metadata persist across commands.

m_error: 0 normal; 1 invalid runtime dimensions; 2 incomplete required prefix
or metadata; 3 incorrect input LAST. An error produces one beat with data/row/
clip/inexact zero, original tag, last1. Precheck and full vector loading happen
before arithmetic, so an invalid transaction emits no successful prefix rows.
An early LAST aborts immediately without draining future beats. Stop the aborted
input and submit a complete new command/vector after consuming the error.
Reset cancels configuration replies, partial vectors, computation and held
outputs, clears all validity, flushes the quantizer and requires reconfiguration.
All ready/valid outputs are suppressed during reset. There is no timeout for
missing input or stalled output and no unconditional completion deadline.

## Architecture and example

See ARCHITECTURE.md for the 11-bit/group layout, prefix validity, one 9x4 MAC
multiplier and cycle budget. files.f and example/files.f resolve from this
package root and include the existing canonical requantizer dependency alias.
No weights or generator outputs need downloading.

four_feature_sparse_top2 is an actual fixed sparse projection followed by the
existing signed stable stream_topk(K=2). One packed four-U8 input produces the
two highest RNE((x[a]-x[b])/2) values from pairs (0,1),(0,2),(1,3),(2,3).
Equal scores preserve the smaller row index. Its interface is ordinary
ready/valid; input has a tag, outputs have score/index/tag and last on rank 2.
It boots four resident rows after reset, allows one input in flight, and admits
the next packed input only after the final rank retires. Reset cancels both
cores and reboots weights. TAG_W is 1..32. No application accuracy is implied.

## Qualification

Authoring state: RTL_CANDIDATE, INTEGRATION_CANDIDATE, HW_UNVERIFIED.
Finite source-reviewed syntax/unit plan is in FINITE_PLAN.json; execution
requires exact root and independent-peer pins. No tests have run yet. No
synthesis, PnR, STA, board test, PPA or inherited regression is authorized here.
