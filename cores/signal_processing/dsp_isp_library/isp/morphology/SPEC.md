# Morphology contract (isolated development)

Unsigned 8/10-bit raster images; compile-time positive WIDTH/HEIGHT, K=3/5,
PAD_MODE=0 ZERO or 1 REPLICATE. Center anchor `(K/2,K/2)`. Mask bit `row*K+col`
selects that offset; at least one mask bit is required. Erosion takes samples at
`(y+dy,x+dx)`; dilation takes `(y-dy,x-dx)`, reflecting nonsymmetric masks.
Opening is erosion then dilation; closing is dilation then erosion using the
same configured structuring element. Each stage independently extends its input
with the selected finite-image border rule; repeated finite-image border extension
need not share every infinite-domain morphology identity.

Runtime atomic configuration: `cfg_op` 0 erosion, 1 dilation, 2 opening, 3
closing; `cfg_binary` maps any nonzero input to one, and outputs canonical 0/1;
otherwise min/max act on unsigned grayscale. `cfg_mask` is a nonempty K*K bit
set. `cfg_valid/cfg_ready` transfers all fields together. Configuration ready is
asserted only while no frame is in flight. Config has priority over a new frame
on the same edge; legal updates pulse cfg_done, empty masks pulse cfg_error and
leave the previous configuration intact. A source holding config valid while
busy must keep its fields stable; it does not interrupt the current frame.
Default after reset: grayscale erosion with every mask bit set.

Whole-frame drain is required before accepting the next frame or config. This
ensures opening/closing's later stage never processes an old frame under a new
config. Input SOF and EOL are checked by the shared window engine. Output shape
equals input shape, SOF at (0,0), EOL at x=WIDTH-1. Marker errors are sticky until
reset and do not automatically resynchronize malformed streams.

Low-active synchronous reset discards the entire in-flight frame and both
stages; RAM is not cleared. `tvalid && !tready` holds data and all markers.
No arithmetic rounding or saturation is required: unsigned min/max stays within
input range. Binary conversion is an explicit logical operation, not saturation.

Architecture: padded window → balanced min/max tree → elastic result. Opening
and closing then use a second independent padded window/tree. Single operations
bypass stage two. Tree depth is ceil(log2(K*K)), with neutral inactive leaves.
Comparator stage has no-stall latency 1 and II=1. Window stage uses one row cache
plus K synchronous banks; source row capture/replay phases limit average rate.
There is no claim of one input/output per clock across an entire frame. Dual-stage
resource cost applies even when dynamic operation selects a single stage.

Independent model, RTL regression, synthesis, P&R and board evidence are separate
gates. Initial work has no physical acceptance claim. The underlying inferred RAM
hardware mapping remains subject to the repository's current silicon investigation.
