# Exact symmetric Hausdorff distance between binary shapes

`binary_hausdorff` compares two full aligned binary masks. It returns each
directed worst nearest-neighbor squared Euclidean distance, their maximum,
and both source/target witness pairs. Raw mask bits enter the RTL; no host
distance field, point list, nearest-neighbor result or summary is supplied.
This is a symmetric worst-case shape-distance service, distinct from directed
mean Chamfer template scores, distance maps and polyline simplification.

Status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
Only [verification.json](verification.json) qualifies the finite checks. No
synthesis, PnR, STA, board or expanded
regression is run. Maximum32x32 numerical processing is NOT_RUN, compile-only.

## Exact metric and deterministic witnesses

A and B are coordinates whose respective mask bit is1. For both nonempty:

```text
h2(A,B) = max(a in A) min(b in B) ((ax-bx)^2+(ay-by)^2)
H2(A,B) = max(h2(A,B),h2(B,A))
```

`m_ab_distance_sq`, `m_ba_distance_sq` and `m_distance_sq` return those three
unsigned integers. Euclidean Hausdorff distance is sqrt(H2); no square root or
approximate scalar is computed. Both inner nearest-target ties and outer
farthest-source ties choose the lowest raster index y*WIDTH+x. Every source
and target witness is a real set member. A->B and B->A witnesses refer to
their corresponding source and target masks. `m_direction=1` selects B->A
when it is strictly larger; equal directed distances choose0/A->B.

The metric is zero exactly when the two nonempty masks coincide. The image
boundary does not introduce outside points. Shared zeros are not features.
There is no translation search, image registration, ROI, subpixel coordinates,
percentile Hausdorff, average surface distance or threshold approximation.

Empty masks make this finite service undefined. Independent `m_errors[0]`
and `[1]` mean A/B empty. Bits2/3 are sticky SOF/EOL framing mismatches.
All16 patterns are reachable, including malformed empty frames. Any error
returns zero directed/symmetric distances, direction and all witnesses;
actual mask populations and first tag remain diagnostic.

## Handshake, frame ownership and reset

One rising-edge clock, synchronous active-high rst, ordinary ready/valid and
no external CE/CDC/configuration. Accept only valid&&ready. The source holds
both mask bits, SOF/EOL and tag until acceptance or reset. Supply exactly
WIDTH*HEIGHT paired pixels in row-major order. SOF is true only on the first
pixel; EOL exactly on every final column. Static dimensions close the frame;
there is no last input or marker-based restart. Missing inputs wait normally.

The first accepted tag owns even a malformed frame; later tags are ignored.
Marker errors never shorten capture. Correct markers are regenerated for the
child EDT, preventing its fail-stop behavior from truncating external drain.
After all N pixels, an empty/malformed frame produces one canonical error
response. Valid frames finish both complete distance maps before responding.

Every response field holds under arbitrary sink backpressure. No new input
enters during map work, replay, completion or held response. After response
retirement, one BOOT edge clears frame ownership and resets the child; the next
input can first transfer two edges after retirement. Source/sink stalls have
no unconditional wall-clock bound. Reset gates ready/valid low immediately,
cancels all phases at its edge and clears scalar output state. Mask and child
RAM are unreset: a complete fresh paired capture and complete child passes
overwrite every location before read. No canceled response survives reset.

The existing child has active-low reset and CE-qualified transfers. This
wrapper converts reset, ties child CE high, couples the initial child/external
capture handshakes exactly, and owns all later child inputs/outputs. External
users must follow this wrapper's ordinary ready/valid contract.

## Real composition, widths and resources

WIDTH/HEIGHT1..32, TAG_W1..32; default16x12/T8. There are no runtime settings,
vendor primitives, generated tables, external RAM or address-map errors.
XW/YW=max(1,clog2(W/H)); CW=max(1,clog2(N+1));
DW=max(1,clog2((W-1)^2+(H-1)^2+1)). Default CW/DW8/9, maximum11/11.
Maximum squared distance1922 is exact; there is no rounding or saturation.

The complete unchanged repository [EDT](../../system/common_scaffold/image/euclidean_distance/README.md)
is instantiated once. During paired capture, B is inverted into its zero-
feature input while a2-bit paired-mask RAM is written. Each B-distance map
point synchronously reads that RAM, then reduces the A-selected distances.
After child completion, A is synchronously replayed from the same RAM and its
map reduced at B-selected locations. Strict improvement preserves first raster
farthest ties; the child's exact nearest-coordinate tie rule supplies targets.
The child computes separable exhaustive1-D min-plus passes, not an all2-D-pairs
matrix. The wrapper adds no runtime multiplier/divider or second EDT instance.

Mask reads/writes occupy disjoint states, as do child memory phases. Initial
paired input II1 is possible. Replay II2 and mask-map consumption add one held
cycle per child map point; both scans always finish every map point, selected
or not. States are BOOT, CAPTURE, CHECK_FRAME, MAP_READ, MAP_EVAL, WAIT_DONE,
FEED_READ, FEED_SEND and EMIT; phase distinguishes the two transforms.

From final paired input edge E to first visible result:

```text
valid nonempty frame: 4*N*(WIDTH+HEIGHT+3)+2 periods
any error: 1 period
```

Default23810, globalmaximum274434,1x1normal22 periods. These include both
transforms, full map reductions, replay and completion. Earliest output
transfer is the following edge. No frequency, video rate or power is measured.

Logical RAM is the new2N-bit mask plus child N*(2+3XW) bits, total
N*(4+3XW):3072 default /19456 maximum. Wrapper scalar/read/output declarations
use15+3AW+6XW+4YW+2CW+TAG_W+2DW bits (AW=max(1,clog2 N)):121/171.
Child scalar/read/output declarations add156+8XW+4YW bits:204/216, total
325/387. These are declaration budgets, not mapped RAM/FF/LUT measurements.
Architecture risk LOW default/MEDIUM maximum is qualitative; reused child
arithmetic/RAM mapping and geometry-dependent service time need physical review.

## Offline closure and finite matrix

[files.f](files.f) lists new wrapper first (establishing simulation time units),
then the existing baseline EDT source. [example/files.f](example/files.f) adds
`shape16`. The complete offline closure has two production sources/three with
the example. The dependency is SHA256-bound in [SOURCES.md](SOURCES.md) and the
report and remains unchanged. No child historical synthesis or numerical scope
is promoted by this new composition's tests.

Run `python run_tests.py` from any directory with Python standard library and
repository-native Icarus/vvp. [TEST_PLAN.json](TEST_PLAN.json) predates the first
compiler/simulator: nine profiles,508 frames/10096 paired pixels, exhaustive
all256 paired2x2 masks, maximum32-square compile-only, six invalid profiles and
28 commands. Every child has20-second limit; any timeout is terminal with no
retry, fixture shrink or longer limit. Ordinary failures retain original hashes
and records before the unchanged matrix can be repaired and rerun.
Positive compiles use `-Wall -Wno-timescale`: only the unchanged child's
inherited time-unit warning is suppressed; all other diagnostics fail.

The independent oracle enumerates2-D point sets and max-min integer distances,
including exact witnesses and tie rules. TB separately checks every child map
distance/nearest coordinate by brute-force2-D search, every mask replay, complete
frame work, all public fields, errors/tags, exact tail, source stability and held
response. Twenty observed phase resets/profile (partial capture skipped at1x1)
are canceled before another active edge, then followed by a complete analytic
opposite-corner pair, hold, retirement and no-stale-output checks. Main totals
exclude reset/setup/fresh traffic; aggregate internal and stall counters include
it. This finite evidence does not establish exhaustive or hardware correctness.

The original28-command attempt passed without failure or timeout: nine complete
profiles, six expected parameter rejects and the predetermined maximum-square
syntax check. Main508 frames comprise342 valid/166 error responses,10096
paired pixels,508 exact tails,10224 child map records and5112 raw-mask replay
checks. Profile normal delays are22/310/310/114/326/2562/23810/4610/4610;
any error delay is1. Maximum actual numerical area192 and measured tail23810
remain distinct from the compile-only32-square and its algebraic274434 bound.

On valid main results, A->B is larger88 times, B->A80 and equal174;46 symmetric
distances are zero and296 nonzero. There are566 selected-source inner searches
with multiple nearest targets and194 directed results with multiple farthest
sources. All16 error patterns occur in every profile. All returned witnesses
and both tie policies are checked as part of the complete packed response.

There are179 immediate cancellations and179 complete fresh recoveries. The
inclusive internal monitors check26098 child map records,12887 replayed mask
pixels and4174 selected-source reductions. Held cycles3131 and blocked-source
cycles54 include probe/setup/fresh traffic; the blocked offers are the two held
normal/error reset targets per profile. Main-only map/replay counts are separate.
After successful completion, only documentation qualification and report hash
packaging changed; RTL/TB/oracle/plan/fixtures and all tool records are unchanged,
and no numerical check was rerun.
