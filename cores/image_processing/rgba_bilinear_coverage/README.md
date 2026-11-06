# Coverage-correct bilinear RGBA filtering

`rgba_bilinear_coverage` filters four straight-alpha ARGB texels into one
premultiplied RGBA sample, preserving full alpha/color/weight products until
one final round-to-nearest-even (RNE). Transparent texels cannot introduce
colored fringes. The actual example performs four dependent resident indexed
texture reads, filters them, then uses the unchanged Porter–Duff core to
compose the result with a supplied premultiplied destination.

Baseline: `50b8d36a3ce65cae5c4b3ab4604fa24f3567204b`. New code is original
Apache-2.0. Status is SOURCE_ONLY / NOT_RUN / HW_UNVERIFIED until the exact
root and peer gate authorizes the frozen finite plan. This README is a
pre-execution specification, not an execution receipt.

## Exact numerical contract

Core `s_00,s_10,s_01,s_11` are straight `{A8,R8,G8,B8}`; indices are x-first,
then y. `s_fx,s_fy` are unsigned fractions 0..255 with denominator256. Define
weights `[(256-fx)*(256-fy), fx*(256-fy), (256-fx)*fy, fx*fy]`. Their exact
sum is65,536; individual weights can equal65,536 and require17bits.

For each accepted request:

```
A = RNE(sum(weight_i * alpha_i) / 65536)
C = RNE(sum(weight_i * alpha_i * color_i) / (255*65536))
```

Output is premultiplied `{R8,G8,B8,A8}`. All input bytes are legal; straight
RGB may exceed alpha. Output RGB never exceeds output alpha because RNE is
monotone and each unrounded RGB is bounded by unrounded alpha. No gamma,
color-space conversion, straight-output unpremultiplication, perspective
division, mipmapping, area/minification antialiasing or anisotropic filtering
is performed. The caller defines the byte color space.

This differs from independently interpolating straight RGBA, and from first
rounding each texel to premultiplied8bit. For example a left texel with A1/R128
and transparent black on the right, fx64/fy0, gives premultiplied R0/A1 here;
rounding the left premultiplied R to1 first would instead give R1/A1.

One clock, synchronous active-high reset, ordinary ready/valid, no CE/CDC.
TAG_W is1..32. Destination x/y16 and opaque tag are latched and forwarded.
Sources hold all offered fields while blocked. One token is owned from input
acceptance until final output retirement. Output and metadata remain stable
under unbounded sink stalls; no next request or same-edge fallthrough is
accepted. Reset cancels computation and held output and masks ready/valid.

## Actual indexed-texture composition

`example/indexed_bilinear_porter_duff.sv` instantiates unchanged
`indexed_texture_sampler` and `rgba_porter_duff`, plus this filter. Texture
dimensions independently1..256, default8x8; TAG_W1..32. Compile source lists
relative to this package directory, including `example/files.f`.

Public `s_u,s_v` are unsigned Q8.8 texel coordinates: upper8bits select the
base, lower8bits select the fraction. In-range bases read all four neighbors,
with the right/bottom neighbor clamped to the last texel; duplicates are read
normally. A base outside the texture reads no texture location and supplies
transparent zero to the filter. Every query produces one output, and `m_oob`
reports that base-range condition. At256x256 every representable base is in
range; this profile cannot exercise base OOB. Destination coordinates do not
affect texture access. Negative/wrapped/normalized UV are unsupported.

`s_dst` and output are premultiplied `{R,G,B,A}`; `s_mode` is unchanged
Porter–Duff mode0..12. Invalid modes return error1 and transparent zero;
invalid premultiplied destination returns error3 and transparent zero, with
mode-error priority. Filtered source cannot trigger source-error2. Output
mode, coordinates/tag and OOB indication stay with the owned query. OOB or
transparent texture samples still run composition: destination-preserving
operators can return a nonzero result.

Management and independent texture/palette loading reuse the sampler's
BEGIN0/PUBLISH1 protocol and held status/count response. Palette input is
straight `{A,R,G,B}`. BEGIN resets load counters; successful publication
requires exactly W*H index bytes and256 palette entries. Early PUBLISH leaves
the load active with status1; PUBLISH outside loading gives status2;
unsupported management operations give status3. New complete load epochs
replace residents; RAM payload is not reset. A shared reset invalidates the
resident texture and cancels pending load, management and render ownership.

Pending management immediately blocks new queries. It is forwarded to the
sampler only after the entire owned query retires, including lookup gaps,
filter computation and held final composition output. This prevents a pending
BEGIN from blocking the four reads of an already accepted query. Management,
texture and palette readiness stay low throughout that owner. A held
management response blocks new queries. Missing load data or unbounded output
backpressure has no unconditional completion bound.

## Resource and cycle budget

The filter time-shares one unsigned17x17 multiplier through four weights,
four weighted-alpha terms, twelve alpha×color products and twelve weighted
color products:32 multiplications per sample. Multiplication and accumulation
occupy separate states. One indexed32bit color accumulator adder and24bit
alpha adder retain exact sums. The final /255 fold and full remainder test
use shifts, subtraction and comparisons, with no runtime divider or ROM.
Logical register payload is441+TAG_W bits before synthesis; there is no core
RAM. The wrapper adds250+TAG_W register bits and reuses the existing sampler
RAM and composition pipeline. Logical sampler RAM is8704bits at8x8 and
532,480bits at256x256, before packing or pruning. One multiplier expression
does not establish physical DSP inference. Default storage risk LOW/MEDIUM;
maximum storage HIGH. Logic/control/timing risks remain unmeasured.

With no stalls the core exposes valid69 edges after acceptance, retires on
edge70 and admits the next request on edge71. The wrapper exposes valid89
edges after an in-range acceptance (four sequential lookups), or73 for OOB;
earliest retirement is90/74, next acceptance91/75. Load, management and stalls
add cycles. This is a sparse low-area transaction service; dense scanout rate,
MHz, physical RAM fit, resource totals and power have not been measured.

## Frozen finite scope

Five separate archived Python preparations precede every HDL child. Planned
HDL work is two syntax checks and five compile/simulation pairs: core TAG1/32,
then actual1x1/TAG1,5x4/TAG8 and256x256/TAG32 compositions. Each core profile
scores268 directed/deterministic-random results, including half ties, hidden
transparent colors, constant fields and extrema; six live reset fixtures
cover arithmetic and held output, with six separately scored recovery outputs.
Each wrapper profile scores two complete vector epochs (1176 queries), all13
legal composition modes, invalid mode and malformed destinations, subtexel
fractions, clamped edges, sparse/full-domain UV, pending management and held
outputs. Four live reset fixtures cover reads, filtering, composition and
held output; each is followed by a fresh complete texture/palette load.
The maximum profile loads all65,536 indices six times, but only samples sparse
queries: it does not render a full image or prove sustained video service.

Per-core main holds1072; per-wrapper main holds4704. Wrapper management
responses58 and held-response cycles174 include fixture traffic;38 pending
management offers span owned queries. Resets and fixture outputs are reported
separately from main scored cases. Each TB also holds one future request valid
through calculation and four held-output cycles, rejects same-edge retirement
fallthrough, then checks its later acceptance and result: two additional
results, eight holds and73(core)/93(wrapper) blocked cycles, separately counted.
There is no inherited regression, combined
repository compile, synthesis, PnR, STA, SDF, board or PPA step.

Execution needs exact source/plan/seal hashes and named root+peer proof. The
runner archives source bytes and controls, then durably records child PID,
exit state and raw streams before parsing markers/receipts. Every preparation
or HDL child has20s, taskkill helper5s and one shared2s exit/reader interval.
No automatic retry; an execution lock or any report directory blocks a new
attempt. Executed input bytes and raw evidence remain frozen.
