# Resident INT4 matrix inference

`int4_weight_matvec` keeps a packed signed-INT4 matrix in local memory, loads one
U8 activation vector, and reuses it across runtime-selected output rows. Weights
and per-row quantization parameters persist across vectors. This is a dense
layer / 1x1-convolution-channel primitive; window generation, tensor layout, DMA
and whole-network scheduling belong to the caller.

For each row, with all operations exact until the stated rounding:

```
acc[r] = bias[r] + sum_c((U8(x[c]) - U8(cmd_x_zero)) * S4(W[r,c]))
rounded = RNE(acc[r] * U16(scale[r]) / 2^shift[r])
y[r] = sat_signed8(rounded + signed8(zero[r]))
```

RNE means nearest integer, exact ties to even, including negative values. The
output zero is added **after rounding**; moving an odd zero before a half tie
changes the required parity. `m_clip` flags final saturation; `m_inexact` flags
discarded nonzero fractional bits before the zero addition, independently of
clipping. Scale zero is legal. Bias is signed32 in accumulator units; scale is
an unsigned16 integer, shift is 0..31, zero is signed8. Model export must supply
these parameters; no floating-point scale conversion occurs in hardware.

The 40-bit accumulator is exact over the supported domain: even at1024 columns,
the dot magnitude is at most1024*255*8, and bias adds at most2^31. The57-bit
signed scaling product and64-bit quantizer input are exact. The unchanged
`stream_requantize` first rounds/clamps to signed16. Any value clipping at that
stage remains outside signed8 after every allowed zero offset, so the final
signed8 result and clip flag equal the formula above. Offsets travel in the
quantizer tag and cannot be confused between rows under stalls.

## Interface and lifecycle

One rising-edge clock, synchronous active-high `rst`, no CE, no CDC. Reset
cancels pending configuration, vector and output transactions, clears all
configuration-valid bits, and flushes the quantizer. RAM contents are not reset
and cannot be used until configured again. Ready/valid is suppressed during
reset. `busy` reflects FSM state and becomes idle at the reset edge.

Every transfer is standard `valid && ready`, independent of any legacy CE.
Sources hold valid and the associated payload until accepted. All results and
configuration responses remain stable while stalled. There is one vector in
flight; output rows preserve ascending row order. The three-slot quantizer may
overlap row computation with output delivery. Backpressure eventually stalls
computation and cannot affect cached operands or numerical results.

Configuration is accepted only in idle; `c_valid` has priority over a simultaneous
command. `cmd_ready` stays low until the held configuration response is consumed.
No configuration can change during precheck, loading, computation or output drain.
`c_rsp_valid/c_rsp_ready` returns `c_error`:0 success,1 index out of range,
2 unsupported opcode. Errors leave memory and validity unchanged.

| c_op | Effect |
| --- | --- |
| 0 | Write32-bit `c_weights` to row `c_row`, packed-word index `c_word`. Nibble bits4*i+:4 encode column8*c_word+i, two's complement -8..7. |
| 1 | Write `c_bias/c_scale/c_shift/c_zero` to `c_row`. `c_word` and weights are ignored. |
| 2 | Invalidate every weight word and metadata row. Other fields ignored. |
| 3 | Return unsupported-opcode error. |

Static parameters: MAX_ROWS1..64, MAX_COLS1..1024, TAG_W>=1; defaults8/64/16.
Other static settings are outside the contract; no elaboration-time rejection
guard is implemented.
Runtime `cmd_rows/cmd_cols` select the top-left submatrix with nonzero dimensions
bounded by those parameters. Command acceptance latches dimensions, U8 input
zero and opaque tag. The core checks **every used word and metadata row** before
asserting `s_ready`. Padding nibbles after MAX_COLS or cmd_cols are ignored.

Then exactly cmd_cols samples arrive in column order. `s_last` must equal
`column==cmd_cols-1`. Input gaps have no limit. There is no timeout. A valid
transaction emits cmd_rows signed8 beats with row index, tag, flags, and
`m_last` on the final row. The next command becomes eligible after that final
beat transfers.

`m_error`:0 success,1 invalid dimensions,2 unconfigured required word/row,
3 incorrect input LAST. An error produces exactly one beat: zero data/row,
original command tag, last1, clip/inexact0. Validation precedes all arithmetic,
so errors produce no partial rows. Early LAST aborts immediately; it does not
drain the remainder. The caller stops the aborted vector and submits a full new
command/vector after consuming the error. Missing LAST at the prescribed final
sample also aborts. Reset and invalidate require reconfiguration.

## Storage, cycles and feasibility

Word address is row*ceil(MAX_COLS/8)+word. Weight/vector reads register data at
RD, consumed at the following MAC edge; writes occur at accepted config/input
edges, with no concurrent read/write transaction. No external memory, ROM data
files or vendor primitives are required. Metadata uses small register arrays;
weight/vector arrays have synchronous read ports and no reset. Inference of
specific BRAM arrangements has not been checked.

A parallel row engine would replicate memory ports/MACs; this implementation
uses one9x4 multiplier/MAC and one40x17 row-scaling multiplier. Each term takes
two clocks, keeping memory reads separate from arithmetic. Precheck takes
rows*ceil(cols/8) clocks after command acceptance. With no input gaps/stalls,
if the final sample transfers at edge E, the first quantizer input transfers
at E+2*cols+3; first output becomes valid just after E+2*cols+5 and can transfer
at E+2*cols+6. Subsequent output transfers are2*cols+3 clocks apart when
always ready. Stalls and unavailable input/configuration have no bounded delay.
No frequency, physical throughput or power claim follows from these cycle counts.

Default matrix storage is2048bits, vector512bits, metadata488bits, validity72bits,
plus arithmetic/control/quantizer registers. The64x1024 limit needs262144 weight
bits plus8256 resettable validity bits; it is not the default. Architecture risk **MEDIUM**: small serialized MAC,
variable nibble selection and address arithmetic, a wider row multiplier and
rounder; maximum storage may exceed a small target. Select dimensions from the
actual device budget. No synthesis, PnR, STA, board test or PPA was run.

## Reuse and evidence

Deep local review found existing signed-INT8 streamed dot, sparse matrix gather,
fixed CNN/systolic engines and a CE-qualified symmetric quantizer. None combines
resident packed weights, cached asymmetric input, runtime matrix dimensions and
per-row output scaling/zero with the transaction above. The existing arbitrary-
width RNE pipeline is reused unchanged as `rtl/deps/stream_requantize.v`; its
untracked original package remains untouched. This package records an exact hash
bridge and does not inherit historical physical qualifications for the new
composition. See [SOURCES.md](SOURCES.md).

From this package root, `files.f` is the full production closure;
`example/files.f` additionally elaborates the minimal8x64 dense-layer wrapper.
Both work offline. `python run_checks.py` performs only nine bounded Icarus
checks across1x1/TAG1,3x9/TAG8 and8x64/TAG16, plus maximum-shape syntax and example
syntax. Each child has a20-second limit and process-tree timeout cleanup; source
inputs/vectors are archived before execution. Raw receipts and logs retain the
first narrower-stall run and the final additional missing-later-word/full-pipeline
stall cases. Selected effective checks are listed in B33_DELIVERY.json.

The model uses Python arbitrary integers and `divmod`, independent of RTL
rounding. Coverage includes nibble sign/packing boundaries, non-power-of-two
dimensions, clipped/exact/inexact outputs, odd-zero half ties, full signed32 bias,
maximum scale/shift, persistent weights, invalidation, missing words/metadata,
dimension/index/opcode/framing errors, config arbitration, input gaps, output
stalls, cancellation during four live phases, and complete reconfiguration.
Maturity: **LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED**.
LINT_PASS here means Icarus syntax/elaboration only.
