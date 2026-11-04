# Exact streaming neighboring gray-tone differences

`streaming_ngtdm` computes the neighborhood gray-tone difference matrix
(NGTDM) from raw grayscale pixels: for every center gray, the number of centers
and the sum of their absolute differences from the average of their neighbors.
It supports exact texture-statistic inputs without a frame buffer or host
neighborhood summaries. This mean-difference quantity differs from GLDM's
threshold-neighbor counts, GLCM gray pairs, GLRLM runs, GLSZM zones and entropy.

Status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
Only [verification.json](verification.json) qualifies the finite evidence.
No synthesis, PnR, STA, hardware or expanded
regression is authorized. Maximum-square numerical simulation is NOT_RUN.

## Exact statistic

Quantize each unsigned PIXEL_W sample by retaining its GRAY_W most significant
bits. Gray0 is ordinary. For center p with gray g, let V(p) contain all other
in-frame pixels in its3x3 neighborhood; k=|V(p)|. For every gray g emit:

```text
n[g]    = number of centers p with gray g and k>0
S120[g] = sum over those p of 120 * abs(g - sum(q in V(p))/k)
```

The center itself is excluded from the mean. Borders are clipped; no outside,
replicated or reflected samples exist. There is no ROI or missing-pixel mask.
Legal rectangular neighbor counts are0,1,2,3,5,8. Their nonzero LCM is120, so
the result is an exact rational statistic stored as an integer: divide S120
by120 to recover the difference sum. There is no approximation, rounding,
saturation, finite-result overflow or floating-point operation.

A1x1 image has k0 and contributes nothing: all counts and sums are zero.
All other legal rectangles have sum(n)=WIDTH*HEIGHT. Constant images have zero
differences. Empty gray bins are emitted with both fields zero. Output is dense
ascending gray0 through2^GRAY_W-1, including all zeros. `m_count` is n[g] and
`m_difference_120` is S120[g]. Full coarseness/contrast/busyness/complexity/
strength feature formulas and their nonlinear normalizations are not computed.

The isolated-center exclusion differs from the actual upstream C function;
no PyRadiomics API, dtype, ROI or medical-feature compatibility is claimed.
See the actual fixed-source and full-license preflight in [SOURCES.md](SOURCES.md).

## Frame and handshake contract

One rising-edge clock, synchronous active-high rst, ordinary ready/valid,
no CE or CDC. Accept only on valid&&ready; source holds all fields until
acceptance or reset. Static WIDTH*HEIGHT determines exactly N input transfers
in raster order. SOF must be true exactly at the first pixel, EOL exactly at
every row's last column. There is no last input, dynamic configuration or
resynchronization scan. Source gaps and sink stalls have no deadline.

The first accepted tag owns the frame, including malformed input. Later tags
are ignored. Sticky independent m_errors[0]/[1] record SOF/EOL mismatch.
Markers never restart or shorten capture. Any error consumes the complete
fixed raster and internal padding, then emits every gray bin with count and
difference zero. Both flags may combine. Output m_first/m_last delimit the
dense vector; gray, fields, flags and tag stay stable under arbitrary stall.
No new input is accepted until the complete response retires and histogram
clearing/padding preparation completes.

Reset immediately gates ready/valid low and cancels capture, line work,
arithmetic, histogram updates and held output at its active edge. RAM is not
reset. Histogram bins are serially cleared before accepting new pixels. Initial
line rows are explicitly invalidated and two left padding columns flush stale
window words; every consumed real pixel belongs to the new frame.

## Widths, scheduling and resources

W/H1..128, PIXEL_W1..16, GRAY_W1..4 and <=PIXEL_W, TAG_W1..32.
Defaults32x24/P8/G3/T8. Parameters are static, with no memory map, external RAM,
vendor primitive, generated ROM or sibling dependency.

CW=max(1,clog2(N+1)); SUM_W=max(1,clog2(N*120*(2^G-1)+1)). Maximum neighbor sum
and k*g are8*(2^G-1), held in G+3 unsigned bits. Their absolute difference fits
the same width. Per-center scaled difference is at most120*(2^G-1), needing
clog2(120*(2^G-1)+1) bits. Count/sum widths are10/20 default,15/25 maximum.
All constant-scale intermediate positive sums fit that per-center bound.

Two synchronous gray+valid line RAMs of W+2 words produce a padded3x3 window.
Six window words plus registered current column complete it. Balanced trees
sum eight gray values and valid bits. WINDOW captures k*g and neighbor sum,
ABS_DIFF takes the magnitude, SCALE uses constant shifts/adds for120/k, and
histogram read/write accumulates one packed count/sum word. All reads and
writes occupy distinct phases, so no RAM read-during-write mode is assumed.
Repeated gray bins use completed serial read-modify-write operations.

States: CLEAR, STEP, LINE_READ, WINDOW, ABS_DIFF, SCALE, H_READ, H_WRITE,
OUT_READ, OUT_HOLD. Each padded grid point takes3 periods plus4 when it emits
an eligible center, or plus2 for the isolated1x1 center. Interior input II is7;
warmup input II is3, with row-padding work between lines. Output II is2 when
always ready. After accepted final real pixel E, first output is visible after

```text
7*WIDTH + 12 + 4*[HEIGHT>=2]*(1+[WIDTH>=2]) - 2*[N==1] periods.
```

This is244 default, at most916, and17 for1x1. It includes bottom/right drain,
arithmetic and output read, and is unchanged by bad markers. First transfer is
on the following edge. Missing inputs/held outputs add unbounded wait.

Ignoring waits, reset-to-next-frame preparation uses at most
2^G + 3*(W+2)*(H+2) + 4*N - 2*[N==1] + 2*(2^G) periods per frame. This
structural count is5748 default and116284 maximum. It includes histogram clear, all padded grid work and dense
outputs; it is not a measured board throughput or frequency claim.

RAM bits =2*(W+2)*(G+1) + 2^G*(CW+SUM_W):512 default,1940 maximum, excluding
scalar/window/read registers. There is no runtime multiplier or divider.
Qualitative architecture risk is LOW default and MEDIUM maximum because the
adder/select paths and RAM packing need physical evaluation. No LUT/FF/BRAM,
DSP, Fmax, power or board measurements are claimed.

## Offline finite checks

[files.f](files.f) is the single-source core closure;
[example/files.f](example/files.f) adds ordinary-ready/valid `neighborhood32`.
Manifests are relative to this package. CE-qualified streams need an adapter.
Python standard library and the existing native repository Icarus/vvp suffice
offline. Run `python run_tests.py` from any directory.

[TEST_PLAN.md](TEST_PLAN.md) freezes nine profiles,948 frames/27472 pixels and
3568 bins, maximum128-square compile-only, eleven named parameter rejects and
reset targets before any compiler/simulator call. Each child is limited to20s.
Any timeout is terminal with no retry, fixture shrink or increased timeout.
Ordinary failures retain their original tool records and source hashes.

The independent Fraction oracle uses direct clipped coordinates, with no line
recurrence or padding. TB checks each actual window's center/count/neighbor sum,
both arithmetic stages, committed histogram updates, dense fields, tags/errors,
hold/retirement, per-frame work and exact tail. Reset targets are observed and
canceled at a negedge before another active edge, followed by a complete
analytic bright-corner frame including hold/retirement/no-stale checks.
Geometry-specific unreachable targets are explicitly skipped. Main evidence
counts exclude setup/reset/recovery; internal aggregate monitor counters and
held/source-stall cycles include that traffic. Finite evidence does not imply
exhaustive parameter correctness or hardware readiness.

The first attempt completed all33 planned commands without failure or timeout:
one version query, three syntax checks (core/example/max square), nine compile/
simulation pairs and eleven expected parameter rejects. All948 main frames
(912 good/36 bad) produced27472 input and3568 dense output checks, including
3568 exact Fraction-derived difference checks and948 exact tail checks. The
tails by profile are17,23,61,34,41,76,244,908,23 periods. Global maximum916 is
an algebraic bound; maximum-square numerical behavior is not measured.

The main center work comprises27472 centers,27452 eligible histogram updates,
156392 neighbor observations,10386 fractional means and13987 nonzero center
differences. Neighbor counts0/1/2/3/5/8 occur20/160/5240/3392/4568/14092 times.
Main work includes bad-frame computation before output masking. Reset counts
are12/18/18/18/17/18/18/18/18, totaling155 immediate cancellations and155
complete fresh recoveries. At1x1 the partial-capture, histogram and repeated-
update targets are unreachable. At G1 the two-bin clear's second entry is
already its final entry, so the separate middle-clear target is omitted.

Aggregate internal monitors, including reset setup/recovery and canceled
prefixes, checked106509 grid points,58003 centers and57925 committed updates;
12545 held cycles and349089 source-stall cycles use the same inclusive scope.
These totals differ deliberately from main-frame evidence. No numerical check
was rerun after completion; final changes only qualify documentation and bind
its new hash while preserving all implementation/test/fixture hashes.
