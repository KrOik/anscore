# Exact squared Euclidean distance transform

`euclidean_distance.sv` computes, for every binary input pixel `(x,y)`,

```
distance_squared = min((x-feature_x)^2 + (y-feature_y)^2)
```

A **zero** input is a feature; a one is foreground. Output includes the exact
unsigned 32-bit squared distance and coordinates of its nearest zero pixel.
Equal distances choose the feature with the lowest raster index `fy*WIDTH+fx`.
There is no chamfer approximation, Manhattan substitution, or square-root output.
If a frame contains no zero, every output has `m_invalid=1`, distance FFFFFFFF,
and nearest x/y FFFF. For valid frames all outputs have invalid zero, including
input zeros themselves (distance zero and nearest coordinates equal themselves).

## Algorithm and range

The first pass evaluates every candidate source x in each row, storing that
row's exact horizontal squared distance, nearest feature x and validity for
each pixel. The second pass evaluates every candidate source row, adding
vertical squared distance to the stored horizontal minimum. This separable
min-plus transform is exact. Ascending candidate x and source-row traversal,
with strict-improvement replacement, implements the documented tie rule.

Complexity is O(WIDTH*HEIGHT*(WIDTH+HEIGHT)), rather than testing every 2-D
feature for every output. It is deliberately serial and resource-oriented;
very wide/tall frames are slow. Hardware tests here do not claim video-rate
throughput. Squaring uses exact unsigned shift/add arithmetic and needs no DSP.

WIDTH and HEIGHT are 1..65535, total pixels <=65536. Invalid geometries fail
elaboration. Under this limit, the largest possible true squared distance is
65534² = 4294705156, so uint32 holds every valid result and FFFFFFFF remains an
unambiguous sentinel. Candidate addition is 33-bit to avoid intermediate wrap.
The horizontal store narrows fields from the static geometry: logical storage
is `N * (2 + 3*max(1,ceil(log2(WIDTH))))` bits, comprising one binary frame and
one packed horizontal-result frame. Both memories use synchronous accesses and
are not reset. An entirely captured frame precedes the horizontal pass, and an
entirely written horizontal store precedes any vertical read.

## Stream protocol and recovery

All transfers require `rst_n && ce && valid && ready` at the rising edge. Reset
is synchronous, overrides CE, aborts every processing phase and clears public
valid/error state. RAM is not cleared; fresh full-frame capture and both passes
prevent stale contents from being exposed after reset.

Supply one binary raster through `s_pixel/s_valid/s_ready`. SOF is required only
on pixel zero; EOL is required on the last pixel of each actual row. A marker
error immediately stops capture, emits no frame results, and presents stable
`done_valid=1,done_error=1`. Acknowledge it with `done_ready` to retry a new frame.
An incorrect SOF cannot silently restart a partially captured frame. There is
one frame buffer, without concurrent capture/processing or runtime configuration.

After capture, input ready stays low throughout both passes, raster output and
completion. Output x/y, SOF/EOL/LAST, distance, nearest coordinates and invalid
are stable under backpressure. CE pauses freeze internal state and all pending
outputs; `m_valid` itself remains asserted during CE pauses. Following the last
output transfer, `done_valid` holds until its handshake. `done_error=0` means a
completed EDT, including no-feature frames: absent features are data validity,
not a protocol error. Input restarts after completion acknowledgement. The
previous done-error flag clears on the next accepted first pixel or reset.

Without stalls, the horizontal pass takes `N*(2*WIDTH+1)` enabled edges after
capture; first output then needs `2*HEIGHT+2` enabled edges. Immediate output
consumption gives output-valid interval `2*HEIGHT+3` enabled edges. Input capture
can accept one pixel per enabled clock. Throughput is geometry-dependent.

## Verification and resource evidence

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/euclidean_distance/run_tests.py
python -B cores/system/common_scaffold/image/euclidean_distance/synth.py
```

The tests check 115 frames /4279 outputs across 9x7,8x9,1x17,17x1,1x1,3x3 and
257x1 geometries. Independent brute-force **2-D** Python search validates squared
distance, nearest coordinates and the raster tie rule. Actual SciPy 1.15.3
`scipy.ndimage.distance_transform_edt` is separately evaluated on 102 frames,
and rounded squares of its float64 distances must match every hardware golden
distance. SciPy nearest-feature ties may differ and are not used as the nearest
coordinate oracle. For no-feature frames SciPy's implicit outside-feature
behavior is intentionally excluded; hardware follows its explicit invalid contract.

Coverage includes all zeros/ones, single zeros at corners/center, checkerboards,
crosses, random feature densities, ties, thin/odd geometries, exact distances
above 65535, CE pauses, output/completion stalls, missing SOF/wrong EOL, frame
reload, and reset during capture/horizontal/vertical/output phases. Additional
tests validate 32-bit extreme square arithmetic, reject invalid geometry, and
accept maximum-limit 65535x1 and 256x256 elaborations; these large geometries
are not claimed as full-frame processing regressions.

Isolated 9x7 `synth_gowin -noalu -nodsp; check` passes with 351 LUT1..4,178 FF,
20 RAM16SDP4 and 0 DSP. This small instance maps to distributed RAM while keeping
synchronous read behavior. No place/route, timing closure or board validation
is claimed. All bulky intermediate simulation/synthesis files use automatically
cleaned temporary directories; compact reproducible logs and evidence remain.
