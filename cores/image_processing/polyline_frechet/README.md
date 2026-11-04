# Exact discrete Frechet curve matching with optimal coupling

`polyline_frechet` compares two **ordered** signed-integer2-D point sequences.
It returns the exact squared discrete Frechet distance and a complete optimal
monotone coupling, from the two final points back to the two first points.
A coupling starts at(0,0), ends at(nA-1,nB-1), and advances by(1,0),(0,1)
or(1,1); its cost is the largest squared Euclidean distance of any matched
pair. The core minimizes that cost. A point can be repeated in the coupling;
input points are never sorted, deduplicated, resampled or implicitly closed.

This fills a distinct semantic gap. Existing `polyline_rdp` simplifies one
curve; `point_convex_hull` removes input order; `binary_hausdorff` compares
unordered mask sets. For A=[(-1,0),(0,0),(1,0)] and B in reverse order,
Hausdorff distance is zero but this core returns squared Frechet distance4.
This is the discrete vertex objective, not continuous-segment Frechet, dynamic
time warping's sum cost, cyclic-start matching or a raster distance transform.

## Arithmetic and deterministic path

Let d(i,j)=||A[i]-B[j]||^2. The boundary scores are cumulative maxima along
the first row/column; an interior score is
`F(i,j)=max(d(i,j),min(F(i-1,j-1),F(i-1,j),F(i,j-1)))`.
The returned `m_distance_sq` is F(nA-1,nB-1). At each interior cell the chosen
predecessor has minimum predecessor score, with diagonal, then up, then left
priority on equality. This local rule defines the exact returned path. It does
not promise a lexicographically minimal complete path, or minimum path length
among all globally optimal couplings. Traceback emits the endpoint pair first
and(0,0) last, allowing output without a second path stack.

Coordinates are two's-complement W-bit integers, no fractional bits. Differences
are extended to signed W+1 before subtraction; unsigned magnitudes are at most
D=2^W-1 and fit W bits. A square fits2W bits and the sum fits DW=2W+1 bits,
because `2*D^2 < 2^(2W+1)`. Every DP operation selects or maximizes such values.
There is no square root, division, floating point, tolerance, rounding or
saturation. One unsigned shift-add square engine is shared by X and Y in every
cell. Both squares always run exactly W steps, including zero or identity input;
the final partial sum includes the last multiplier bit.

## Stream and reset contract

All ports use one rising-edge clock, synchronous active-high `rst`, ordinary
ready/valid, and **no CE**. Each `valid && ready` edge transfers. A CE-qualified
legacy stream needs its own transfer adapter. Assert reset across an edge to
cancel capture, arithmetic, traceback or any held result. Public valid/ready
are gated low immediately while reset is high; ownership clears at the edge.
RAMs are unreset. Current-transaction capture, first-row writes and complete
trace writes precede every consumed RAM entry. No aborted point, row or trace
can be published by a fresh transaction.

| Port | Meaning |
| --- | --- |
| `s_a_x/s_a_y`, `s_b_x/s_b_y` | signed W-bit input coordinates |
| `s_a_keep/s_b_keep` | independently append the corresponding point |
| `s_last` | terminate both sequences, even on a doubly masked token |
| `s_tag` | opaque tag, latched on the first accepted token even if masked |
| `m_a_x/m_a_y`, `m_b_x/m_b_y` | unchanged coordinates of this coupling pair |
| `m_index_a/m_index_b` | original ordinal among retained points in each list |
| `m_count_a/m_count_b` | retained lengths, repeated on every response |
| `m_distance_sq` | complete-transaction optimum, repeated on every pair |
| `m_first/m_last` | first reverse pair and final(0,0) pair |
| `m_empty/m_errors` | canonical error indication described below |
| `m_tag` | first accepted input tag, repeated on every response |

The two keeps permit unequal lengths and independently staggered lists. Masked
points consume no capacity and do not change sequence order. Both lists are
terminated by the same last token; an all-masked transaction represents two
empty lists. Later tags are ignored. Source must hold all token fields stable
while valid and not ready; a missing last leaves capture open until completion
or reset. There are no SOF/EOL markers, runtime configuration, CDC, external
memory errors or implicit input-length timeout.

Error bits are emptyA(bit0), emptyB(bit1), overflowA(bit2), overflowB(bit3).
Each list retains its first MAX_POINTS selected coordinates, saturates its count,
and latches overflow on any further selected token while draining through last.
It cannot be both empty and overflowed. Exactly codes0,1,2,3,4,6,8,9,12 are
reachable; the other7 are impossible. Any nonzero error returns one token with
empty=first=last=1, zero distance/indices/coordinates, saturated retained counts
and the first tag. No prefix distance or coupling is reported. For every normal
pair empty=errors=0, both lengths are positive and the path contains between
max(nA,nB) and nA+nB-1 tokens. Error code0 is an ordinary nonempty result.

Capture accepts one token per clock. Processing and response block all input.
All output fields remain stable under arbitrary backpressure. A response
transfer advances traceback only; the final transfer releases capture for the
following edge. The first response becomes valid exactly
`3+nA*nB*(2*W+4)` periods after the last accepted input, or1 period on error.
At full default lengths the normal tail is7171, at maximum53251. Additional
coupling tokens become valid2 periods after the preceding transfer, giving
always-ready transfer II=3. Arbitrary source/sink stalls have no finite bound.
No continuous-video rate or clock frequency is claimed.

## Parameters and architecture budget

| Parameter | Default | Legal values |
| --- | ---: | --- |
| COORD_W | 12 | 2..24 |
| MAX_POINTS | 16 | 1..32, independently for each list |
| TAG_W | 8 | 1..32 |

IW=max(1,clog2(MAX_POINTS)), CW=max(1,clog2(MAX_POINTS+1)); indices/counts
use those widths. Illegal parameters produce a named elaboration rejection.
All supported parameters are static, with no online generation dependency.

Two packed coordinate banks have one capture write and one synchronous scheduled
read each. A single row buffer retains previous-row scores; registers hold the
current left and previous diagonal. First-row reads are deliberately ignored
where unwritten. A packed2-bit/cell predecessor bank retains the complete DP
trace. Reads and writes are in different phases, with no same-cycle collision.
Trace addresses advance by constants/lengths and subtract1,MAX_POINTS or
MAX_POINTS+1 on traceback; no variable multiplier implements addresses.

Logical RAM bits are `4*W*M+(2*W+1)*M+2*M*M = M*(6*W+1)+2*M*M`:
1680 at defaults and6688 at maximum. Actual RAM inference/granularity is unknown;
small banks may map to distributed memory or registers. Sequential scalar bits,
including unreset read registers and public data, are
`28*W+20+4*IW+TW+BW+2*CW+TAG_W`, with TW=max(1,clog2(M*M)) and
BW=max(1,clog2(W)):402 default/771 maximum. RAM plus scalars is2082/7459.
These logical bit counts are not physical FF/LUT/BRAM measurements.

Work is O(nA*nB), storage O(M^2) for returned-path provenance; a score-only
architecture could remove trace storage but would not supply this coupling.
No runtime `*`, divide, combinational unrolled pair matrix, vendor primitive,
external RAM, ROM or reset sweep is present. A shared2W-bit adder, wide
min/max comparators, coordinate subtract/absolute logic and RAM decode are the
main structural risks. Risk is **LOW** at defaults, **MEDIUM** at maximum;
timing, power, physical area and device fit remain unknown. Serial arithmetic
trades throughput for a bounded operator budget; no low-power claim is made.

## Offline example and frozen evidence

`files.f` closes the single production RTL source. `example/files.f` adds
`trajectory_match.sv`, a default equally sampled trajectory frontend tying both
keeps high and exposing all coupling metadata. Unequal-length clients use the
core directly. No old RTL is modified or silently protocol-connected.

Run `python -B cores/image_processing/polyline_frechet/run_tests.py` offline.
Only Python standard library and repository-native Icarus/vvp are needed.
`TEST_PLAN.json` freezes six numerical profiles, including2/1/1,2/5/3,
4/4/8,8/8/8,12/16/8 and maximum24/32/32. It fixes666 main pairs,
3248 tokens,2083 coupling/error outputs,12132 DP cells and422860 square
steps. The4/4/8 profile contains all256 pairs of two-point signed2x2-grid
curves and all196 pairs of binary-line curves of lengths1..3. Fixtures also
cover signed extrema, zero and nonzero scores, order-sensitive Hausdorff gaps,
unequal lengths, repeat/closed paths, all nine reachable errors, first masked
tags, changing later tags, source gaps and2035 consecutive accepted II1 checks.

The independent oracle performs heap-based minimax search on the monotone grid,
not the RTL's row DP, then independently certifies the final optimum by threshold
BFS reachability at the result and failure at the next lower pair distance.
It derives every cell score and exact canonical reverse coupling. The TB checks
every public field, point/previous-row read, predecessor selection, pair distance
with64-bit arithmetic, DP write value and trace read. All eleven states and both
square endpoints are covered.119 immediate reset probes each require a full
analytic fresh recovery, exact latency, all path tokens, held result, retirement
and no stale output. Capacity1 skips the impossible held-middle label; its
singleton store/held-endpoint labels intentionally alias. Blocked source checks
are limited to three cycles at each held-first/middle/last/error reset target
(middle skipped at capacity1), and that source is canceled only by reset.

Exactly21 bounded HDL children are planned: version, two syntax, six compile/
simulation pairs and six named invalid-parameter rejects. Each child has a
strict20-second timeout. A timeout is terminal, with no retry, fixture shrink
or increased limit. Ordinary failures are retained in subsequent evidence.
Temporary simulator artifacts are removed; full TB/oracle/fixture descriptions
and hashes remain offline. Source files are strict UTF8/LF from inception.

Current `verification.json` records all21 planned children **PASS** and the
exact frozen totals above:618 valid/48 error transactions,666 exact first
latencies,12132 point/row/predecessor/cell checks,2035 trace reads and119
complete fresh recoveries. Coverage includes152 order-sensitive Hausdorff gaps,
169 unequal-length pairs,372 repeated-point pairs,7968 tied predecessor cells,
85 zero and533 nonzero results.4600 main/fresh held cycles and69 blocked
source cycles passed, with the limited blocked-source scope described above.
Every profile reached the complete eleven-state mask. The maximum profile is
numerically simulated; it is not compile-only.

One prior ordinary failed attempt is retained in full: Icarus rejected
`$fscanf` directly into dynamically indexed singleton score/trace TB arrays.
Only the TB loader was changed to read scalar temporaries before assigning
the arrays. The frozen plan, fixtures, RTL and all other source bytes were
unchanged; no timeout occurred. The exact complete matrix then passed.
After this PASS, only documentation and report packaging were updated;
the report preserves the previous report SHA, old/new README hashes and all
nine unchanged source hashes. A subsequent read-only correction fixes the default
scalar/combined budget totals; both refresh receipts remain. No HDL or oracle
was rerun for either documentation refresh.

Maturity: **LINT_PASS, UNIT_SIM_PASS, INTEGRATION_CANDIDATE, HW_UNVERIFIED**.
The example is only an integration candidate; there is no full application
evidence. No synthesis, PnR, STA, board, expanded regression or PPA is run.
Fixed upstream implementation and full-license inspection precede local RTL
and are recorded in [SOURCES.md](SOURCES.md).
