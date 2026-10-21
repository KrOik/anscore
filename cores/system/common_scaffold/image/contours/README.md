# Exact binary cell-edge contours

`contours_cell_edges.v` traces **ordered closed contours**, including every
foreground component and every hole. It emits actual unit edges, not a
boundary bitmap. Pixels are unit square cells; lattice vertices range from
0..WIDTH and 0..HEIGHT. Geometry is fixed at elaboration, WIDTH/HEIGHT=1..4096,
with WIDTH*HEIGHT<=4096. Defaults are 32x32. This is a bounded serial tile
processor, not full-HD or real-time video throughput.

## Geometry and topology contract

Foreground is 4-connected, background 8-connected. Each exposed foreground
cell side is oriented with foreground on its right. Directions are 0=east,
1=south, 2=west, 3=north; image y increases downward. At a diagonal-touch
vertex, successor order is right turn, straight, left turn, reverse, using
the original immutable outgoing edges. Thus diagonal-only foreground cells
remain separate. Background diagonal contact can give a self-touching hole
loop. Every directed edge appears exactly once. The original edge map is
preserved separately from remaining unvisited edges so visiting a prior loop
cannot change a later successor decision.

Contour start selection is smallest remaining vertex in raster order, then
lowest direction. A contour closes when the next **directed edge** would be
its initial edge, not merely when visiting the start vertex. This preserves
self-touching contour behavior at saddle vertices.

Each output token contains the edge's lattice start m_x/m_y and m_dir.
Derive its endpoint by adding direction's unit step. m_contour_start marks
the first edge and m_contour_end the final edge; the final endpoint is the
first lattice vertex. There is no extra repeated endpoint token.
m_contour_index is zero-based per frame, m_edge_index zero-based per contour.
Only a final edge has nonzero m_area2, the signed shoelace double area.
Outer loops have positive area2; hole loops negative area2 and m_hole=1.
m_hole=0 and m_area2=0 on all nonfinal edges. Sum of all final areas equals
twice the foreground pixel count. Unit-edge token count is exact cell-edge
Manhattan perimeter. No parent-child hierarchy index is produced.

This is **not Suzuki/OpenCV pixel-center tracing or marching squares**.
Coordinates, polygon areas and Euclidean lengths of those representations
can differ, including isolated pixels. The FG4/BG8 digital topology is
explicitly comparable; no unsupported standard compatibility is claimed.

Actual network sources consulted:

- https://raw.githubusercontent.com/scikit-image/scikit-image/v0.24.0/skimage/measure/_find_contours.py
- https://raw.githubusercontent.com/scikit-image/scikit-image/v0.24.0/skimage/measure/_regionprops_utils.py

The former explains diagonal marching-squares ambiguity and complementary
foreground/background connectivity; the latter documents Euler=objects-holes.
Our unit-cell geometry is deliberately distinguished from their interpolated
contour coordinates.

## Interface and errors

Capture exactly WIDTH*HEIGHT binary pixels using `ce && s_valid && s_ready`.
s_sof must mark the first pixel only, s_eol every row end. Capture finishes
before any output. Output transfers on `ce && m_valid && m_ready`; all fields
and m_valid are held on stalls, including CE=0. No runtime configuration.
After the last contour (or immediately after scanning an empty image),
done_valid remains asserted until `ce && done_ready`. Status/counters remain
stable during held DONE. A new frame can start after DONE acknowledgement.
An empty image produces zero tokens and normal DONE.

Synchronous active-high reset overrides CE and aborts any partial operation.
RAM is not reset; complete capture and complete edge-map construction before
tracing ensure old contents cannot affect the new frame.

error_code bit0 means malformed SOF/EOL: the full frame is consumed, zero
tokens emitted, then DONE/error held. Bit1 means impossible topology/count
invariant failure: output may contain a partial prefix; discard the entire
frame. Acknowledge DONE and submit a new frame. Foreground_count counts
accepted foreground pixels, edge_count accepted output tokens, contour_count
completed accepted loops. On success final edge_count is exact perimeter.
Static unsupported dimensions cause `$fatal`. Guard bounds allow at most N
contours and 4*N edges; those are conservative for a legal N-pixel image.

Coordinates use clog2(WIDTH+1)/clog2(HEIGHT+1), counts clog2(N+1), edge count
and edge index clog2(4*N+1); each represents the inclusive maximum. Area2 is
signed 32-bit: even the conservative sum of absolute partial edge terms
4*N*max(WIDTH,HEIGHT)<=2^26 fits safely. Completed net area is <=2*N.

## Architecture and verification

Synchronous full-frame pixel RAM feeds four-quadrant vertex edge construction.
An 8-bit synchronous lattice RAM stores immutable original outgoing bits and
remaining outgoing bits. Building scans V=(W+1)*(H+1) vertices; finding each
next contour scans vertices from zero; tracing follows ordered successors
and clears one edge per token. Storage O(N+V), work O(V*contours+edges+V).
Constant-stride addresses explicitly use shift/add to avoid DSP inference.

```powershell
python -B cores/system/common_scaffold/image/contours/test_contours.py
python -B cores/system/common_scaffold/image/contours/synth_contours.py
```

The unified test invokes test_contours_protocol.py too. Results:

- 895 frames, 12989 input pixels, 14468 exact ordered output edges,
  2026 contours, 52 holes PASS.
- Independent Python oracle emits each foreground cell's exposed sides,
  constructs a directed graph and follows its fixed successor permutation.
  It does not duplicate RTL four-quadrant edge generation.
- Every 1x1, 1x7, 7x1, 2x2 and 3x3 binary mask is tested, plus random
  7x7/11x8 masks, empty/full/rings/checkerboards, border contact, diagonal
  saddles, isolated topology and malformed-marker recovery.
- Every valid frame checks actual skimage0.25.2 FG4 component counts and
  BG8 hole counts through Euler; cell-edge oracle checks exact area and
  perimeter. Marching-squares Euclidean perimeter is not treated as equal.
- CE/output stalls, held OUT/DONE payload and validity, multi-frame
  recovery PASS. Reset at CE=0 during capture, build, scan, held output and
  held DONE PASS, followed by a complete 16-edge square recovery. Four
  invalid geometry cases are rejected.

Isolated synth_gowin + check-assert PASS. Default32x32: 635 LUT1..4,
285 ALU, 276 FF, 1 DPX9B and 64 RAM16SDP4. Maximum square64x64:
570 LUT1..4, 314 ALU, 308 FF, 1 DPB and 3 DPX9B. MUX2_LUT5 counts
61/66 respectively. Both use **0 DSP**. Initial constant multiplication
address expressions inferred DSP; explicit shift/add fixed this and all
simulation/synthesis checks were rerun. These are isolated resource counts,
not integrated device utilization or placed/routed timing proof.

Builds use TemporaryDirectory; only small JSON evidence remains.
**Not board verified.** No cryptographic or side-channel claim.
