# Exact grayscale connected area opening

`grayscale_area_opening` accepts a real unsigned grayscale raster and emits its
exact **4-connected area opening**. Bright structures whose upper-level
connected area is too small are lowered to the first viable enclosing level.
Retained structures keep their contours. This supports segmentation cleanup
and bright-speck removal without a fixed structuring-element shape.

Status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
UNIT_SIM_PASS covers the first seven finite profiles (through 32x32); the
64x64 current-TB simulation timed out at 20 seconds and is **not qualified**.
The complete matrix is INCOMPLETE_TIMEOUT. Only the recorded checks in
`verification.json` are qualified. No synthesis, PnR, STA, board or expanded
regression is run.

## Mathematical image contract

For image f, pixel p, integer threshold l and area A, let C_l(p) be the
in-bounds 4-connected component containing p in `{q: f[q]>=l}`. Then

```text
g[p] = max({0} union {l: 1<=l<=f[p] and |C_l(p)|>=A}).
```

The image boundary excludes neighbors; it never wraps rows or introduces
outside pixels. Connectivity is north/south/east/west; diagonal touching alone
does not join components. Zero is an ordinary grayscale value and contributes
to the enclosing component at threshold zero. The zero baseline is exact
because A<=N and the whole rectangular raster is connected. No keep mask or
reserved background label exists. It is sufficient to evaluate positive
levels actually present in f because every other upper-level set equals the
set at the next larger present value.

All pixels/counts/decisions are exact; no rounding, saturation, tolerance,
iteration limit or convergence approximation occurs. Output values are zero
or input intensities, with g<=f. Area 1 is identity. Area N returns the global
minimum at every pixel, including nonzero constant images. A component of
exactly A pixels survives (the rejection predicate is area<A). In a binary
image this removes foreground components smaller than A. A thin connected
line can survive where a fixed-footprint morphological opening would erase it.

## Interface and bad-frame ownership

All ports use one rising-edge clock, synchronous active-high `rst`, ordinary
ready/valid and no CE. Source fields stay stable until acceptance. Static
WIDTH and HEIGHT define exactly N input transfers in row-major order. `s_sof`
must be true only on the first pixel, and `s_eol` only on each final column.
There is no LAST input, dynamic size, resynchronization scan or missing-tail
timeout. Supply the remaining N transfers or reset a partial frame.

`s_area` and `s_tag` belong to the **first accepted pixel**, even if its markers
or area are invalid. Area must be 1..N inclusive. Changes on later pixels are
ignored, including illegal later area values. The COUNT_W-bit field may have
no representable value above N for some geometries; zero remains invalid.
Input pixels themselves have no out-of-range encoding.

Independent sticky output error bits are:

| Bit | Meaning |
| --- | --- |
| 0 | SOF disagrees with expected first-pixel position |
| 1 | EOL disagrees with expected row-end position |
| 2 | First accepted area is zero or greater than N |

Errors do not shorten the input frame. After all N pixels arrive, **any error
produces a complete N-pixel zero raster**, with the first tag and all error
flags attached to every pixel. There is no partially valid filtered image.
Malformed later SOF cannot restart capture or steal ownership. All required
error flags are known before any output is visible. Output SOF/EOL/LAST are
generated from the fixed geometry, independent of malformed input markers.

Exactly N output pixels transfer in row-major order. `m_pixel`, markers, tag,
errors and valid remain stable during arbitrary output backpressure. The
current frame owns the service until its final output transfers; no next-frame
pixel transfers on that same edge. A waiting next frame can transfer one period
later. Output fields are meaningful only while valid. There is no completion
channel in addition to the final raster pixel.

Reset gates ready/valid low immediately and cancels capture, traversal, replay
or a held result at its active edge. No cancellation raster is emitted. RAM is
not reset: every new input overwrites all source and output locations, each
occupied threshold clears the whole visited RAM, and queue entries are marked
and written before reading. Consumers must discard a partially received raster
if reset occurs.

## Architecture, widths and service budget

| Parameter | Default | Legal range |
| --- | ---: | --- |
| WIDTH | 32 | 1..64 |
| HEIGHT | 32 | 1..64 |
| PIXEL_W=B | 8 | 1..8, unsigned |
| TAG_W | 8 | 1..32 |

N<=4096, IW=max(1,clog2 N), XW=max(1,clog2 WIDTH), and
COUNT_W=max(1,clog2(N+1)). Frame/queue addresses cover 0..N-1. Queue head,
tail/area and replay indices use COUNT_W, which represents N without wrap.
The level iterator has B+1 bits and can advance beyond maximum intensity.
Each threshold marks a member visited **before enqueueing**, so every pixel
enters the component queue at most once and tail never exceeds N. Queue state
is reused only after its qualified component has been completely replayed.

Four independent synchronous memories store source B, output B, visited 1,
and a queue entry of IW+XW bits per pixel. Queue coordinates carry x explicitly;
vertical addressing adds/subtracts static WIDTH, with no runtime multiply or
divide. Source/visited reads use separate READ/CHECK clocks, queue reads have
their own consume clock, and replay writes happen after the queue read. No
same-bank read/write collision or device-specific memory mode is required.
The comparator, queue and area counter are reused over all levels/components.
No label RAM, per-component table, full max-tree or sorting network is built.

Logical RAM is N*(2B+1+IW+XW): **32,768 bits** by default, **143,360 bits** at
64x64 B8, plus at most 256 occupied-level bits and scalar registers. These are
logical storage totals, not physical BRAM usage. Risk is **LOW** at default and
**MEDIUM** at maximum because of RAM packing and potentially long serial work.
No LUT/FF/DSP/Fmax/power/device-fit measurement is claimed.

Capture II is 1; always-ready output II is 2. There is no frame overlap.
For a legal frame let L be its number of distinct positive intensities. For
each such threshold let V_l count pixels >=l, R_l sum their in-bounds grid
degrees (including neighbors below l), and Q_l count pixels in components of
area >=A. Periods from final input transfer to first valid output are exactly

```text
max(f)+3 + sum_l(4*N + 7*V_l + R_l + 2*Q_l)
       <= max(f)+3 + 17*N*L.
```

All-zero legal images take 3 periods. Rejected frames take exactly 2 periods.
The finite TB checks exact first-valid latency and scan/pop/write totals for
every fixture. Earliest transfer occurs at the next edge after valid; the N
outputs then need 2N-1 edges with an always-ready sink. At maximum B8,N4096,
the structural first-valid bound is 17,756,418 periods; no video-rate claim is
made. Arbitrary source gaps/output stalls prevent a wall-clock completion bound.

## Offline example and finite checks

From this directory:

```text
iverilog -g2012 -Wall -tnull -s grayscale_area_opening -f files.f
iverilog -g2012 -Wall -tnull -s area_open32 -f example/files.f
python -B run_tests.py
```

`example/area_open32.sv` forwards all ports for a 32x32 grayscale8 raster and
11-bit runtime area. Both manifests include only local sources. The original
work uses root [LICENSE](../../../LICENSE)/[NOTICE](../../../NOTICE); actual
fixed upstream source/license preflight is [SOURCES.md](SOURCES.md).

The independent Python oracle activates pixels in descending intensity order,
unions active neighbors and assigns unresolved members when a set reaches A.
It does not reproduce the RTL's per-level raster scan, visited RAM, FIFO or
component replay. Anti-extensivity, idempotence, A1 identity and AN global
minimum also constrain fixtures. Independent upper-level graph counts predict
latency and total RAM scan/pop/write service, without clock-by-clock emulation.

The planned eight-profile matrix covers single pixel/rows/columns, nonpower dimensions,
PIXEL_W1/2/3/4/8, TAG_W1/3/8/32 and maximum 64x64 geometry. All 2x2 two-bit
images with A1/2/4, and all 3x3 binary images with A1/5/9, are enumerated.
Directed/random cases include nonzero background, nested peaks, plateaus,
diagonal isolation, thin connected borders, exact area, constant/empty/full
images, first-tag/config snapshots and independent/multiple marker/config
errors. Large profiles deliberately use few occupied levels; they do not
exhaust worst-case 255-level runtime.

Development note: an earlier zero-only post-reset recovery matrix completed
all eight profiles, but did not exercise visited/queue/replay in fresh recovery.
Recovery was strengthened to a single bright pixel. The first seven current
profiles passed; the 24-frame 64x64 child reached its 20-second timeout and
stopped. Its current compilation passed, but its enhanced simulation remains
TIMEOUT/NOT_RUN and the earlier TB result does not qualify it. A narrowed rerun
was interrupted on coordination before accepting any maximum-profile result;
the original fixtures are restored. No further full matrix or maximum-profile
simulation is run. Production RTL and exact numerical/latency checks did not
change; no timeout was extended. Eight independent negative-parameter compile
checks were then completed separately because they do not run image simulation.

The TB checks every output field, real source and sink stalls, held stability,
ownership, queue bounds and work totals. Immediate resets target every reachable
controller phase, held good/error pixels with blocked next-frame input, and
bad-frame capture drain. No active edge intervenes between observing the full
target and reset assertion. A fresh single-bright-pixel frame at area 1 after
every cancellation forces visited clearing, queue use and qualified replay,
while dark pixels check source/output overwrite isolation. These finite probes are not exhaustive
reset proofs. Eight invalid static parameter configurations must fail by the
named invalid instance. Every compiler/simulator child has a 20-second timeout;
positive checks reject any diagnostics. Temporary vectors/images are removed.
