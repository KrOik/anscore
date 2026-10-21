# Iterative Zhang–Suen binary thinning

`zhang_suen_thinning.sv` implements the explicit two-subiteration Zhang–Suen
deletion rules on a binary image, not one-pass morphology or medial-axis
distance skeletonization. Repository-wide filename/content searches found no
existing Zhang–Suen/thinning equivalent before this addition.

For a foreground center, neighbors p2..p9 run clockwise from north. B is their
foreground count; A is the circular count of 0→1 transitions. A pixel is deleted
only if 2<=B<=6 and A=1, with these additional conditions:

| subiteration | both products must equal zero |
| --- | --- |
| 0 | p2*p4*p6, p4*p6*p8 |
| 1 | p2*p4*p8, p2*p6*p8 |

Every pixel decision in a subiteration reads the same immutable source bank.
Decisions are written into the other RAM bank; the banks swap only after the
entire subiteration. The second subiteration therefore sees all first-phase
deletions simultaneously. No pixel is deleted in-place while neighbors are
still being evaluated. Border neighbors outside the image are zero; boundary
foreground pixels are evaluated, not forcibly preserved.

## Bounded convergence and errors

MAX_ITERATIONS counts complete pairs of subiterations, including the final
no-change pair used to prove convergence. Range is 1..65535. If neither phase
deletes a pixel, converged becomes 1 and iterations reports that pair count.
If a pair changed pixels and exhausts the limit, converged remains 0 and
error_code=2. The current bounded candidate image is still emitted, explicitly
marked **not converged**; the core does not silently claim a completed skeleton.
A result that happens to become a fixed point on the last deleting pair still
requires a later no-change pair to prove convergence.

Input is binary (one bit), row-major, with SOF exactly at (0,0) and EOL exactly
at each final column. Missing/mispositioned markers abort capture, set
error_code=1, pulse done and return idle without output. Discard the remainder
of that bad input frame externally and restart with fresh SOF; the next first
input clears diagnostics. done also pulses when the last successful/candidate
output is accepted. converged, iterations and error_code remain stable while
the result streams, including stalls. No data output is generated until all
iterations have stopped.

WIDTH/HEIGHT are positive static parameters with WIDTH*HEIGHT<=65536. Products
are checked using 64-bit arithmetic before declaring memory; invalid geometries
clamp the declaration and fail the initial guard. Two banks store 2*W*H bits,
with one registered synchronous read and one write per processing step.
Nine neighborhood reads cost 18 cycles, followed by calculate/store: each
subiteration costs 20*W*H enabled cycles. After I pairs, first valid output
appears 40*W*H*I+2 enabled edges after final capture. Output II=3 enabled cycles
without stalls. This is a resource-bounded frame core, not a line-rate design.

All transfers require **ce && valid && ready**, with CE honored by both
neighbors. Output data/markers/valid remain stable during CE pauses and
backpressure. Reset is synchronous active-low, overrides CE, discards pending
work/output, clears status and resets the source-bank selection. Memories are
not reset: each new frame fully overwrites source bank zero before processing.
While reset is asserted no transfer is valid, even if combinational ready is
high; producers must hold valid low until reset is released.

## Independent evidence and variant boundaries

```
python -B cores/system/common_scaffold/image/thinning/test_thinning.py
python -B cores/system/common_scaffold/image/thinning/synth.py
```

The independent Python reference accumulates a set of deletions and applies
it only after each full phase. Seven geometry/limit variants verify 63 frames,
2187 output pixels: empty/full images, thin lines, crosses, rings, solid
rectangles, diagonal bands, random/sparse images, 1x1 and single rows/columns.
MAX1/MAX2 fixtures produce nine directed not-converged results, checking exact
candidate pixels, iteration count and error status. Tests cover valid gaps,
ready stalls, CE pauses, stalled stability, marker recovery, reset during RAM
processing, reset of a stalled output with CE low and four illegal geometries/
limits. Temporary binaries are automatically removed.

An actual HTTPS fetch of
[scikit-image v0.24 skeletonization source](https://raw.githubusercontent.com/scikit-image/scikit-image/v0.24.0/skimage/morphology/_skeletonize.py)
provided an algorithm/documentation reference; reference.json stores its SHA256.
No source implementation was copied. Its documented Zhang84 lookup-table
variant is also compared diagnostically when installed. The local installed
skimage comparison differs by 32 total pixels across the 45 unlimited-limit
fixtures (differences occur on nontrivial 2D shapes). These results are retained
in evidence.json; the explicit two-phase oracle was not changed to fit that
LUT variant. **No skimage bit-compatibility is claimed.** The implementation and
contract above define the exact thinning variant being delivered.

Default 16x16 isolated Gowin synthesis (`-noalu -nodsp`) reports 497 LUT1-4,
45 MUX2_LUT5, 1 MUX2_LUT6, 114 FF, 32 RAM16SDP4 and zero DSP; CHECK reports
zero problems. No P&R, clock target or board validation is claimed.
