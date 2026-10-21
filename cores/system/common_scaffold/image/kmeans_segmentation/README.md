# Full-frame three-channel K-means

`kmeans_rgb_frame.sv` implements complete bounded integer Lloyd clustering,
not a nearest-palette placeholder. `WIDTH*HEIGHT` must be 1..1024; each axis
must be 1..1024. Runtime K is 2..4; each unsigned channel is 8 bits. Distance
is the sum of three squared channel differences, with lowest label winning
ties. The triplet is nominal RGB; callers may supply other consistently
encoded channels. In particular, encoded 8-bit Lab distance is not pure ΔE.

START atomically captures K, iteration limit (1..255), tolerance (0..255),
and seed. Capture accepts exactly N raster pixels with SOF only on the first
and EOL on every row end. There is no external host-computed palette.
Initialization samples actual frame RAM: `r0 = seed or 1`, center j is pixel
`rj % N`, followed by xorshift32 (left13, right17, left5 with 32-bit truncation).
Repeated indices/colors are allowed. Inactive center and count slots are zero.

Every iteration assigns the entire frame, accumulates exact integer sums and
counts, and updates each nonempty center as `(sum + floor(count/2))/count`
with integer division. Empty clusters retain their old center. Convergence
means maximum absolute per-channel center movement <= tolerance, tested
after each full update. Iterations includes that final update. Max-iteration
termination has `converged=0` unless tolerance also passed. A separate final
assignment pass emits *all* labels and quantized triplets using final centers;
counts and inertia describe those final assignments rather than stale labels.

`initial_centers` and `final_centers` pack center 0 in the low 24 bits;
`cluster_counts` packs count 0 in the low 11 bits (1024 is representable).
The triplet is `{channel0,channel1,channel2}`. Inertia is the exact integer
sum of final squared distances, bounded by 199756800 for 1024 pixels.

All transfers require CE as well as valid/ready. CE freezes state and output;
output data/markers remain stable until consumed. DONE is held until a
CE-qualified done-ready handshake. Active-low synchronous reset overrides CE.
No frame RAM reset is needed because full capture precedes every read.
Output is serial and variable latency, not one pixel per cycle: a single
8-cycle shift/add square multiplier and a single 32-cycle restoring divider
are shared. Frame reads are synchronous and map to block RAM at max capacity.

Error 1: invalid K/iteration limit or elaborated geometry, no input/output
frame accepted and previous statistics preserved. Error 2: bad SOF/EOL;
the full N samples are still captured, clustered and emitted deterministically,
then DONE reports the error. There is no partial persistent model. Reset is
the explicit abort mechanism; malformed traffic with fewer than N samples
waits for the remaining samples. Statistics remain stable after DONE until
the next valid START. The module does not claim unbounded image size, video
rate throughput, k-means++ initialization, or perceptual quality guarantees.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/kmeans_segmentation/run_tests.py
python -B cores/system/common_scaffold/image/kmeans_segmentation/run_synthesis.py
```

`test_evidence.json` records exact independent integer-oracle comparisons of
all output pixels, labels, center slots, counts, iterations, convergence and
inertia, with CE stalls, output backpressure, changed live configuration,
invalid STARTs, framing errors, held DONE, and disabled-CE reset/recovery.
It also runs actual sklearn 1.7.2 Lloyd KMeans with the identical initial
centers. Symmetric integral fixtures compare exactly; arbitrary random
fixtures report observed differences, because floating means and empty-center
relocation differ from this documented integer variant. No arbitrary-image
bit-exact sklearn equivalence is asserted. Source reference URLs, successful
fetch times and SHA256 are in `references.json`; no upstream code is copied.

Isolated Gowin synthesis passes `check` for 7x5 and 32x32, with 0 DSP and
approximately 2.1K LUT1..4 plus muxes. Exact counts are frozen in
`synthesis_evidence.json`. This is simulation and isolated synthesis evidence,
not JTAG/board acceptance, timing closure, or full-resolution validation.
All generated testbenches, vectors, simulator binaries and synthesis netlists
use temporary directories and are removed after normal completion.
