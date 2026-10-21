# Exact RGB 3D LUT trilinear stream

`color_lut3d.v` implements a complete runtime-loaded RGB cube transform with
endpoint-aligned **exact rational trilinear interpolation**. It never treats
an unloaded or partial table as an identity/passthrough success. The design
uses one table, eight serial synchronous vertex reads, one shared bit-serial
multiply/accumulate engine, and a restoring divider; there are no runtime
combinational dividers or DSP multipliers.

## Table dimensions, memory bit order and math

BITS=8..12, GRID_LOG2=1..4, K=2^GRID_LOG2, N=K+1. The supported cube sizes
are 3,5,9,17 nodes per axis. Each vertex has three BITS-bit unsigned channels:
**lut_data={R,G,B}, R in the most significant BITS, G in the middle, B in the
least significant BITS**. Pixels use the identical s_rgb/m_rgb bit order.
Addresses are sequential with R fastest, G next, B slowest:
`address=(blue*N+green)*N+red`, coordinates 0..K. The caller must supply exactly
N^3 vertices in this order; it is the standard .cube vertex order.

Let D=2^BITS-1. For each input channel v:

```
u = v*K / D
lower = min(floor(u), K-1)
fraction = v*K - lower*D                  // integer in [0,D]
```

The eight surrounding vertices are combined using per-axis integer weights
fraction and D-fraction. The numerator is the sum of each vertex channel times
its three weights; output is `clamp(round_half_up(numerator / D^3),0,D)`.
The implementation keeps all precision through the three interpolation axes
and rounds **only once**, at final output. It does not quantize fractions to
Q8 or truncate between axes. Shared arithmetic uses at most 4*BITS+1 bits;
D^3 and all products fit that explicit bound. Since D is all one bits,
D-fraction is the bitwise complement of fraction: each bit-serial multiply
step chooses one of its two endpoints and adds one shifted value. The final
constant-denominator division is serial, not an uncontrolled synthesized `/`.

Input 0 maps exactly to first-axis vertex; input D maps to lower=K-1 with
fraction=D, selecting the last vertex exactly. All eight cube corners therefore
produce exactly their stored vertex value. An identity grid is quantized by
rounding node index*D/K; the tested integer input points remain exactly
identity, including half-grid neighborhoods and endpoints.

## Loading, commit and frame atomicity

All configuration operations are handshakes qualified by CE:

1. `load_begin_valid/load_begin_ready` starts a fresh full-table transaction,
   invalidates configured, clears config_error, and resets the sequential
   write index. It is accepted only when no frame/pixel/output is active.
2. Transfer vertices using lut_valid/lut_ready, with lut_last true **only**
   on vertex N^3-1. Early or missing last stops the transaction, sets error 2
   and leaves the table unusable. Restart with a new load_begin.
3. `commit_valid/commit_ready` publishes a complete table. A successful commit
   sets configured and pulses commit_done. A partial/absent table is rejected
   with error 1; it cannot accept pixels. A partial load may continue after
   such a rejected commit, then a later commit can succeed.

config_error is historical until the next load_begin or reset: a successful
retry is confirmed by configured/commit_done even if an earlier rejected
commit left error 1. New load_begin invalidates the prior table instead of
retaining an old active copy: table replacement intentionally pauses between
frames rather than doubling RAM storage. RAM is not reset, but no pixel can
read it until a complete post-reset table has committed.

Load-begin has priority over a simultaneous commit request, preventing a
mutual-ready deadlock. Vertex writes are paused for either control request;
no two configuration operations are accepted together. Producers must hold
each valid bundle until its own handshake. Do not send a vertex as though
it was accepted when lut_ready is low.

Pixel SOF and EOF explicitly delimit frames; s_eof is an additional required
sideband because this core has no WIDTH/HEIGHT registers. s_sof must be true
exactly when no frame is active; s_eof must also have s_eol=1. Any violation
sets sticky marker_error, and output data/markers remain deterministic; the
caller must discard a malformed frame. EOL is preserved as metadata; without
geometry this core cannot validate row length. EOF clears input-frame state,
but load/commit are still blocked until that pixel's output drains. A config
request held during a frame neither commits nor blocks the remaining pixels;
it is accepted only after the complete frame drains. Omitting EOF can keep
configuration blocked indefinitely; synchronous reset explicitly aborts it.

## Streaming, CE, latency and reset

Every transfer is `ce && valid && ready`. CE=0 freezes state, RAM accesses,
payload and markers; m_valid may remain high. Input/config ready are low
during pause. Output RGB, SOF/EOL/EOF remain stable under backpressure.
The core accepts one pixel, computes all channels serially, then holds its
output until consumed. No additional pixel is accepted while it computes or
holds an output. `busy` includes calculation, pending output, table loading
and an active frame between pixels.

After an input handshake, output becomes valid after
`sum(lower_axis+1) + 33*BITS + 48` enabled clocks, at most
`3*K + 33*BITS + 48` clocks (492 for BITS12/GRID_LOG2=4), excluding stalls.
Table load requires N^3 accepted words. This low-resource implementation is
not a one-pixel-per-clock video datapath; the upstream must obey ready.

Active-high synchronous rst overrides CE, aborts a partial frame/load/output,
clears configured and diagnostics, and requires a new complete load+commit.
No old/uninitialized RAM data can then reach a valid output. commit_done is
an enabled-clock pulse, held during CE pause. marker_error is sticky until
reset; config_error is cleared by reset or a new load transaction.

## Verification and host integration

```
python -B cores/system/common_scaffold/image/color_lut3d/test_color_lut3d.py
python -B cores/system/common_scaffold/image/color_lut3d/synth_color_lut3d.py
```

An independent Python Fraction oracle performs geometric coordinate mapping
and eight-corner rational weighting, independently of the RTL serial/separable
arithmetic. Five configs exercise BITS8/10/12 and every grid exponent 1..4,
including all 4913 entries of a 17^3 table. Four tables per config are identity,
nonlinear cross-channel, random vertices, and a channel permutation. All
**400 output pixels** are compared exactly, including all eight corners,
near endpoints, middle-grid neighbors and random RGB inputs.

The permutation table is actually authored as normalized .cube text, passed
through `host/color_lut3d/export_cube.py:convert`, written to hex and loaded
into the RTL. Its quantized vertices are first independently checked, and
expected interpolation remains the Fraction oracle rather than the exporter.
This verifies address order, channel bit order and host export integration.

Tests additionally cover commit before load, partial-table rejection followed
by successful completion, malformed last markers, uninitialized-read gating,
frame-safe deferred load, blocked mid-frame commit, simultaneous config request
priority, random CE and ready pauses, full marker preservation/diagnosis,
reset during arithmetic, reset during stalled output, reset mid-load, and four
illegal static parameters. Temporary binaries/fixtures are deleted automatically;
small JSON summaries remain here.

## Isolated resources

synth_gowin, no family/P&R; LUT1-4 and ALU are reported separately:

| BITS / GRID_LOG2 | LUT1-4 | ALU | FF | DSP | storage cells |
|---|---:|---:|---:|---:|---|
| 8 / 1 | 550 | 122 | 422 | 0 | 24 RAM16SDP4 |
| 10 / 2 | 657 | 176 | 494 | 0 | 1 SDPX9B + 16 RAM16SDP4 |
| 12 / 4 | 895 | 204 | 605 | 0 | 10 DPX9B + 18 RAM16SDP4 |

MUX5 cells are separately recorded in synthesis_result.json. Raw table storage
is N^3*3*BITS bits: 176868 bits for the largest supported 17^3/12-bit table.
Small vertex/work buffers may map to LUT RAM. 33^3 tables are not supported.
No P&R, 50 MHz timing closure or physical board result is claimed.

