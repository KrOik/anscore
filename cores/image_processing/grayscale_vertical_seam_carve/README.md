# Grayscale vertical seam removal

`grayscale_vertical_seam_carve` consumes one unsigned8 grayscale frame, computes
an exact minimum-energy vertical8-connected seam, and emits the frame with that
one pixel per row removed. It includes gradient calculation, dynamic programming,
traceback and actual raster compaction. The output geometry is `(WIDTH-1)×HEIGHT`.
The existing `common_scaffold/image/seam_find` emits a stitching mask for two
aligned images and explicitly excludes pixel removal; it cannot substitute for
this function. Existing scalers preserve regular sampling coordinates rather
than selecting a connected low-energy seam.

Original Apache-2.0 RTL; dependencies are fully contained in this directory.
Run `files.f` and `example/files.f` from this **package root**. The example exposes
all interfaces at the default16×16 geometry. No external memory or ROM data is
needed. Python3 standard library and Icarus are required only for verification.

## Interface and ownership

All signals use the rising edge of `clk`. `rst` is synchronous active-high, takes
priority over every transfer, cancels the complete service, and invalidates any
pending output/completion. There is no CE and no CDC. Ready/valid transfers occur
on edges with `valid && ready && !rst`; do not connect a CE-qualified stream
without an adapter. Each producer holds all its fields while blocked.

`c_valid/c_ready` accepts a new frame command and `c_tag[TAG_W-1:0]`. Only one
service can be active. `c_ready` stays low until its completion is acknowledged;
there is no retirement-edge fallthrough. Geometry is elaboration-time only:
`WIDTH=2..64` (default16), `HEIGHT=1..64` (default16), `TAG_W=1..32` (default8).
Unsupported parameters deliberately reference a missing named module.

After the command, `s_valid/s_ready` accepts exactly `WIDTH*HEIGHT` `s_pixel[7:0]`
values in row-major order. `s_sof` must be1 on only the first sample, `s_eol` on
every row's final sample, and `s_last` on only the frame's final sample. Bad
markers immediately stop capture and produce an error completion **before any
output pixel is emitted**. Remaining source pixels from that service must be
discarded by the caller. `s_ready` is low outside capture; arbitrary input gaps
are permitted.

After complete capture and calculation, `m_valid/m_ready` emits the compacted
frame. `m_sof/m_eol/m_last` follow the reduced geometry, and `m_removed_x[6:0]`
repeats the original seam column for the output pixel's row. Data, all markers
and the witness remain stable under arbitrary output stalls. Output order
preserves the relative order of all retained pixels. No input/output overlap is
supported. Outputs have no meaning while their valid is low.

After the final output transfer, `d_valid` holds until `d_ready` acknowledges.
`d_error=0` means success; `d_cost[15:0]` is the exact total seam energy and
`d_tag` echoes the command tag. `d_error=1` means malformed input markers, with
cost0. Tag, error and cost remain stable while blocked. Acknowledge an error to
start a new frame without reset. A successful completion is produced only after
all reduced pixels have transferred. No abort port exists; reset cancels work in
capture, calculation, held output or held completion. If reset follows partial
output, the caller must discard that partial frame.

## Exact objective and ties

For source image `I`, repeated edge samples implement clamped boundaries:

```text
E(x,y) = |I(min(x+1,W-1),y)-I(max(x-1,0),y)|
       + |I(x,min(y+1,H-1))-I(x,max(y-1,0))|
```

The seam contains one column `s[y]` at every row with
`|s[y]-s[y-1]|<=1`, minimizing `sum(E(s[y],y))`. Its start/end are unrestricted.
An equal-cost predecessor chooses the smaller column; equal-cost terminal
columns choose the smaller column. Equivalently this is the lexicographically
smallest **reversed** column path among all optimal paths. It is not a claim of
lexicographically smallest top-to-bottom path. A uniform image removes column0.

Each energy is0..510 and total cost0..`510*HEIGHT` (at most32640), represented
exactly with no saturation, division, rounding or fixed-point interpretation.
This backward central-difference objective is explicitly different from Sobel
energy and forward-energy seam-carving implementations. Repeated seam removal,
horizontal removal, enlargement, RGB, protect/drop masks and arbitrary runtime
geometry are outside this core's behavior.

## Architecture and feasibility

The FSM serializes four pixel reads per energy and up to three predecessor-cost
reads. Array reads are clocked; no multi-read combinational frame cone or
unrolled path search is used. Two alternating DP rows preserve predecessor
values while the next row is written. Complete parent coordinates support exact
traceback. Frame/parent/DP arrays are not reset: complete successful capture and
the forward pass overwrite all locations before reading them. Only the seam
row registers use asynchronous selection during output. Same-address RAM
read/write collisions are not required by the schedule. There is one clock and
no vendor primitive.

Memory bits are `8*W*H + clog2(W)*W*H + 2*W*clog2(510*H+1)` plus
`clog2(W)*H` seam registers (using at least1bit for the coordinate).
Default16×16:2048pixel bits,1024parent bits,416DP bits,64seam bits.
Maximum64×64:32768pixel bits,24576parent bits,1920DP bits,384seam bits.
**Resource risk MEDIUM**: dimensions grow quadratically, and exact RAM packing,
address arithmetic, BRAM inference and target fit remain unmeasured. The default
is intentionally small. There are no multipliers on pixel values and no DSP
requirement. Constant address arithmetic still needs logic.

The first row takes7calculation cycles/pixel; later rows take12cycles/pixel at
the boundaries and14inside. Terminal selection takes2Wcycles, traceback at most
2H, and output takes2cycles/pixel with an always-ready sink. From final input
acceptance to first output-valid, `14*W*H+2*W+2*H+2` is a conservative bound.
Output stalls add directly; arbitrary stalls have no unconditional completion
deadline. These are RTL schedule bounds, not measured hardware throughput.

## Finite verification

Run from the repository root:

```powershell
python -B cores/image_processing/grayscale_vertical_seam_carve/run_tests.py
```

Every compiler/simulator child has a20second wall-clock limit. The runner uses
the absolute repository OSS CAD tool paths. Five deterministic geometries are
2×1,3×5,5×4,16×16,64×64. Six fixtures cover black/white, ramp, checkerboard,
seeded random and curved low-value structure. An independent Python reference
keeps complete reverse path tuples and additionally enumerates all admissible
paths for the small geometries; the RTL uses scalar RAM and traceback instead.
Every emitted pixel, marker, seam row and total cost is checked. Each geometry
includes14complete checked frames, three marker errors followed by healthy
recovery, input gaps/output stalls, held completion, and reset during capture,
calculation, held output and held completion.

The initial maximum-geometry attempt reached the fixed10ms **TB simulation-time**
watchdog without a reported data mismatch. Raw failure and its VVP are retained.
The TB watchdog now scales conservatively with geometry; input fixtures,
reference objective, expected pixels/costs and20second wall limit were unchanged.
`--profile 64x64` runs only that fixed profile and omits repeated standalone
lint/example checks. The exact actual results and checked source hashes live in
timestamped `evidence/*/results.json`, with raw stdout/stderr and input/golden
hex data. Successful VVP copies are removed by the runner after successful
simulation; failed VVP is preserved.

Qualification is limited to the recorded `LINT_PASS + UNIT_SIM_PASS` checks;
all hardware remains `HW_UNVERIFIED`. No synthesis, placement/routing, STA,
board execution, Fmax, power or measured area evidence is claimed. The Icarus
test compile emits a missing RTL timescale warning; the DUT has no delays and
TB timing is explicitly1ns/1ps.

### Runner safety revision after qualification

The delivered `run_tests.py` now launches children with `Popen/communicate` and
starts cleanup at its20second execution deadline. On Windows it attempts
`taskkill /PID ... /T /F` (5second cleanup bound), then a parent-kill fallback
and a2second bounded pipe drain. Cleanup failures/timeouts are recorded.
POSIX uses a new session and process-group kill. A missing executable produces
a `NOT_RUN` record with raw stderr; a timeout produces `TIMEOUT`. The main
sequence records the failure and stops before later child launches; its final
receipt still writes if process-tree cleanup fails.

The prior finite RTL/TB evidence remains valid for its recorded source bytes.
The exact previously executed runner is retained at
`history/run_tests.executed.py.txt`, SHA-256
`4fecaa2db23681bbb46e4e69ffb494d3e22b60b3ed20e8e4b4e0fc9071c4d6ff`.
The final runner safety revision received source/syntax review and one deliberate
missing-executable probe, recorded in `reports/runner_safety_review/results.json`.
No numerical preparation or HDL suite was rerun for this runner-only change.
Runtime execution of its timeout/process-tree cleanup path remains `NOT_RUN`;
the previous execution receipts do not claim to cover the final runner bytes.

The initial five-profile attempt used an earlier runner, recovered byte-for-byte
at `history/run_tests.initial.py.txt` and verified against that attempt's receipt:
SHA-256 `9299a06462df0affbad51eab9253d93baeebdd7cbf622dc5b28528f8a3117e53`.
Between this initial runner and the targeted executed runner, the only helper
changes added `argparse`, the fixed-profile `--profile` selector, omission of
standalone lint/example checks for a selected profile, and reporting the selected
profile list. The oracle, fixture construction and HDL child execution helper
were unchanged. The separate TB edit changed only its simulation-time watchdog.
Recovery used deterministic text reconstruction and SHA-256 comparison;
the reconstructed helper was not executed.
