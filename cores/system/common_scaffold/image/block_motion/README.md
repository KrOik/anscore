# Exhaustive integer block motion estimation

`img_block_motion.v` estimates a motion vector for every fixed-grid grayscale
block in a current/reference frame pair. The existing `img_mf_translation_sad`
was inspected: it estimates one global cropped-frame translation, not a block
motion field. This independent module fills the block-grid gap without changing
that accepted kernel. It implements exhaustive integer SAD, not optical flow,
subpixel interpolation, pyramids or motion-compensated prediction.

## Parameters and exact motion convention

Compile-time parameters: `WIDTH,HEIGHT=1..4096` with total pixels <=65536,
`BITS=8..12`, `BLOCK_W,BLOCK_H=1..64`, `SEARCH_RANGE=0..15`.
Invalid combinations fail elaboration. Defaults are 16x12,8-bit,8x8 blocks,R=2.
Memory capacity and execution time further constrain useful physical dimensions.

Blocks start at x=0,BLOCK_W,... and y=0,BLOCK_H,... in row-major grid order.
The final column/row uses actual width=min(BLOCK_W,WIDTH-x), and equivalent height.
There is no padding: SAD includes exactly that actual area, including a 1-pixel
corner block. Every displacement `(dx,dy)` within [-R,R]^2 is considered only if
the **whole actual reference block** lies within the frame:

```
SAD(dx,dy) = sum(abs(current[y+j,x+i] - reference[y+dy+j,x+dx+i]))
```

The vector therefore maps **current block position + offset into the reference**.
It is not a forward flow that maps reference into current. Offset zero is always
legal, including full-frame blocks and R=0, so every block has at least one
candidate. Out-of-frame candidates are skipped entirely rather than padded or
evaluated on a smaller intersection, keeping all candidate costs comparable.

Select the smallest SAD; ties select smallest `abs(dx)+abs(dy)` (Manhattan
magnitude), then numerically smaller signed dy, then smaller signed dx. The
runner-up SAD is the smallest cost among **all other distinct offsets**, including
another offset tied for best. Thus a cost tie has gap zero even though its chosen
vector is deterministic. A block with one legal offset reports second SAD and gap
as `32'hFFFFFFFF` (infinite confidence); it is not rejected for lack of a runner-up.

Each difference fits BITS bits. Maximum legal SAD is
BLOCK_W*BLOCK_H*(2^BITS-1), at most 16,773,120 for 64x64 and BITS=12. The internal
cost width is ceil(log2(maximum+2)), reserving an all-ones sentinel strictly above
every real sum. Public 32-bit costs and unsigned differences therefore do not wrap.
The maximum legal block/bit-depth cost is tested directly.

## Configuration, input and result interfaces

Input `s_current/s_reference[BITS-1:0]` supplies paired raster pixels with
`s_valid/s_ready`, `s_sof` on frame pixel 0, `s_eol` on every actual row end.
Frames must already be synchronized; there is no timestamp or camera aligner.
Both frames are fully captured before any block is evaluated.

Idle `cfg_valid/cfg_ready` atomically sets unsigned 32-bit `cfg_max_sad` and
`cfg_min_gap`. All values are legal. `cfg_done` is an enabled-cycle acknowledgement.
Config takes priority over idle input and is snapshotted on accepted frame SOF.
Busy config is not accepted; hold the request until ready to update a later frame.
Reset defaults max SAD to FFFFFFFF and minimum gap to zero, accepting every computed
best vector. Criteria apply to the raw SAD sum, **not normalized by actual area**;
applications should account for partial-block areas when choosing these thresholds.

Each `m_valid/m_ready` result contains:

- Signed 16-bit `m_dx,m_dy` using the convention above.
- `m_x,m_y[15:0]`: block **pixel origin**, not grid index.
- `m_width,m_height[15:0]`: actual unpadded dimensions.
- `m_sad,m_second_sad,m_gap[31:0]`: best cost, runner-up, nonnegative difference.
- `m_invalid` and 2-bit reason **bit mask**: bit0 if best SAD > max SAD;
  bit1 if gap < min gap. Both bits may be set. Equality passes both tests.
- `m_sof` for the first block and `m_last` for the final block of the frame.

Vectors/costs remain available even when marked invalid. An invalid vector is a
successful result with insufficient match quality, not a frame-processing failure.
After the last block transfer, `done_valid/done_ready` carries stable `done_error`
and `error_code[1:0]` (zero success, one input-marker error). Input/config waits
until completion is consumed. There is no new-frame start command beyond SOF.

## RAM, CE, throughput and recovery

Two full-frame synchronous RAMs store current/reference pixels: logical storage
2*WIDTH*HEIGHT*BITS. RAM contents/read registers are not reset. A complete new
frame capture overwrites every pixel before results can be produced; stale RAM
cannot become a valid frame. Constant-stride addressing uses shift/add, not DSP.

All interfaces transfer on rising edges with `clk_en && valid && ready`. Ready
is low when CE is disabled or reset is asserted. Pending result and completion
payloads remain stable under backpressure or disabled CE. Consumers must honor
this CE-qualified convention; input sources hold pending data/markers until accepted.

Capture accepts up to one paired pixel per enabled edge. One sample SAD iteration
uses three edges: synchronous address/read, absolute difference, accumulation.
A valid candidate adds approximately 3*actual_area+3 edges including candidate/
update/next control; a rejected out-of-frame candidate uses two. Each block adds
initialization/report/transfer overhead and any output stalls. Total work scales
with number of blocks * (2R+1)^2 * actual area. There is no frame overlap, DMA,
early SAD termination or parallel candidate search. This is a small serial
arithmetic implementation; large search/frame settings have correspondingly high
latency and RAM requirements.

Any SOF/EOL mismatch, including missing initial SOF, immediately aborts with error
completion. No vectors were emitted yet because input validation precedes all
processing. The offending sample is dropped. After completion, the next sample
must start a new valid frame; there is no silent resynchronization or missing-pixel
timeout. Asynchronous low `rst_n` aborts capture, candidate calculation, stalled
results or pending completion and restores default configuration. A reset can
invalidate an already partially emitted vector frame, which consumers must discard.

## Reproduce and evidence

From repository root:

```powershell
python -B cores/system/common_scaffold/image/block_motion/run_tests.py
python -B cores/system/common_scaffold/image/block_motion/synth.py
```

Both scripts use `integration/tooling.py` and temporary directories. Simulation
vectors/binaries and synthesis working files are removed automatically; only
small source-bound JSON/log evidence remains.

An independent Python exhaustive enumerator computes costs, sorts candidate keys
and checks every RTL field. Eight profiles cover every bit width 8..12, 1x1 and
thin frames, partial 9x7 blocks, R=0, 1x1 blocks, full-frame blocks and the maximum
64x64/12-bit SAD of 16,773,120. Cases include uniform/ambiguous ties, directed
signed dy/dx tie breakers, independently verified known positive/negative axial
and diagonal translations, random pairs, exact threshold acceptance and invalid
bit combinations. Total 130 reference frames / 834 vectors PASS. Additional
bad-marker/missing-SOF recovery, busy config snapshot, random CE/source/sink
stalls, stable result/completion and capture/processing/output-reset checks are
included. `test_result.json` records the final RTL hash.

`synth.py` maps a 9x7,8-bit,4x3-block,R=2 instance with
`synth_gowin -noalu -nolutram`. CHECK 0 problems; 397 LUT1..4, 52 MUX2_LUT5,
265 FF, 2 DPX9B, 0 DSP. Exact cells/hash are in `synthesis.json` and the retained
`synthesis.log`. Counts describe that configuration only. No placement/routing,
clock setup/hold signoff, JTAG or physical video motion-quality validation is
claimed. Shared source/runner integration is owned by the parent task.
