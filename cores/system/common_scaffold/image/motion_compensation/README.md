# Integer block motion compensation

`motion_compensation.sv` reconstructs a full grayscale raster from one reference
frame and one backward motion vector per fixed-grid block. It fills the missing
motion-compensated prediction stage identified by `image/block_motion/README.md`;
global translation and affine transforms are different operators.

For output pixel `(x,y)`, select the block at `(x/BLOCK_W,y/BLOCK_H)` and sample
`reference[y+dy,x+dx]`. This matches `img_block_motion` exactly: displacement maps
**current coordinates into the reference**, with no sign reversal. The final
block row/column has independent actual width/height, including thin and
single-pixel corner blocks. No padded block pixels are generated. This is integer
nearest-neighbor compensation, without fractional vectors or interpolation.

## Transaction and mapping

Parameters: WIDTH/HEIGHT 1..65535, total pixels <=65536, BITS 8..12, BLOCK_W/
BLOCK_H 1..64. Invalid combinations fail elaboration. Logical storage is
`WIDTH*HEIGHT*BITS + ceil(WIDTH/BLOCK_W)*ceil(HEIGHT/BLOCK_H)*33` bits.
The reference frame and vector grid use synchronous RAM reads and writes.

All transfers require `rst_n && ce && valid && ready`. Reset is synchronous,
overrides CE and aborts any phase. RAM is not cleared; counters and protocol
state prevent stale contents becoming visible after reset/release. Workflow:

1. Load one raster reference using `s_pixel/s_valid/s_ready`. SOF is required on
   the first pixel only; EOL on each actual final-column pixel only.
2. Load vectors using `vector_valid/vector_ready`, in row-major **block** order.
   Origins are pixel positions (0,BLOCK_W,...) and likewise for y. Width/height
   must equal the actual remaining unpadded area, capped at the block dimensions.
   Reference and vector loads may interleave or occur simultaneously.
3. Handshake `start_valid/start_ready` after both tables are complete. Start has
   priority over both input streams and snapshots runtime `fill_pixel`.
4. Consume the full raster, then observe stable `done_valid`. Handshake
   `release_valid/release_ready` to clear counts and begin the next transaction.

There is a single frame transaction, with no concurrent-frame double buffer.
Busy input/config attempts are backpressured and do not modify RAM or snapshot
state. Holding output `m_ready=0` freezes every output field. CE pauses freeze
all state, including asserted outputs. Done holds until release, also across CE
pauses. `m_valid`/`done_valid` are not gated by CE; transfers are.

Map `img_block_motion.m_{x,y,width,height,dx,dy,invalid}` directly to corresponding
vector inputs, and `m_valid/m_ready` to `vector_valid/vector_ready`. The reference
pixels used by the estimator must also be supplied to compensation. Its SAD/gap
and reason fields are not required here; its boolean invalid is propagated as
an invalid block. The executable chain test connects the actual two RTL modules.

Each vector component is signed 16-bit. Reference x/y arithmetic is explicitly
signed 32-bit, preventing overflow at large coordinates or displacement extrema.
For each pixel, `m_reason` is a bitmask: bit0 is invalid vector, bit1 is sampled
reference coordinate outside the frame. Both can be asserted. `m_invalid` is OR
of these reasons. A pixel with any reason outputs snapshot fill; otherwise it
outputs the exact unsigned reference sample. An invalid vector invalidates the
entire actual block. For a valid vector, bounds are checked per pixel, so a
partially out-of-frame block retains its valid samples. Output includes x/y,
SOF/EOL/LAST markers and exactly WIDTH*HEIGHT pixels.

First output-valid occurs three enabled edges after accepted start, and output
presentation interval is four enabled edges when consumed immediately. Throughput
is serial and resource-oriented, not one pixel/clock.

## Errors and recovery

`error` is a one-enabled-cycle pulse; sticky `error_code` clears on reset/release.
Rejected input requests are consumed (valid/ready handshake) but never written
and do not advance the relevant counter. Correct the request and retry it.
Busy requests have ready low and are not consumed. If simultaneous reference
and vector requests both fail, the vector-side error code wins.

| Code | Meaning and behavior |
| --- | --- |
| 1 | Start rejected: reference frame incomplete; remain loading |
| 2 | Start rejected: vector grid incomplete; remain loading |
| 3 | Vector origin/order/actual dimensions mismatch; retain expected block |
| 4 | Extra reference pixel or extra vector after that table is complete |
| 5 | Reference SOF/EOL mismatch; retain expected pixel position |
| 6 | Illegal internal state; suppress output and permit explicit release |

Duplicate vectors and missing/out-of-order vectors cannot silently overwrite an
earlier block: ordered geometry must match the next expected block. No reference
or no vectors therefore cannot run. Missing data may be supplied after rejected
start; reset discards a partially loaded transaction. There is no implicit SOF
restart while a transaction is loaded.

## Reproducible checks

```powershell
python -B cores/system/common_scaffold/image/motion_compensation/run_tests.py
python -B cores/system/common_scaffold/image/motion_compensation/synth.py
```

The main entry includes all three test suites. Independent Python indexing
checks 120 frames /2808 pixels over five configurations (8/10/12-bit; partial,
thin and single-pixel frames), zero/positive/negative/diagonal/random vectors,
signed extrema, invalid vectors, edge fill, reload, marker/geometry/duplicate/
overflow errors, missing tables, configuration snapshot, busy isolation, CE and
backpressure, and reset in load/compute/output phases. A real exhaustive
block-motion-estimator RTL chain adds three frames /27 vectors /105 output
pixels, using independent Python SAD ranking and prediction oracles.

Additional procedural geometry tests check 65535x1 frames with both +32767 and
-32768 displacements (131070 output pixels) and maximum 65536-pixel 256x256
capture/count/start transactions. Intermediate simulation/synthesis artifacts
use automatically cleaned temporary directories. Compact logs/evidence persist.

Isolated Gowin `synth_gowin -noalu -nodsp; check` at 9x7 B8 blocks4x3 passes:
491 LUT1..4, 188 FF, 17 RAM16SDP4, 0 DSP. This small instance maps to distributed
RAM with synchronous read behavior. Synthesis is not timing closure or board
validation; neither place/route nor JTAG was run for this module.
