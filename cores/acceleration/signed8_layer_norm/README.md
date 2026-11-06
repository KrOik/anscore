# Signed8 centered layer normalization

`signed8_layer_norm` keeps per-element affine parameters resident, captures a
runtime-length signed8 activation vector and emits centered, variance-scaled
signed8 activations. This supplies inference behavior absent from uncentered
L2 vector normalization. One vector owns the engine until its last result is
accepted. There is no external memory, CPU-computed normalization factor or
vendor primitive. Current state: LINT_PASS / UNIT_SIM_PASS /
INTEGRATION_CANDIDATE / HW_UNVERIFIED. The first finite invocation passed
11 children including4 simulations; exact scope is in QUALIFICATION.md.

## Exact staged integer contract

For N accepted samples x, epsilon E in squared input-code units:

```
S = sum(x[i]); Q = sum(x[i]*x[i])
C = N*Q-S*S
T = C+N*N*E
r = RNE(sqrt(T)*2^(FRAC+2))
z[i] = T==0 ? 0 : RNE((N*x[i]-S)*2^(2*FRAC+2)/r)
y[i] = sat_signed8(RNE(z[i]*gamma[i]/2^shift[i])+beta[i])
```

All operations up to r are exact integers. C>=0 by the exact central-moment
identity; the mean and population variance are never prematurely rounded.
RNE means nearest integer with exact ties to even, including negative values.
The square root and division introduce their stated staged rounding; output is
not asserted bit-identical to floating LayerNorm. A quantized model exporter
must choose E, gamma, beta and shift for the intended input/output scales.
Uniform input zero offset cancels in centering, but epsilon must remain in
squared input-code units. Runtime epsilon has no fractional bits.

Gamma and beta are signed16; shift0..31. Beta is added **after** RNE, which
matters at odd half ties. T=0 (constant vector and E=0) has explicitly defined
z=0 and returns sat8(beta) with `m_degenerate=1`. It is not a NaN behavior.
Constant vectors with positive E also return beta, with degenerate0. N=1 is
legal. The affine quantizer first clamps to signed32; a clamped value remains
outside signed8 after every legal beta, so final y/clip match the formula.
`m_inexact` reports discarded nonzero bits in the affine right shift only.
It is not a total numerical-error or root/division-exactness flag.

## Interface and ownership

One rising-edge clock, synchronous active-high public reset, ordinary
`valid && ready` everywhere. No public CE or CDC. The private unsigned
multiplier uses CE tied high and asynchronous low reset derived from !rst;
root/divider use matching synchronous low reset. Assert rst across an active
edge to cancel work. Public ready/valid are masked during rst; payload RAM is
not reset. Reset invalidates all affine rows and requires reconfiguration.
Every output field remains stable while valid and !ready.

| Config op | Accepted in idle, one held response |
|---|---|
| 0 | Write gamma/beta/shift to `c_index`; mark that row valid |
| 1 | Invalidate all affine rows; other fields ignored |
| 2,3 | Unsupported error, no mutation |

`c_error`:0 success,1 invalid row,2 unsupported op. Row fields are16-bit;
high bits are checked before indexing. Config has priority over a simultaneous
command. A config reply blocks both new configs and commands until consumed.
No row can be changed while a vector is active.

Command accepts `cmd_len`1..MAX_LEN, unsigned16 `cmd_epsilon`, opaque tag. A
precheck verifies all selected affine rows before admitting input. Exactly N
samples follow in order; `s_last` must equal index==N-1. Input gaps have no
limit. After a malformed LAST the core stops input immediately and returns
one error marker; caller stops that vector and replays a fresh command later.
There is no implicit drain or timeout. Unused higher rows do not matter.

Normal output has N beats in ascending `m_index`, first command tag, last on
N-1. `m_clip` means final signed8 saturation. `m_error`:0 normal,1 invalid N,
2 required affine row unconfigured,3 malformed input LAST,4 internal arithmetic
fault. Errors1..3 produce one zero data/index last marker, flags0, with the
command tag. Error4 terminates any already emitted prefix and requires caller
discard/replay; this unreachable-under-legal-input guard is not fault-injected.
Input payload has no externally visible partial output before capture closes.

Parameters: MAX_LEN1..256(default64), FRAC0..16(default12), TAG_W1..32(default16).
Illegal static configurations fail elaboration through an unresolved guard.
No parameter sweep, merged compile or inherited regression is requested.

## Storage and finite service

Affine storage is37*MAX_LEN bits, activation storage8*MAX_LEN bits, plus one
valid bit per row. Synchronous reads occur only in processing, writes only
in configuration/capture; no read/write collision is needed. Default RAM2880
bits, maximum11520 bits, excluding scalar registers/validity and helper state.
No initialization file or generated coefficient table is required.

Let C=ceil(log2(MAX_LEN)), SW=8+C, QW=16+C, UW=9+C, EW=18+2C,
RF=FRAC+2, RN=ceil((EW+2RF)/2), DN=UW+RF+FRAC. C=0 at MAX_LEN1.
S uses SW signed bits, Q uses QW unsigned bits, N*x-S uses UW signed bits,
T uses EW unsigned bits. All moment/affine magnitudes fit the shared32x32
unsigned multiplier. The signed8 square and bounded N*x use native narrow
operators; one serial CSA/fold product handles four moment products and each
affine product. There is no per-channel divider array.

Capture can accept one sample per edge after N precheck edges. Processing
blocks new input. A conservative source-derived budget, when output is ready,
is RN+DN+240 edges from the final input to first output acceptance, and DN+60
from one output acceptance to the next. Degenerate vectors also satisfy those
bounds. The finite TB checks the first-result bound for its core profiles;
backpressure/input gaps have no unconditional wall-clock completion bound.
These are logical cycle budgets, not measured Fmax or sustained hardware rates.

Risk MEDIUM: serial service time, wide arithmetic control and physical RAM/DSP
mapping. Device fit, area, timing, power and board behavior are unmeasured.
No synthesis, PnR, STA or board test is run.

## Actual pipeline example and offline use

`example/quantized_layer_norm.sv` connects unchanged `stream_requantize` for
signed32→signed8 to the normalization core. `cmd_input_shift` is latched per
vector. LAST travels in the quantizer tag; a single in-flight sample avoids
buffering suffix samples after an early-LAST abort. It accumulates separate
`m_input_clip/m_input_inexact` flags across accepted quantized samples. Its
capture is serialized through the elastic prefix and is not II1. Configuration
cannot change during the adapter's ownership. Reset also flushes the prefix.

Compile lists are relative to this package root: `files.f` for core,
`example/files.f` for the actual composition. All helper sources are retained
at tracked repository paths; no internet dependency exists. `FINITE_PLAN.json`
defines the only planned finite invocation. `run_checks.py` refuses existing
receipts, archives exact inputs/vectors/plan before tools, limits each child to
20s and stops after the first failure. Raw stdout/stderr and failed images are
preserved. Inspect qualification before invoking; do not replay automatically.
