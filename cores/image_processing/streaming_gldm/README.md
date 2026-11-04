# Streaming gray-level dependence matrix

`streaming_gldm` builds an exact local gray-level dependence matrix from an
unsigned grayscale raster. Two line histories and a small sliding window
replace a full-frame buffer. Every real pixel contributes once to a histogram
indexed by its quantized gray and the number of similar pixels in its clipped
3x3 neighborhood, including itself.

Status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
Actual qualification is recorded in [verification.json](verification.json):
33 current completed tool records, nine finite numerical profiles and eleven
named parameter rejections. The numerical matrix and maximum128x128
compile-only scope were fixed in advance. No synthesis, PnR, STA, board run or
expanded regression was performed. Earlier packages, including the area-opening
timeout and GLSZM maximum-square compile-only evidence, remain unchanged.

## Exact image and matrix contract

Quantization retains the GRAY_W most significant bits of each PIXEL_W-bit
unsigned input, equivalent to floor(pixel/2^(PIXEL_W-GRAY_W)). Gray0 is ordinary
data. The full WIDTH*HEIGHT rectangle is processed, without ROI or keep masks.
For center p with quantized value g, define

```text
d(p) = number of in-frame q with max(|qx-px|,|qy-py|)<=1
       and |gray(q)-g|<=alpha.
P[g,d] = number of centers p with gray(p)=g and d(p)=d.
```

The center always contributes one, so 1<=d<=9. The difference comparison is
inclusive and uses **quantized gray units**, not the original pixel units.
Alpha is unsigned GRAY_W bits: every encoding 0..2^GRAY_W-1 is legal. Alpha0
counts exact matches; maximum alpha admits every in-frame neighbor. There is
no transitive region growth: a neighbor is compared directly with the center.
Borders are clipped. Outside pixels, including internal invalid padding, are
excluded rather than treated as black, replicated, mirrored or wrapped.

Output is dense gray-major, then dependence1..9. Every zero and geometrically
unreachable bin is emitted. `m_gray`, `m_dependence` and `m_count` describe one
bin; `m_alpha` repeats the frame's alpha. `m_first` marks gray0/dependence1,
and `m_last` the highest gray/dependence9. There are exactly 9*2^GRAY_W records.
For a successful image, sum(P)=N and sum_d P[g,d] is the population of gray g.
The weighted sum sum(d*P) equals N plus the number of directed similar-neighbor
relationships. At maximum alpha it is N+R8, where R8 is the full in-frame
eight-neighbor degree sum. Counts are exact, with no rounding or saturation.
No normalized texture feature, inference or medical score is returned.

This is distinct from LBP's one-sided ring comparison code, GLCM's separate
neighbor-pair frequencies, GLRLM's directional linear runs, and GLSZM's maximal
equal-gray connected regions. Pair frequencies alone lose the joint number of
dependent neighbors at each center. See [SOURCES.md](SOURCES.md).

## Transfers, ownership and errors

One rising-edge clock, synchronous active-high `rst`, ordinary ready/valid and
no CE or CDC. Hold all source fields stable until acceptance. Ready is asserted
only for a real pixel slot; internally generated invalid padding never consumes
a source transfer. Exactly N real pixels are accepted in row-major order.
`s_sof` is true only on the first pixel and `s_eol` only on a final column.
There is no input LAST, dynamic geometry, resynchronization scan or missing-tail
timeout. A partial frame waits for the remaining real pixels or reset.

The first accepted pixel owns alpha and tag even if malformed. Later alpha/tag
values are ignored. Independent sticky error bits are bit0 SOF disagreement
and bit1 EOL disagreement. Errors neither restart nor shorten capture. The
entire fixed raster and internal bottom drain complete before output. Any
error produces all dense records with **every count zero**, retaining first
alpha/tag and both flags on every record. No prefix histogram is exposed.
Processing counters still include the actual input centers of rejected frames.

Every output field and valid remains stable under arbitrary backpressure.
No next-frame pixel is accepted during processing/output or subsequent full
histogram clear and invalid top/left warmup. A pending next frame is held until
the next actual source slot. Connecting older CE-qualified streams requires
an explicit adapter; port-name similarity alone is insufficient.

Reset immediately gates ready/valid low and must span an active edge. It
cancels partial capture, line/window work, histogram RMW, padding drain or held
output. No cancellation token is emitted. Consumers discard partial matrices.
RAM is not reset: every padded histogram entry is cleared before input; line
history from the first two internal rows is explicitly excluded; padding and
real writes overwrite both line histories before their qualified use. Window
registers reset, and two leading invalid columns flush horizontal history on
every row. There is no cross-reset partial-result retention.

## Widths, storage and schedule

| Parameter | Default | Legal range |
| --- | ---: | --- |
| WIDTH / HEIGHT | 32 / 24 | 1..128 each |
| PIXEL_W | 8 | 1..16, unsigned |
| GRAY_W | 3 | 1..4 and <=PIXEL_W |
| TAG_W | 8 | 1..32 |

N<=16384 and CW=max(1,clog2(N+1)) is at most15, representing the full N count
without wrap. Dependence and the balanced eight-bit popcount plus center use
four bits. Absolute gray difference is calculated by unsigned compare then
subtract in GRAY_W bits, covering 0..2^GRAY_W-1. Padded x/y widths contain
0..WIDTH+1 and 0..HEIGHT+1, including extent128. No runtime multiply/divide or
vendor primitive is used.

Two synchronous line RAMs have WIDTH+2 words of GRAY_W+1 bits (gray+valid).
Their separate read and window-update phases avoid read/write collisions.
Six small gray+valid registers retain the previous two columns of three rows.
Eight small absolute-difference/threshold units operate in parallel, followed
by a balanced popcount. A single synchronous histogram bank is read/modified/
written for each center, so repeated bins need no forwarding.

Histogram address is {gray,dependence-1}. Its padded depth is
HDEPTH=16*2^GRAY_W; only dependence1..9 is emitted, but all locations clear.
Logical RAM is `2*(WIDTH+2)*(GRAY_W+1)+HDEPTH*CW`: **1,552 bits** default,
**5,140 bits** maximum, plus window/read/control/output registers. There is no
frame RAM or external memory. Risk is LOW default / MEDIUM maximum as a
qualitative mapping/timing judgment; no measured LUT/FF/BRAM/DSP, Fmax, power
or device-fit claim is made.

Each internal padded position takes STEP, synchronous LINE_READ, and WINDOW.
A real center adds H_READ/H_WRITE. Real source II is3 or5 within a row, with
additional invalid row-edge steps. Always-ready output II is2. Clear takes
HDEPTH clocks, followed by automatic invalid top/left warmup before input.
For P=(WIDTH+2)*(HEIGHT+2), each frame has exactly P line reads/window updates,
N centers/histogram increments, and

```text
R8 = 2*HEIGHT*(WIDTH-1)+2*WIDTH*(HEIGHT-1)+4*(WIDTH-1)*(HEIGHT-1)
```

valid neighbor observations. The qualified exact final-real-input to first-valid
tail is `5*WIDTH+12+2*[HEIGHT>=2]*(1+[WIDTH>=2])`, including rejected frames.
It is176 default and at most656 periods. Per-frame window/center/neighbor/
matched-neighbor counters and each exact tail are checked independently by TB.
The no-stall first-input-to-next-first-input interval is structurally
`3*P+2*N+2*(9*2^GRAY_W)+HDEPTH`: 4,460 default and84,012 maximum. This is a
structural derivation, not a measured continuous-service benchmark. Arbitrary
source gaps or sink stalls prevent a wall-clock guarantee.

## Offline use and predetermined checks

From this directory:

```text
iverilog -g2012 -Wall -tnull -s streaming_gldm -f files.f
iverilog -g2012 -Wall -tnull -s dependence32 -f example/files.f
python -B run_tests.py
```

The local example forwards all ports at default32x24/P8/G3. One production
source and the wrapper form the complete offline manifest closure. New code
uses root [LICENSE](../../../LICENSE)/[NOTICE](../../../NOTICE); no external
Python package, downloaded implementation or sibling RTL is required.

Fixed numerical tuples (WIDTH,HEIGHT,PIXEL_W,GRAY_W,TAG_W): (1,1,1,1,1),
(1,7,4,2,3), (7,1,8,3,8), (2,2,2,2,8), (3,3,1,1,8), (8,5,8,3,8),
(32,24,12,4,8), (128,1,16,4,32), (1,128,16,4,32). Each has20 directed/random/
marker-error frames. All256 2x2 four-gray images at each of four alpha values,
and all512 binary3x3 images at both alpha values add2048 frames: **2228 total**.
Largest simulated area768 and axis128 do not qualify the maximum square.
128x128/P16/G4/T32 is compile-only from before the first tool invocation;
its numerical simulation is explicitly NOT_RUN.

The oracle directly enumerates each center's clipped coordinate-neighbor set,
using Python integers. It does not implement padding, line RAM, window columns
or the RTL schedule. Global/per-gray conservation, weighted dependence and
maximum-alpha geometry provide additional constraints. Fixtures include zero,
maximum, checkerboard, alpha0/max/intermediate, exact-cutoff and cutoff+1
neighbors, stripes, diagonal touching, corner singleton, blocks, low-bit
quantization, crosses, and first-alpha/tag freezing with varying later fields.
The TB additionally checks the complete eight-bit border-valid mask.

Reset probes cover all eight states, mid-clear, partial/error source capture,
actual held normal/error matrix with blocked next source, top-row warmup,
bottom/right drain and repeated-bin RMW. Targets reset immediately before any
extra active edge. Every recovery sends a complete bright-corner/dark-remainder
image at alpha=2^GRAY_W-2, checking every dense output and fresh line/window/
histogram work. There are13 probes at1x1 and15 elsewhere; recovery work is
separate from main counts.

Every compiler/simulator child has a20-second limit. Timeout stops the matrix
and is preserved as TIMEOUT/NOT_RUN, with retry, fixture reduction and timeout
increase forbidden. The runner checkpoints before and after each child. Any
ordinary initial failure is retained separately with commands/source hashes.
Eleven static illegal parameter configurations require the named rejection.

The current finite matrix passed2228 frames (2192 good,36 rejected),35152 real
input pixels and68976 dense outputs, with2228 exact tail checks. Observed work
was78744 line reads and window updates each,35152 centers and histogram
increments each,186088 in-bounds neighbor observations and145864 qualifying
neighbor relationships. Per-frame work matched the independent coordinate
oracle. Actual held cycles totaled87969 and blocked-source cycles612673.

All133 immediate cancellations completed133 fresh nonconstant recovery images,
outside the main counts:16378 additional input pixels and10224 dense records.
The maximum selected tail is652 at128x1, while the global structural maximum
is656; this does not qualify numerical operation at128x128 or measure a clock.

One initial ordinary syntax failure is preserved separately: the internal
identifier `matches` is a SystemVerilog reserved word. Only that exact RTL/TB
signal was renamed `match_bits`; the original version/failed-production
commands and original nine source hashes remain in `prior_failed_attempts`.
Those two historical tool records are excluded from the33 current qualified
records. The same matrix then passed without timeout, fixture reduction or
limit change. Afterward only README qualification/evidence prose and report
packaging metadata were completed; no qualified RTL/TB/runner/example/manifest/
profile/vector change or numerical rerun occurred.
