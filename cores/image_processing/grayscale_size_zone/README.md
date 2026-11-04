# Exact gray-level size-zone matrix

`grayscale_size_zone` counts maximal connected regions of equal quantized
grayscale in a real raster. Its matrix P[g,s] is the number of zones with gray
level g and exactly s pixels. This is useful for spatial texture and region-size
distributions. It does not calculate a medical score or normalized feature.

Status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
The first predetermined matrix completed: 34 qualified tool records, nine
numerical profiles and 12 named parameter rejections. Actual receipts are in
[verification.json](verification.json). No synthesis, PnR, STA, board run or
expanded regression was run. The maximum 32x32 square is compile-only by the
predetermined budget; it is not part of the nine numerical profiles.

## Image and matrix contract

Each unsigned PIXEL_W-bit input is quantized by retaining its GRAY_W most
significant bits, equivalent to floor(pixel/2^(PIXEL_W-GRAY_W)). Every pixel
belongs to the full rectangular image. Zero is an ordinary level, with no ROI,
background exemption, threshold or keep mask. Connectivity is a static 4 or 8:
four axial neighbors, optionally the four diagonals. Neighbors outside the
rectangle are excluded; rows never wrap. A zone is the maximal connected set
of pixels having one exact quantized value, not an upper-level component.

There is one matrix for the image. For N=WIDTH*HEIGHT, every successful frame
has 1<=zones<=N and satisfies:

```text
zones = sum_g sum_s P[g,s]
N     = sum_g sum_s s*P[g,s]
sum_s s*P[g,s] = number of input pixels quantized to g.
```

Output is dense gray-major, then size=1..N, including every zero and unreachable
bin. `m_gray`, `m_size` and `m_count` describe that bin; `m_zones` repeats the
global zone count. `m_first` marks gray0/size1 and `m_last` the maximum gray/N.
There are exactly 2^GRAY_W*N output records even when the image is constant.
No floating-point normalization, division, clipping, tolerance or iteration
limit is used. Different 4/8 connectivity can produce different exact matrices.

Existing binary CCL emits labels/bboxes for foreground components; area opening
filters grayscale upper-level sets; GLCM counts neighbor pairs; GLRLM counts
linear runs in four directions. None provides this equal-gray connected-zone
size distribution. Existing exact L1/Linf and Euclidean distance maps were
also inspected and excluded from new work. See [SOURCES.md](SOURCES.md).

## Clock, frame ownership and errors

All transfers occur on the rising edge of one clock with ordinary valid/ready.
`rst` is synchronous active high and immediately gates ready/valid low. There
is no CE or CDC. Input fields must remain stable until their handshake.
Connecting older CE-qualified streams requires an explicit adapter.

Static geometry defines exactly N accepted pixels in row-major order. `s_sof`
must be true only on the first pixel; `s_eol` only on each actual final column.
No LAST input or resynchronization scan exists. A partial frame waits for its
remaining pixels or reset. The first accepted pixel owns `s_tag`, even when its
markers are malformed; subsequent tags are ignored.

Independent sticky error bits are bit0 SOF mismatch and bit1 EOL mismatch.
Errors do not shorten capture or restart the frame. After all N pixels have
arrived, any error produces the complete dense output with **every count and
the global zones zero**, preserving the first tag and both error flags on every
record. No partial valid matrix is exposed. Output markers/indices come from
geometry and are independent of malformed input markers.

The frame owns the service until the final dense result is accepted, then the
entire padded histogram is cleared before any next input is accepted. Input
cannot overlap matrix processing, a held result, or histogram clearing. A next
frame offered early remains blocked. All output fields and valid stay stable
under arbitrary backpressure. Fields outside valid have no payload meaning.

Reset cancels capture, traversal, histogram update, clear or output without
emitting a cancellation record. Consumers discard a partly received matrix.
Control returns to histogram clear. Pixel RAM is fully overwritten by the next
capture, including visited=0; FIFO entries are written and marked before being
read, and the full histogram clear makes old counts unreachable. There is no
bulk RAM reset or cross-reset transaction/partial-result retention.

## Architecture, widths and service

| Parameter | Default | Legal range |
| --- | ---: | --- |
| WIDTH / HEIGHT | 16 / 16 | 1..32 each |
| PIXEL_W | 8 | 1..16, unsigned |
| GRAY_W | 2 | 1..3 and <=PIXEL_W |
| CONNECTIVITY | 8 | 4 or 8 |
| TAG_W | 8 | 1..32 |

Let IW=max(1,clog2 N), XW=max(1,clog2 WIDTH), CW=max(1,clog2(N+1)) and
HDEPTH=2^(GRAY_W+IW). Source/visited packed words have GRAY_W+1 bits, FIFO
words hold IW-bit address plus XW-bit x, and histogram entries have CW bits.
CW represents N exactly, including power-of-two geometry; addresses only
truncate head/tail when a proven nonempty queue read or new push uses <N.
Histogram address is {gray,size-1}, with padding cleared but never emitted.

A raster seed scan reads the packed pixel RAM. Every unvisited seed starts
one FIFO traversal; an equal-gray neighbor is marked visited on the same edge
that appends its coordinate, before any other neighbor can inspect it. Each
pixel therefore enters exactly one zone and is enqueued/popped once. The FIFO
has N entries, including the all-constant full-frame zone. After a queue empties,
one histogram RMW increments P[gray,zone_size], then scanning resumes.

Three independent synchronous memories store packed pixels, FIFO and histogram.
Each read is consumed in a following state; reads and writes to the same memory
occur in different phases. No RAM collision mode or forwarding is required.
Vertical neighbors use address +/-WIDTH and explicit x bounds; diagonal checks
combine both row and column bounds. There is no runtime multiplier, divider,
label table, output-frame store, vendor primitive or external RAM dependency.

Logical RAM is N*(GRAY_W+1+IW+XW)+HDEPTH*CW: **13,056 bits** by default and
**109,568 bits** at 32x32/GRAY_W3, plus scalar/read/output registers. Default risk
is LOW, maximum MEDIUM due to RAM packing and serialized work. These are
architecture judgments, not measured LUT/FF/BRAM/DSP/Fmax/power/device fit.

Input II is 1. Always-ready dense output II is 2. Histogram clear takes exactly
HDEPTH clocks after reset and after final result retirement. For connectivity K,
let R be the sum of in-bounds neighbor degrees over all pixels:

```text
R4 = 2*HEIGHT*(WIDTH-1) + 2*WIDTH*(HEIGHT-1)
R8 = R4 + 4*(WIDTH-1)*(HEIGHT-1).
```

The exact tail-to-first-valid formula for a good image with Z zones is
`(K+4)*N + 2*R + 3*Z + 1`; errors take 1. The finite TB checks it independently
for every main image together with N seed scans, N pops, K*N neighbor decisions,
R in-bounds visits and Z histogram increments. Structural tail bounds use Z<=N:
7,561 default and 30,985 maximum clocks. The bounds are not measured benchmarks;
source gaps and output stalls prevent an absolute wall-clock completion bound.

## Offline example and fixed finite verification

From this directory:

```text
iverilog -g2012 -Wall -tnull -s grayscale_size_zone -f files.f
iverilog -g2012 -Wall -tnull -s zone_texture16 -f example/files.f
python -B run_tests.py
```

The example forwards all ports for default 16x16/P8/G2/8-connectivity. Both
manifests reference only local sources. New work is under root
[LICENSE](../../../LICENSE)/[NOTICE](../../../NOTICE); no upstream code is
copied, executed, translated or required offline.

The nine tuples (WIDTH,HEIGHT,PIXEL_W,GRAY_W,CONNECTIVITY,TAG_W) were fixed before
any compiler/simulator invocation: (1,1,1,1,4,1), (1,7,4,2,8,3), (7,1,8,3,4,8),
(2,2,2,2,8,8), (3,3,1,1,4,8), (8,5,8,2,4,8), (16,12,12,3,8,8),
(32,1,16,3,8,32), (1,32,16,3,4,32). Each has 20 predetermined directed/random/
marker-error frames; the 2x2 case adds all 256 four-gray images and 3x3 adds all
512 binary images: **948 main frames**. Largest simulated area is 192, largest
axis 32; the full legal 32x32/P16/G3/C8/T32 configuration is compile-only from
the outset, with numerical simulation NOT_RUN.

The oracle unions whole-image undirected equal-gray edges and aggregates root
sizes; it does not reproduce FIFO floodfill, visited flags or hardware phases.
It also checks global/per-gray area conservation and geometric degree counts.
Directed patterns cover zero, maximum, all-constant, checkerboard, both stripes,
diagonal touching, L shapes, corner singleton, blocks, low-bit quantization and
cross-shaped regions. Four independently malformed frames check SOF/EOL and
first-tag ownership. The TB checks every dense field, actual held normal/error
outputs with a blocked next source, and all main work/latency counters.

Immediate reset probes target every reachable state, mid-clear, partial/error
capture, new/already-visited neighbors, a full N-entry FIFO at completion, last
seed reads/evaluations and held normal/error outputs. N=1 skips impossible
neighbor states. Each cancellation is followed by a complete single-bright-
corner/dark-remainder image, checking all output bins and forcing new pixel/
visited/FIFO/histogram work (two zones when N>1). Main service totals exclude
these extra transactions. The plan has 12 probes at N1 and 20 elsewhere.

Every compiler/simulator child has a 20-second limit. Timeout stops the matrix,
is retained as TIMEOUT/NOT_RUN, and forbids retries, smaller fixtures or longer
limits. Every child is checkpointed before launch and after completion; ordinary
initial failures are retained separately with their commands/source hashes.
Twelve invalid parameter configurations require the named elaboration rejection.

Current evidence: 948 main frames (912 good, 36 rejected), 12,112 input pixels,
59,872 dense output transfers and 948 exact tail checks. The TB observed 10,816
seed evaluations and pops each, 62,400 neighbor decisions, 42,400 in-bounds
visits and 4,026 histogram increments, matching independently counted image
geometry and zones. Actual held cycles total 76,393 and blocked source cycles
467,560. The largest selected first-valid tail is 5,430 clocks at 16x12; this
is a finite-fixture result, not a global maximum or frequency measurement.

All 172 immediate cancellations were followed by 172 complete fresh images,
outside the main counts (6,472 fresh input pixels and 46,544 dense records).
The first matrix had no failed attempt, timeout, retry or fixture change.
Afterward only documentation and report packaging metadata were completed;
the qualified RTL, TB, runner, finite profiles and vectors were unchanged.
