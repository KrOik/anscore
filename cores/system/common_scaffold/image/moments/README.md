# Exact spatial moments and centroid

`image_spatial_moments.sv` consumes one raster image and computes exact unsigned
raw moments M00, M10, M01, M20, M11, M02. Coordinate origin is the top-left,
x increases to the right, y downwards. The moment definition is
`Mij = sum(weight(x,y) * x**i * y**j)`. This is a complete streaming accumulator
and hardware divider, with no host-side calculation required at runtime.

`binary_mode` is sampled on the first accepted pixel of every frame. In binary
mode each nonzero pixel has weight 1; otherwise weight equals unsigned intensity.
With parameter `MASK_ENABLE=1`, `s_mask=0` excludes that pixel. Mask is part of
the same pixel transfer, with no separate mask-valid/channel. When disabled,
mask is ignored. Changes of binary_mode later in a frame have no effect.

All transfers require **rst_n && ce && valid && ready**. Reset is synchronous,
active low, and overrides CE. Do not count transfers while reset is asserted,
even if combinational s_ready is high. `s_sof` must be true exactly at (0,0),
`s_eol` exactly at x=WIDTH-1. Marker mismatch aborts the whole frame, pulses
done with error_code=1, clears partial sums and restores immediate fresh-frame
acceptance. A legal first pixel clears the error. Reserved defensive illegal
state recovery reports error 2. Source gaps and CE pauses are supported.

One output record is produced per good frame. It includes six 64-bit raw
moments and 32-bit Q16.16 centroids, each computed by unsigned floor division:
`cx=floor((M10<<16)/M00)`, `cy=floor((M01<<16)/M00)`. There is one shared
80-cycle restoring divider, used twice. Empty/all-masked frame emits all raw
zeros and cx=cy=0, centroid_valid=0, with no protocol error. Nonempty frame sets
centroid_valid=1. Raw sums may change during capture; consume the entire output
only with m_valid. All output fields remain stable under backpressure or CE=0.
done pulses for one **enabled cycle** on output handshake (or marker abort).
busy covers partial capture, division, and pending output. New frame capture
starts after that handshake; this module does not buffer overlapping frames.

After final input transfer, m_valid appears after 162 enabled clock edges for a
nonempty frame, or one enabled edge for an empty frame. Input II is 1 during
capture. Output latency counts no disabled edges; m_ready does not affect when
m_valid is first asserted. Reset aborts capture, division or a held output.

## Bounds and implementation

Supported: BITS=8..12; WIDTH and HEIGHT=1..4096, product <=65536.
All products used for parameter validation are explicitly 64-bit. Coordinates
are unsigned 12 bits, weights <=4095. Coordinate square/cross products fit 24
bits; weight times these products fits 36 bits. Conservative sum bounds are:

| Quantity | Strict upper bound |
|---|---:|
| M00 | 2^28 |
| M10, M01 | 2^40 |
| M20, M11, M02 | 2^52 |
| M10 or M01 shifted left by 16 | 2^56 |
| Centroid Q16.16 | 2^28 |

Therefore 64-bit raw sums and the explicitly 80-bit centroid numerator cannot
overflow for any supported image; 32-bit centroid outputs are sufficient. The
divider remainder is 65 bits. No central/normalized moments, orientation,
covariance or Hu invariants are supplied. These require wider intermediate
products and an explicit rounding/normalization contract; do not calculate
central products by multiplying raw moments in 64 bits.

No frame RAM or coefficient RAM is needed. All state is registered. Parallel
coordinate/weight products provide one input per enabled cycle, at a documented
logic cost. Isolated synthesis uses `-nodsp`, so multipliers map to LUTs.

## Reproduce

From the repository root:

```powershell
python cores/system/common_scaffold/image/moments/test_moments.py
python cores/system/common_scaffold/image/moments/synth.py
```

Tests use independent Python arbitrary-precision sums, NumPy reductions and
actual `cv2.moments` calls. Directed patterns cover empty/full, single/translated
points, horizontal/vertical symmetry, checkerboard, weighted/random images,
masking, thin geometries, 4096 coordinates and a full 65536-pixel capacity image.
Mode snapshot, CE, output stalls, malformed markers, reset during partial
capture/division/held output, and fresh replay are exercised. Six invalid
parameter cases must fail elaboration/runtime initialization explicitly.
Temporary testbenches/binaries are automatically removed; compact JSON and
synthesis logs remain. `evidence.json` and `synthesis.json` contain current
results. Isolated synthesis CHECK is required to report zero problems.

Current numerical regression: **176 frames / 273186 pixels**, 176 independent
OpenCV audits, plus six rejected parameter cases, all PASS. Standalone Gowin
synthesis for 16x16, MASK_ENABLE=0, with no DSP mapping:

| BITS | LUT1..4 total | FF | MUX5 | DSP | RAM |
|---|---:|---:|---:|---:|---:|
| 8 | 4219 | 633 | 344 | 0 | 0 |
| 12 | 5352 | 633 | 389 | 0 | 0 |

Both configurations report CHECK zero problems. These numbers are isolated
logic estimates, with top-level I/O buffers, not place-and-route utilization.

This folder has **no board validation or routed timing claim**. A successful
standalone synthesis is not an acceptance report for an integrated board top.

Reference: [OpenCV moments implementation](https://raw.githubusercontent.com/opencv/opencv/4.x/modules/imgproc/src/moments.cpp).
The fetched source hash is recorded in reference.json; RTL is independently
implemented. Tests compare raw moments, not OpenCV floating central moments.
