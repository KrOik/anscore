# Binary hole filling by exact boundary-background flood

`binary_hole_fill.sv` fills every zero-valued region not connected to an image
boundary zero. Original foreground bits remain one. It emits both the filled
image and a hole-only mask (one exactly where an original zero was filled),
plus the number of filled pixels. This is binary hole filling, not closing;
the repository had no equivalent binary flood/reconstruction core on inspection.

Static CONNECT8=0 uses four background neighbors, CONNECT8=1 uses all eight.
Diagonal leakage therefore connects a cavity to the outside in eight-neighbor
mode but can leave it a hole in four-neighbor mode. Every in-image boundary
zero is a seed, including single-row/column/1x1 cases. There are no implicit
foreground borders, clipping or unprocessed edge pixels.

## Exact BFS and capacity proof

Input capture writes the binary image and initializes every visited bit. Each
boundary zero is immediately marked visited and appended once to a queue.
After capture, a synchronous queue read fetches a seed/reached background
coordinate; each valid neighbor is synchronously checked. A zero unvisited
neighbor is marked **at enqueue time**, then appended. Thus each pixel is
enqueued at most once in the entire traversal. The queue stores N=WIDTH*HEIGHT
coordinates and has nonwrapping head/tail counters capable of representing N.
Capacity N therefore suffices for any image; the full-background test exercises
tail=N explicitly. No reconstruction iteration limit or nonconvergence can
occur: at most N nodes are popped. A defensive unreachable capacity violation
would abort with error_code=2 instead of silently skipping a node.

Only after the queue is exhausted does output begin. For original bit p and
visited bit v, filled=p||!v, hole=!p&&!v. An all-foreground frame has no queue
seeds and is unchanged; an all-background frame is fully visited and unchanged.
Storage is 2*N bits for image/visited plus N*(XW+YW) queue bits, where
XW=max(1,ceil(log2(W))), YW=max(1,ceil(log2(H))). All three RAM reads are
synchronous; memories need no reset because capture overwrites every required
image/visited entry and queue counters invalidate old entries.

## Frame protocol and timing

WIDTH/HEIGHT are positive static parameters, each <=65535, with total N<=65536.
Geometry products use 64-bit arithmetic before declaring RAM; invalid large
parameters clamp storage before an initial fatal guard. Input/output are
row-major. SOF must be exactly at (0,0), EOL exactly at the final column.
Marker errors abort capture with error_code=1 and done, without output. Discard
the remainder externally and begin a new fresh SOF frame; no automatic marker
search is performed. The next first pixel clears errors/count. A successful
frame pulses done when the last output is accepted. filled_count is accumulated
as output pixels are presented; its complete-frame value is valid at done.
Output pixels/markers/hole mask remain stable under backpressure.

All transfers require **ce && valid && ready** and are invalid during reset.
Both neighbors must honor CE. Reset is synchronous active-low, overrides CE,
discards computation/pending output and clears counters/status. Producers must
hold valid low during reset even if a combinational ready output is high.
The next complete frame reinitializes image/visited data before any BFS read.
Capture, traversal and output do not overlap with another frame.

If Q reachable background pixels are popped, traversal costs Q*(3+2*C) enabled
cycles with C=4/8, then first output valid appears three enabled edges later,
measured from final input acceptance. Thus first-valid latency is 11*Q+3 or
19*Q+3 enabled edges. Output II=3 enabled cycles without stalls. This is a
resource-bounded frame processor, not an II=1 or video-line-rate design.

## Evidence and public reference

```
python -B cores/system/common_scaffold/image/hole_fill/test_hole_fill.py
python -B cores/system/common_scaffold/image/hole_fill/synth.py
```

An independent Python deque floodfill verifies all pixels and hole counts;
SciPy binary_fill_holes independently agrees exactly using an explicit cross
or full 3x3 connectivity structure. Eight variants cover 80 frames/2110 pixels:
1x1, single rows/columns, odd/even rectangles, empty/full, rings, multiple holes,
open boundaries, diagonal leaks, random and sparse patterns. The test asserts
four/eight topology differs on a directed diagonal fixture. It also checks
full queue capacity, partial-frame marker failure/retry, random valid/ready/CE,
stalled output stability, compute/output reset and four invalid parameter sets.
Temporary binaries are automatically removed.

An actual HTTPS fetch of the
[SciPy binary_fill_holes reference](https://docs.scipy.org/doc/scipy/reference/generated/scipy.ndimage.binary_fill_holes.html)
confirmed the complement-invasion-from-boundary mathematical contract.
reference.json records the content SHA256. No external implementation was copied.

Isolated 16x16 Gowin synthesis (`-noalu -nodsp`):

| background connectivity | LUT1-4 | MUX5 | FF | memory | DSP |
| --- | ---: | ---: | ---: | --- | ---: |
| 4 | 417 | 36 | 143 | 1 DPX9B + 32 RAM16SDP4 | 0 |
| 8 | 421 | 42 | 143 | 1 DPX9B + 32 RAM16SDP4 | 0 |

Both CHECK passes report zero problems. Memory scales with geometry. No P&R,
clock target or board validation is claimed.
