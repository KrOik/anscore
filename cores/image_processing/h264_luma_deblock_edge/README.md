# Eight-bit H.264 luma deblocking boundary

`h264_luma_deblock_edge` filters one eight-sample boundary neighborhood
`p3 p2 p1 p0 | q0 q1 q2 q3` per transaction. It implements the H.264 luma normal
and strong boundary equations with externally derived boundary strength and
thresholds. The result includes all eight samples, an exact changed indicator,
an error bit, a tag and a pass-through end marker. This adds codec-boundary
filtering beyond generic blur, edge detection, quantization and image resizing.

Original Apache-2.0 portable RTL. All production dependencies are in `files.f`;
the complete exposed-port example is in `example/files.f`. Resolve **both lists
from this package root**. No generator, coefficient file, external RAM, vendor
primitive or third-party source is required for use. `LICENSE` is included.

## Interface and schedule

All ports share the rising edge of `clk`. `rst` is synchronous active-high and
has priority over input/output transfers; it clears the pending result and all
output fields at that edge. Consumers must discard a pending result when reset
is asserted. There is no CE or CDC. Transfers are `valid && ready` on non-reset
edges. Producers hold valid and every payload bit until transfer.

`s_pixels[8*i+:8]` maps lane0..7 to `p3,p2,p1,p0,q0,q1,q2,q3`. Pixels are
unsigned8 values0..255. The input also carries `s_bs[2:0]`, unsigned thresholds
`s_alpha[7:0]`, `s_beta[7:0]`, and unsigned `s_tc0[4:0]`:

| Boundary strength | Result |
| --- | --- |
| 0 | Exact bypass, no error; thresholds ignored |
| 1..3 | Normal clipped-delta luma filter using the supplied `tc0` |
| 4 | Strong luma filter; `tc0` ignored |
| 5..7 | Exact bypass with `m_error=1` |

All threshold bit patterns are supported by this arithmetic interface. For
normative H.264 use the caller must derive alpha/beta/tc0 from QP, offsets and
the strength-specific tables. Strengths1..3 share this arithmetic kernel;
their table-derived tc0 values provide their different correction limits.
Alpha0 or beta0 causes the strict gate to reject filtering. There is no runtime
configuration state: all thresholds are sampled with their own neighborhood.

`s_tag[TAG_W-1:0]` and `s_last` are copied unchanged to `m_tag` and `m_last`.
`TAG_W` supports every integer1..32, default8. Invalid parameters elaborate a
named missing module. Tags and LAST are opaque; LAST does not reset internal
state, flush a frame or check geometry. No external memory interface or frame
buffer exists. The caller supplies oriented neighborhoods, schedules overlapping
edge updates and owns writeback hazards. Horizontal and vertical filtering use
the same neighborhood ordering; this core does not fetch or transpose pixels.

`m_pixels` contains the filtered samples; `m_error` reports only invalid strength.
`m_changed` is exactly `m_pixels != accepted_s_pixels`, including zero on invalid
strength bypass. `p3/q3` are always unchanged. Every valid output field remains
stable under arbitrary sink stalls. A single elastic register permits a new
input on the same edge that retires an old result; `s_ready=!m_valid||m_ready`
outside reset. An input accepted on edge n produces output-valid after edge n,
and its earliest output acceptance is edge n+1. With continuous valid/ready it
accepts one neighborhood per cycle after reset. Output stalls can be unbounded,
so there is no unconditional transaction-completion deadline. This is a clock
schedule description, not measured FPGA throughput or timing.

## Exact arithmetic

Every equation uses **the original input samples**. Define

```text
gate = |p0-q0| < alpha and |p1-p0| < beta and |q1-q0| < beta
ap   = |p2-p0| < beta
aq   = |q2-q0| < beta
near = |p0-q0| < floor(alpha/4)+2
clip(v,L) = min(L,max(-L,v))
u8(v) = min(255,max(0,v))
```

Strength0, invalid strength and a false gate preserve every sample. For a true
gate and strengths1..3:

```text
tc = tc0 + ap + aq
delta = clip(floor((4*(q0-p0)+p1-q1+4)/8),tc)
p0' = u8(p0+delta)             q0' = u8(q0-delta)
avg = floor((p0+q0+1)/2)
if ap: p1' = u8(p1+clip(floor((p2+avg-2*p1)/2),tc0))
if aq: q1' = u8(q1+clip(floor((q2+avg-2*q1)/2),tc0))
```

For a true gate and strength4, each side chooses independently. If `near && ap`:

```text
p0' = floor((p2+2*p1+2*p0+2*q0+q1+4)/8)
p1' = floor((p2+p1+p0+q0+2)/4)
p2' = floor((2*p3+3*p2+p1+p0+q0+4)/8)
```

Otherwise only `p0'=floor((2*p1+p0+q1+2)/4)`. The q side exchanges p/q in
these equations and uses `near && aq`. Unassigned samples retain their values.
Strict comparisons apply at every equality boundary. Signed division rounds
towards negative infinity, implemented with arithmetic right shifts; it does
not truncate towards zero. The displayed positive rounding constants are part
of the equations. No floating point, tolerance or fixed-point scale is used.

Signed12-bit arithmetic covers the normal correction numerator -1271..1279
and every side update. The limit is0..33. Strong weighted sums plus rounding
are0..2044, fitting unsigned11 bits. Their weights preserve the unsigned8
output range. Output pixel clipping applies to normal corrections, without
wraparound at either rail.

## Architecture and risk

This is one bounded combinational arithmetic cone followed by one elastic
output register: comparisons, additions, constant shifts and clamps. There
are no pixel multipliers, frame/line arrays, variable-length loops, iterative
controller or generated lookup tables. TAG_W changes only tag storage/wiring.
The single-stage combinational path includes gate selection, signed correction
and clipping, so **architecture risk MEDIUM** for high target clock frequencies.
One neighborhood per RTL cycle does not prove a target clock is achievable.
No device fit, resource count, frequency, power or physical throughput has been
measured. A future integration may pipeline the arithmetic if required.

## Finite checks and evidence

From the repository root:

```powershell
python -B cores/image_processing/h264_luma_deblock_edge/run_tests.py
```

The runner copies the exact executable inputs into each timestamped report
**before any compilation or reference preparation**, hashes the originals,
and verifies they remain unchanged. It finalizes the runner before checking.
Each Icarus/vvp child uses an absolute tool path, a20second process deadline,
Windows process-tree termination or POSIX process-group termination, and bounded
cleanup. Missing executables record `NOT_RUN`; failure or timeout stops later
launches. Raw stdout/stderr, command lines, source/tool hashes and generated
input/golden vectors are retained. Simulator binaries stay in ignored `.build/`
for root-owned post-delivery cleanup. `.gitattributes` preserves source bytes.

The fixed finite suite compiles the RTL and example, prepares652 deterministic
neighborhoods once, then checks TAG_W1,8,32. Every profile checks all vectors
under input gaps/output stalls and again with continuous valid/ready, including
one-result-per-cycle behavior. It checks every output byte, tag, LAST, error,
changed indicator, stall stability, reset of a held result and complete recovery.
Fixtures include all strength encodings, zero/max thresholds and tc0, strict
threshold equalities, all ap/aq combinations, normal signed corrections of both
signs, clipping, asymmetric strong modes and seeded arbitrary/correlated pixels.
The independent Python reference uses lists, tuple dot-products and integer floor
division; hand-derived anchors check representative normal and strong outputs.
Branch counts describe **reference fixture coverage**, not internal RTL coverage.

Current status and exact observed results are in `QUALIFICATION.json` after the
bounded checks. Finite simulation cannot establish complete H.264 conformance,
all codec scheduling or exhaustive input-space coverage. This package does not
implement chroma filtering, QP/strength derivation, bitstream decoding, macroblock
order or a full encoder/decoder. Hardware maturity remains `HW_UNVERIFIED`;
synthesis, placement/routing, STA and board execution are `NOT_RUN`.

Actual qualification: the initial production/example compiles passed, but the
first TB compile rejected task name `sequence`, a SystemVerilog keyword. The
runner stopped before simulation and retained exact source copies and raw logs.
Only that task name and its calls changed to `run_stream`. The explicit saved
HDL-only continuation reused the same652input/golden vectors without repeating
the reference preparation; TAG_W1,8,32 each passed1304checked transactions across
the stalled and continuous phases. Total execution was9HDL children:8PASS and
the preserved initial compile failure. Exact source/vector/log hashes were
rechecked before qualification. Status is `LINT_PASS + UNIT_SIM_PASS` for this
finite scope, with `HW_UNVERIFIED`. The three TB compiles emit only a missing
explicit RTL timescale warning; production contains no delays. Process-timeout
cleanup and the missing-tool branch have source review, not runtime evidence.

### Source-reviewed outcome gating revision

After the recorded HDL checks, independent review identified that an exception
during reference preparation could leave two successful syntax checks and let
the old main runner label that incomplete receipt PASS. The delivered runner now
requires successful preparation, the exact ordered eight check names, an explicit
completed-suite flag, unchanged sources and PASS from every child. Each simulator
must also emit its expected TAG_W/vector/checked-count completion marker; exit0
alone is insufficient. The one-time HDL continuation likewise requires the exact
ordered six checks, a completed-suite flag and those simulator markers.

These outcome-only changes did not modify RTL, TB, the reference equations,
fixtures or saved vectors. Exact previously executed helpers are retained at
`history/run_tests.executed.py.txt` and `history/continue_hdl.executed.py.txt` and
remain bound by the original receipts. The final helpers received AST parsing
and source review only; their new runtime behavior is **NOT_RUN**. No preparation
or HDL was repeated. `reports/OUTCOME_GATING_REVIEW.json` maps executed to current
helper hashes. The one-time continuation is a historical execution path with
original-source guards; use `run_tests.py` for future complete checks.
