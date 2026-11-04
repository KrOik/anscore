# Streaming four-direction gray-level run-length matrices

`streaming_glrlm` consumes unsigned grayscale pixels and builds four exact
gray-level run-length matrices (GLRLMs). Each bin counts **maximal consecutive
equal-gray runs**, rather than neighboring pixel pairs or encoded source runs.
This adds a texture descriptor for segmentation/classification pipelines.

Status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
Only the predetermined finite checks in `verification.json` are qualified;
128x128 is compile only. No synthesis, PnR, STA, board or expanded regression
runs here.

## Pixel and texture mathematics

Pixels are quantized to G=2^GRAY_W bins by keeping their most significant bits:

```text
gray = unsigned_pixel >> (PIXEL_W-GRAY_W)
```

This is exact floor quantization into uniform power-of-two bins, with no
round-to-nearest or floating point. All following run/count operations are
exact for that quantized image. Zero is an ordinary gray bin; no bin is a
reserved background or ignored label. There is no mask/ROI or external run
input, and no approximate length/count saturation.

With x increasing right and y increasing down, directions are:

| Code | Direction step |
| --- | --- |
| 0 | horizontal (+1,0) |
| 1 | vertical (0,+1) |
| 2 | diagonal (+1,+1) |
| 3 | antidiagonal (-1,+1) |

For direction d, P_d[g,r] counts maximal contiguous runs of gray g and actual
length r along every complete in-bounds line of that direction. Runs never
cross a row/line boundary and have no outside padding. Reversing a line gives
the same matrix. Every pixel belongs to exactly one run in each direction:

```text
sum_g,r r*P_d[g,r] = N = WIDTH*HEIGHT
R_d = sum_g,r P_d[g,r],   1 <= R_d <= N
```

Singleton directions are retained. For example, a 1x1 image contributes one
length-1 run in each of all four directions. A constant WxH image has H
horizontal runs of length W and W vertical runs of length H; both diagonal
directions have W+H-1 runs. No line crosses the image border or wraps columns.
There is no per-angle weighting, direction averaging, medical feature score,
normalization/division or PyRadiomics API compatibility claim. Raw matrices
and their exact run totals support downstream normalization or texture features.

## Framing, errors and ownership

All ports share one rising-edge clock, synchronous active-high `rst`, ordinary
ready/valid and no CE/CDC. Static WIDTH/HEIGHT require exactly N input transfers
in row-major order. `s_sof` is true only on the first pixel; `s_eol` is true
only at each last column. There is no LAST input, dynamic configuration,
framing resynchronization scan or missing-input timeout. Supply the remaining
fixed N transfers or reset. The source holds every field and valid until
acceptance. The first accepted pixel supplies the tag even with bad markers;
later tags and unexpected SOF cannot take ownership.

Independent sticky `m_errors` bits are bit0 for any SOF-position disagreement
and bit1 for any EOL-position disagreement. A bad frame still consumes all N
pixels and emits the complete dense matrix sequence, with **every count and
run total zero** and the first tag/all error flags on every record. All errors
are known before the first output. No prefix statistics are published. Pixel
values have no invalid unsigned encoding.

Output order is direction 0..3, gray 0..G-1, length 1..L where L=max(WIDTH,HEIGHT).
It emits D=4*G*L records, including zero bins and direction-impossible lengths.
`m_length` is actual length, not a zero-based index. `m_count=P_d[g,r]` and
`m_runs=R_d` for the current direction. `m_direction_last` marks that direction's
final bin; `m_last` marks the final bin of direction3. These are the only
completion markers. All valid fields remain stable during arbitrary output
backpressure. No next-frame pixel is accepted before final output retirement
and the complete histogram clear described below.

Reset gates ready/valid low immediately and cancels capture, history read,
histogram update, output read and held normal/error records at its active edge.
No cancellation output is emitted. Histogram banks clear at runtime after
reset and after final output; input remains stalled until clear finishes.
Line RAMs are not reset: row0 ignores all previous-row values, each current
word is written before future rows use it, and horizontal/diagonal boundaries
gate stale predecessors. Old output-read registers have no meaning while
invalid. A consumer discards partial matrix records if system reset occurs.

## Architecture, widths and budgets

| Parameter | Default | Legal range |
| --- | ---: | --- |
| WIDTH | 64 | 1..128 |
| HEIGHT | 64 | 1..128 |
| PIXEL_W | 8 | 1..16, unsigned |
| GRAY_W | 3 | 1..4 and <=PIXEL_W |
| TAG_W | 8 | 1..32 |

Let COUNT_W=max(1,clog2(N+1)), LENGTH_W=max(1,clog2(L+1)),
OW=max(1,clog2 L), pitch=2^OW and HDEPTH=G*pitch. COUNT_W represents N
(maximum 16,384, width 15); LENGTH_W represents L (maximum128, width8).
The histogram address concatenates gray and length-minus-one. Padded pitch
slots beyond L are cleared but never emitted. For L=1 pitch is2, retaining
well-formed one-bit offsets. All parameters derived in the port list are local.

There is no frame RAM. Three synchronous line memories store {gray,length}
for vertical, diagonal and antidiagonal prefixes, plus one horizontal register.
At x, the diagonal reads its old word before writing the current row, then
caches that **old** word for the next column's top-left predecessor. The cache
is excluded at x=0. The antidiagonal reads x+1, ahead of the raster write
frontier; the right border excludes that predecessor. Row0 excludes all three
previous-row states. These rules handle single rows/columns without stale reads.

Each direction has a separate synchronous histogram RAM. A new pixel either
starts a run or extends its predecessor of the same gray. First increment the
bin for the new prefix length. For an extension, then decrement the old prefix
length bin. Those addresses differ by one and both counts are updated in
separate READ/WRITE phases. This telescopes each unfinished chain to exactly
one provisional run; at a line boundary the last prefix is already the maximal
run, so no frame/row flush or second write is needed. A decrement always removes
an existing provisional run. Even before that decrement, temporary counts are
at most the number of pixels consumed, hence fit COUNT_W. No negative count,
same-address increment/decrement, read-during-write mode or hidden forwarding
is required. All four directions update in parallel using their own bank.

Logical RAM is

```text
4*G*pitch*COUNT_W + 3*WIDTH*(GRAY_W+LENGTH_W)
```

This is **28,544 bits** by default and **127,488 bits** at maximum, excluding
scalar/read/output registers. No external RAM, vendor primitive, runtime
multiply/divide or sibling RTL is used. Qualitative risk is **LOW** by default,
**MEDIUM** at maximum because of bank mapping, dense output volume and RAM
packing. Logical bits are not measured BRAM usage; LUT/FF/DSP counts, Fmax,
power and device fit are unmeasured.

Input II is exactly5 with a continuously waiting source during a frame:
accept/history read, calculate/new-bin read, increment, old-bin read, decrement.
Periods from final input transfer to first valid matrix record are exactly5,
including rejected frames. Always-ready output II is2; earliest transfer is
the next edge after visible valid. Four banks clear in parallel for HDEPTH
clocks after reset or final retirement. A waiting next frame can transfer one
edge after the last clear write. No input/output frames overlap.

From these schedules, the always-ready/continuously-offered first-input to
next-first-input interval is **5*N + 2*D + HDEPTH** periods: 25,088 at default,
100,352 at maximum. This is a structural cycle calculation, not a measured
continuous-service benchmark or clock-frequency claim. Finite TB checks II
lower bounds and exact5 tail latency. Source gaps and output stalls preclude
an unconditional wall-clock completion bound.

## Offline example and predetermined finite evidence

From this package directory:

```text
iverilog -g2012 -Wall -tnull -s streaming_glrlm -f files.f
iverilog -g2012 -Wall -tnull -s texture64 -f example/files.f
python -B run_tests.py
```

`example/texture64.sv` forwards all ports for default64x64/P8/G3/T8, giving
2048 dense texture records per frame. Both manifests contain only local
authored RTL. Root [LICENSE](../../../LICENSE)/[NOTICE](../../../NOTICE)
cover this original work; actual immutable source/license inspection is
recorded in [SOURCES.md](SOURCES.md). No external Python package or network is
needed for the finite checker or hardware integration.

Development note: the first production compile stopped because `bins` is a
reserved SystemVerilog coverage keyword. The memory identifier was renamed
`hist_mem`; the arithmetic/schedule and predetermined fixtures did not change.
The failed compile and its original source hashes are retained separately.

The independent oracle extracts whole geometric lines from boundary starts
and groups equal quantized values with Python itertools.groupby. It has no
streaming line RAM, old diagonal cache, prefix extension or increment/decrement
histogram. It checks pixel conservation and all dense fields, while a separate
N-minus-total-runs identity predicts the number of RTL extension transactions.
TB assertions check lengths, counter increment/underflow bounds, new/old bin
separation, held source/result stability, one-frame ownership and conservation
of each published direction.

The matrix was fixed **before the first tool run**: 9 simulation profiles,
900 main images, 21,702 pixels and 132,656 dense records. Single-pixel/row/
column, nonpower geometry, PIXEL_W1/2/3/4/8/12/16, GRAY_W1/2/3/4 and
TAG_W1/3/8/32 are covered. All256 two-bit2x2 images and all512 binary3x3
images are enumerated. Directed/random fixtures include constants, checker/
stripe/block patterns, diagonal/antidiagonal runs, full-width/height runs,
MSB quantization boundaries and ignored low bits, changed later tags,
independent/combined marker errors and next-frame recovery. The two maximum
single-axis profiles (128x1 and1x128) have exactly four fixed images each.
128x128/P16/G4/T32 is **compile only**; no full maximum-image numerical
simulation or video-rate benchmark is attempted.

Immediate reset probes cover all eight states, middle of histogram clear,
partial capture, each synchronous update phase, output read, held good/error
records with a real blocked next-frame offer, and bad-frame drain. No active
edge intervenes between observing a complete target and reset assertion.
Every cancellation is followed by a full fresh single-bright-pixel image and
all its dense matrix records, forcing clears, line-history reuse and both
prefix update paths. These finite examples are not exhaustive reset proofs.
Eleven illegal parameter combinations must fail by the named invalid instance.
Each compiler/simulator child has a20-second timeout; timeout stops the suite
and records an incomplete command separately, without automatic retry or
fixture reduction. Positive diagnostics fail. Temporary vectors/simulator
images are removed; source/vector/license hashes bind the actual evidence.
