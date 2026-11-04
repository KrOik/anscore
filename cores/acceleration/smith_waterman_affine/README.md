# Exact Smith–Waterman score with affine gaps

`smith_waterman_affine` scores the best local alignment of two bounded symbol
sequences with match rewards, mismatch penalties and affine gap penalties.
It returns the exact maximum score and its endpoint pair. Unlike the existing
unit-cost global `edit_distance`, unmatched prefixes/suffixes are free, local
scores restart at zero and long gaps use separate open/extension costs.
There is no traceback, aligned-string output, start coordinate or CIGAR stream.

## Scoring and numeric contract

Symbols are unsigned CHAR_W-bit codes compared for equality, with no character
encoding, substitution matrix, wildcard or alphabet conversion. All scoring
parameters are nonnegative integers; MATCH_SCORE is positive and
`GAP_OPEN >= GAP_EXTEND >= 1`. A gap of k symbols costs
`GAP_OPEN+(k-1)*GAP_EXTEND`, so a one-symbol gap costs GAP_OPEN.

For accepted sequences A and B, the mathematical recurrence is:

```text
H[0,j]=H[i,0]=0
E[i,j]=max(H[i,j-1]-GAP_OPEN, E[i,j-1]-GAP_EXTEND)
F[i,j]=max(H[i-1,j]-GAP_OPEN, F[i-1,j]-GAP_EXTEND)
H[i,j]=max(0, H[i-1,j-1]+(A[i-1]==B[j-1] ? MATCH_SCORE : -MISMATCH_PENALTY),
           E[i,j], F[i,j])
```

The conceptual initial E/F values are negative infinity. The hardware instead
clamps every E/F value and every subtraction to zero. This preserves H exactly:
negative gaps cannot win H's zero floor, and further positive extension
penalties cannot make such a gap useful before a fresh open. This requires
the documented positive gap penalties. It avoids signed negative sentinels.
Only H's result is exposed; clamped internal gap zeros are not traceback states.

`m_score=max(H[i,j])`, an exact unsigned integer. Only strict improvements
replace the best endpoint, so positive ties select the earliest A-major,
B-minor cell (lowest i, then lowest j). `m_a_end=i` and `m_b_end=j` are consumed
prefix lengths: the final aligned symbols have zero-based indices i-1 and j-1.
When the score is zero, both ends are zero. These are ends of the best local
score, not lengths of an alignment including gaps or start locations.

H is at most `min(length(A),length(B))*MATCH_SCORE`; at most one reward is
earned per pair of consumed matching symbols and all other terms are costs.
SCORE_W=max(1,clog2(MAX_LEN*MATCH_SCORE+1)) therefore holds every reachable
score. The match trial has one extra bit before narrowing; its reachable
diagonal is bounded by (MAX_LEN-1)*MATCH_SCORE, so no reward is lost. Penalties
are compared before narrowing, including cases where 255 exceeds the entire
score range. No rounding, fixed-point scaling, numeric saturation or overflow
approximation is used.

| Parameter | Default | Legal range |
| --- | ---: | --- |
| CHAR_W | 8 | 1..16 |
| MAX_LEN | 32 | 1..256 included symbols on each side |
| MATCH_SCORE | 2 | 1..255 |
| MISMATCH_PENALTY | 1 | 0..255 |
| GAP_OPEN | 3 | 1..255 |
| GAP_EXTEND | 1 | 1..GAP_OPEN |
| TAG_W | 8 | 1..32 opaque bits |

COUNT_W=max(1,clog2(MAX_LEN+1)) holds lengths and ends. Derived localparams
are internal. Invalid public parameters fail elaboration via a deliberately
unresolved named parameter-error instance. Scoring is static at elaboration;
there are no runtime configuration updates.

## Dual input, framing, errors and reset

All ports use one rising-edge clk. `rst` is synchronous active-high, gates
all public ready/valid low, cancels partial sequences/computation/held results,
and reopens both streams after its active edge. There is no CE or CDC. Legacy
CE-qualified streams need an explicit transfer adapter. Peers must restart
both sides of a pair canceled by reset, even if one side had already ended.

A beat transfers independently on a_valid&&a_ready or b_valid&&b_ready. Sources
hold all fields while valid and stalled. keep=1 appends a symbol; keep=0 ignores
the symbol. last terminates that side, including an excluded last beat. Empty
sequences use an excluded last beat; arbitrary masks and gaps are supported.
The first accepted A beat supplies a_tag even if excluded. Later A tags are
ignored. B has no tag; the nth A and nth B transaction are paired by order.
Neither side can begin its next sequence before the pair's result retires.

Each ready stays high until its own last is accepted, independently of the
other side. It remains ready after reaching capacity to drain an overlong
sequence. Only the first MAX_LEN included symbols are stored; an additional
included symbol latches the corresponding error bit. Excluded beats never
consume capacity or overflow. Missing last leaves that side open indefinitely.

Both sides must finish before any result. `m_error[0]` reports A overflow and
bit 1 B overflow. Any overflow rejects the **entire pair**: score and ends are
zero, with one ordinary result token. This is not a score for the retained
prefix. Length fields report the retained lengths min(included length,MAX_LEN),
not the full overlong lengths. With no errors, either empty side also returns
score/ends zero. Error flags distinguish rejected input from a genuine zero
score. There is no alphabet validation, external-memory error or timeout.

Exactly one result transfers on m_valid&&m_ready per pair. It contains score,
both ends, both retained lengths, error bits and A's tag. All fields remain
stable under arbitrary backpressure. New input stays blocked until this result
is consumed; both sides reopen on the following clock. Fields are meaningful
only when m_valid. There is no separate LAST or completion pulse for the
single-token result. Consumer/source stalls have no unconditional completion
bound.

## Architecture and structural review

Two symbol memories capture A and B. A packed row memory stores H and vertical
F for each B position; horizontal E, left H and the old diagonal H are scalar
registers. Initialization writes zero to the current B row, one entry per
clock. Each A row samples its A symbol once. Each cell then synchronously
fetches B and the packed previous-row value, calculates the recurrence and
writes the packed result on the next clock. Read/write phases are exclusive,
so no RAM read-during-write mode is assumed. Arrays are not reset in parallel;
capture and row initialization establish ownership before any consumed read.

One DP cell serves the entire matrix. Work is O(len(A)*len(B)), with two
clocks per cell, one row-setup clock per A symbol and len(B)+1 initialization
clocks, plus fixed control boundaries. Empty/rejected pairs skip the matrix.
Capture supports one symbol per clock on each independent side. Capture,
calculation and output transactions do not overlap. These are structural
schedules, not measured hardware rates or a continuous sequence throughput
promise.

Array capacity is `2*MAX_LEN*CHAR_W + 2*(MAX_LEN+1)*SCORE_W` bits: **974**
at defaults and **16416** at maximum. Scalar state, output and arithmetic
registers are additional. No multiplier, divider, ROM table, vendor primitive
or external storage is required. The local DP cell has several narrow
subtract/compare paths; its expected critical path is score subtraction
through the maxima, with storage mapping becoming more relevant at maximum
dimensions. Qualitative resource risk is **LOW** at defaults, **MEDIUM** at
maximum; actual mapping, area, frequency, power and fit remain unmeasured.

Existing edit_distance storage/control was considered. Its single min-cost
row lacks affine gap state and zero-reset local scoring; wrapping that module
cannot transform its global edit metric into this recurrence. Its original
RTL and historical evidence remain untouched. No duplicate copy is vendored.

## Offline use and finite evidence

`files.f` is the complete production source closure.
`examples/local_align32.sv` exposes the default byte-symbol service and is an
**INTEGRATION_CANDIDATE**. No external source, generator, ROM or network is
needed for compilation or bounded simulation.

```text
python -B cores/acceleration/smith_waterman_affine/sim/run.py
```

The standard-library runner uses local OSS CAD Suite Icarus/vvp or IVERILOG/VVP
overrides. Each child process has a 20-second timeout. Generated vectors and
images live in a task-specific temporary directory removed on exit. The
persistent TB, vector generator, actual command output, vector hashes and six
source hashes are retained; all local text is LF.

Current maturity: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**. Thirty-three
tool commands check eight CHAR_W/MAX_LEN/match/mismatch/open/extend/tag profiles:
1/1/1/255/255/255/1, 1/3/2/1/2/1/3, 2/5/3/0/1/1/8,
8/16/2/3/3/1/8, 8/32/2/1/3/1/8, 4/9/7/9/5/2/8,
8/64/1/0/255/255/16 and 16/256/255/255/255/1/32.
They cover **566 pairs**, including **24 rejected overlong pairs**, and
**220401** independent oracle matrix cells. The maximum profile is actually
simulated, including full 256-symbol exact matches at score 65280.

The oracle uses a full two-dimensional matrix and explicitly enumerates
**all possible gap lengths** at each cell. It has no rolling E/F state or
clamped-gap implementation. It checks exact score and earliest endpoint,
retained lengths, both error bits and tag. All 225 pairs of binary strings of
length 0..3 are included. Cases cover empty/all-different/identical sequences,
long affine gaps, zero mismatch costs, large penalties relative to SCORE_W,
nonpower-of-two lengths, full-width symbol extrema and seeded small-alphabet sequences.

The dual drivers independently stall/gap the two input streams and vary their
finish order. They test ignored/masked first metadata, partial/one-side-ended
collection, eight immediate reset phase probes per profile (three capture
cases, row initialization/setup, fetch, calculate and held output), repeated
reuse and five held-result clocks per pair. Fourteen illegal parameter cases
are rejected. This is finite coverage, not proof for all sequences/parameters.
Synthesis, place/route, STA, full regression and hardware testing were not run.
Source and license review: [SOURCES.md](SOURCES.md).
