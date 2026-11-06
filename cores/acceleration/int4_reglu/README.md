# Resident INT4 ReGLU projection

Two learned INT4 projections share one unchanged resident matvec and one cached
query. Interleaved rows provide a signed8 gate and value; ReLU on the gate,
elementwise multiplication and a final configurable signed8 quantizer form a
reusable gated feed-forward stage. Weights and branch/output quantization stay
resident across successive queries. The final down-projection of a complete MLP,
training, sigmoid/GELU, automatic model export and model accuracy are not supplied.

Current state: LINT_PASS + UNIT_SIM_PASS + INTEGRATION_CANDIDATE + HW_UNVERIFIED.
The one finite receipt in QUALIFICATION.md records 11 PASS children and four
successful simulations. No HDL profile was retried or repaired.

## Integer operation

For hidden element j and branch b=gate/value:

```
a[b,j] = S32(bias[b,j]) + sum_c((U8(x[c])-U8(x_zero))*S4(W[b,j,c]))
v[b,j] = sat8(RNE(a[b,j]*U16(scale[b,j])/2^shift[b,j])+S8(zero[b,j]))
y[j]   = sat8(RNE(max(0,v[gate,j])*v[value,j]*U16(out_scale[j])
                  /2^out_shift[j])+S8(out_zero[j]))
```

RNE rounds to nearest with exact half ties to even, including negative values.
Both zero offsets are added after rounding. The gate is rectified after its
signed8 projection quantizer; a clipped negative gate still reports branch clip
even though its product becomes zero. Output scale zero gives out_zero exactly.
This contract fixes all intermediate quantization and is not float ReGLU
equivalence. A model exporter must supply compatible scales/zero points.

## Parameters and ports

MAX_HIDDEN 1..32 (default8), MAX_COLS 1..256 (default64), TAG_W 1..32 (default8).
Named elaboration guards reject unsupported parameters. One rising-edge clock;
`rst` is synchronous high, takes priority and gates all public ready/valid low.
There is no CE, CDC, external memory, timeout or automatic retry.

All interfaces are ordinary ready/valid. A source holds valid and every payload
until transfer; outputs/configuration replies remain stable indefinitely while
stalled. Configuration has priority over a simultaneously offered command.
One command owns the operation through its final output retirement. The next
configuration or command can transfer on a later edge, never that same edge.

| Interface | Fields and meaning |
|---|---|
| c_valid/c_ready | 3-bit c_op; c_row/c_word unsigned16, c_branch1 |
| c_op=0 | Write packed INT4 weights for hidden c_row, c_branch (0 gate,1 value); nibble i of c_weights is column 8*c_word+i |
| c_op=1 | Set S32 c_bias, U16 c_scale, U5 c_shift and S8 c_zero for one branch row |
| c_op=2 | Invalidate all weights, branch metadata and output metadata; other fields ignored |
| c_op=3 | Set output metadata for hidden c_row from c_scale/c_shift/c_zero; branch/word/weights/bias ignored |
| c_op=4..7 | BAD_OP; no mutation |
| c_rsp_valid/c_rsp_ready/c_error | Held2-bit status:0 OK,1 index/word out of range,2 BAD_OP |
| cmd_valid/cmd_ready | cmd_hidden/cmd_cols unsigned16, cmd_x_zero U8, cmd_tag TAG_W |
| s_valid/s_ready | U8 s_data and s_last, exactly cmd_cols samples |
| m_valid/m_ready | S8 m_data, U16 m_index in ascending hidden order, TAG_W m_tag, m_last |
| m_error | 3-bit:0 ordinary,1 shape,2 missing branch config,3 LAST mismatch,4 missing output metadata |
| m_clip/m_inexact | Final quantization clipping and discarded nonzero bits |
| m_project_clip/m_project_inexact | OR of the two branch flags for this hidden element |
| m_gate_closed | Quantized gate <=0 for this element |
| busy | Command/configuration ownership; outside reset state!=IDLE |

Full c_row/c_word and command geometries are checked before indexing/truncation.
The last weight word's padding nibbles are ignored. All required output metadata
is checked first, followed by all required branch metadata/weight words in the
unchanged child. Error precedence is shape, output metadata, branch metadata,
then accepted LAST. Rewriting one configured word is allowed; it does not clear
other words. Configuration cannot interleave with a query or a held response.

Malformed LAST aborts immediately on the offending accepted sample, without
draining the source. The caller abandons that vector and waits for the error
marker to retire before a new command. Invalid shape/missing configuration
accepts no samples. Every error emits exactly one LAST marker, zero data/index
and zero numeric flags, with the query tag; none can emit an ordinary prefix.
Reset cancels active input, child pipelines and pending output, invalidates all
configuration and leaves RAM payload stale/unreachable. A consumer discards any
already delivered output prefix without LAST across reset.

## Architecture, latency and actual example

The original int4_weight_matvec is instantiated once with 2*MAX_HIDDEN rows:
row2j is gate, row2j+1 is value. A shared signed8x8 gate product and signed16x17
output scale operate in separate registered states. The unchanged requantizer
rounds through signed16 before adding output zero and saturating signed8; any
signed16 overflow remains outside signed8 after every possible zero offset.
There is no hidden-vector buffer or parallel MAC array. Matrix/query/output
metadata RAM payload is 4840 bits default and 68512 maximum; child branch
metadata, validity and scalar registers are additional. Risk MEDIUM. These are
structural bounds, not mapped RAM/DSP/area or hardware performance measurements.

Latency varies with shape and backpressure. Before accepting samples, output
metadata precheck takes h clocks and child branch precheck takes
2*h*ceil(cols/8) clocks, plus command handoff. Each branch performs synchronous
read and MAC for every column, followed by registered scale/quantization. A
gate/value pair then traverses registered product, scale and post-quantization.
The next pair can wait behind a held output, so no unconditional completion
deadline or full-rate streaming assertion is made. Results stay ordered.

[example/reglu32_input.sv](example/reglu32_input.sv) is an actual composition:
an unchanged signed32-to-signed8 elastic quantizer feeds the core through a sign
bit toggle, adding128, with x_zero fixed128. cmd_input_shift0..31 is captured
on command acceptance. One raw input may be pending; its LAST and flags persist
until the core accepts it. m_input_clip/m_input_inexact OR prefix flags over
accepted samples and stay constant during ordinary outputs; an early error has
zero flags, a malformed-input error retains flags of its accepted prefix. The
wrapper introduces input quantization and additional variable acceptance gaps.
Its reset cancels the occupied prefix slot together with the core.

Both source lists are relative to this package directory. Compile the top using
files.f, or the actual example using example/files.f. All dependencies are in
this repository; no network access, weights download or external runtime is
required. Read SOURCES.md for novelty/provenance and ARCHITECTURE.md for budgets.

The finite plan covers three core profiles including maximum geometry and the
actual prefix example, integer ties/sign/extremes, persistent rewriting,
configuration errors/priority/future offers, input/output gaps, held outputs,
and resets through owned states. It does not provide synthesis, PnR, STA, board,
PPA, model accuracy, whole-network or inherited regression evidence.
