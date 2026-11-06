# Tetrahedral RGB grading with frame-atomic background LUT loading

Current state: **RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
No model, runner, compiler, simulation, synthesis, PnR, STA, board or PPA
execution has occurred for this candidate. Frozen `STATUS.md` remains the
pre-execution record; any later qualification must use separate evidence metadata.

The core applies a runtime 3D RGB cube using four-vertex tetrahedral interpolation.
It differs numerically and architecturally from the existing eight-vertex,
single-table trilinear `common_scaffold/image/color_lut3d` implementation.
It adds frame-boundary publication of an inactive table loaded while the current
frame continues, without storing the input or output frame.

`BITS=8..12`, `GRID_LOG2=1..4`, `WIDTH/HEIGHT=1..4096`, `TAG_W=1..32`.
The cube has `N=2^GRID_LOG2+1` nodes per axis: 3, 5, 9 or 17. Every node holds
three unsigned BITS-bit channels in `{R,G,B}` order. Sequential LUT addresses
are `r+N*g+N*N*b` (R fastest). No initialization file is required in hardware.

All transfers are `valid && ready` at the rising clock. Reset is synchronous,
active high; it cancels both configuration and frame transactions and invalidates
both banks without resetting RAM contents. There is no CE or CDC in the new core.
The actual reused grayscale block has its own CE/RV adapter in the example.

Configuration starts with `cfg_begin_valid/ready`, followed by exactly `N^3`
`lut_valid/ready` tokens. `lut_last` must equal the final-address predicate on
every accepted token. An early or missing last discards the staging table and
returns configuration error 1; existing active pixels and the active table
remain intact. A good load returns configuration error 0 and marks the table
pending. Hold `cfg_rsp_valid` until its response handshake. A new load is
accepted only after that response retires and no pending table remains.

A frame command `c_valid/ready` snapshots `c_tag` and selects a table. A table
already pending before that edge becomes active; otherwise the current table is
used. A table completing on the same edge is eligible only for a later command.
`configured` means an active table exists; `table_pending` separately reports a
complete unpublished table. A command with neither returns frame error 1 and
accepts no pixels. Configuration completion does not itself activate a table.

The command owns exactly WIDTH*HEIGHT raster inputs. `s_sof` is true only at
(0,0), `s_eol` only at x=WIDTH-1, and `s_last` only at the final pixel. Any
accepted marker mismatch returns frame error 2, produces no result for that
input and cancels the remainder. Earlier frame results are provisional until
successful DONE; there is no rollback framebuffer. Frame error 3 denotes an
illegal FSM state. `d_valid/error/tag` remain stable until `d_ready`.

Pixels, coordinates, markers and tags remain stable under output backpressure.
The next source pixel is accepted only after the previous result retires.
The next frame command is fenced behind DONE retirement. A continuously
asserted future command is not sampled until its own handshake.

With no gaps or output stalls, the source initiation interval is 20 clocks;
result valid appears 18 clocks after its source handshake. Background table
loading has an independent one-token-per-clock RTL interface (the finite TB
deliberately inserts gaps). These are cycle contracts, not measured FPGA rates.
Default two-bank storage is 34,992 bits (BITS8/grid9); maximum is 353,736 bits
(BITS12/grid17), plus small scalar/vertex state. Risk is LOW at default and
MEDIUM at maximum. No synthesized resource, power or frequency claim is made.

`example/graded_luma_preview.sv` composes this core with the actual unchanged
`cores/system/extended_library/src/isp_rgb2gray.v`. Its registered formula is
`Y=(77R+150G+29B)>>8`. A single owned output slot holds coordinates/tag/markers
and gates DONE until the last grayscale result retires. It adds one clock from
the core result handshake to external luma retirement when ready is high.

Use `files.f` or `example/files.f` from this package directory. No external
downloads are required. `freeze.ps1` performs metadata-only sealing; the
Python runner requires a complete independent root source NO_BLOCKER proof and explicit
root unique execution authorization. Do not execute a model or HDL pre-review.
