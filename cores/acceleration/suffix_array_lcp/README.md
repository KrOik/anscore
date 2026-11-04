# Runtime suffix array and adjacent LCP

`suffix_array_lcp` builds an exact suffix index over a runtime unsigned-symbol
frame. It returns every suffix start once, in lexicographic order, together
with the exact longest common prefix with the preceding suffix. The first
rank has LCP zero. A shorter suffix sorts first when it is a prefix; all symbol
values, including zero and all ones, remain ordinary data. No sentinel value
is reserved. This adds a content index rather than another fixed-record sort,
prefix routing table or fixed-pattern matcher.

## Interface and ownership

One clock, synchronous active-high `rst`, no CE or CDC. Input transfers on
`s_valid && s_ready`, output on `m_valid && m_ready`. Hold the entire offered
input until accepted. Every output field remains stable while valid and
blocked. The first accepted token owns `s_tag`, even if masked. Later tags
are ignored. Accepted `s_last` closes the frame, including a masked LAST.
No input timeout is imposed. Only kept symbols consume storage and positions:
the first kept symbol has index zero, independently of masked tokens.

A successful nonempty frame of length L emits L kept records. `m_rank` is
0..L-1, `m_suffix` is the original kept-symbol start index, `m_lcp` is the
common-prefix length, and `m_count=L`. FIRST marks rank zero and LAST marks
rank L-1. The frame tag repeats on every result. An empty frame succeeds with
one masked FIRST/LAST token and canonical zero numeric fields. All numeric
ports are unsigned; there is no scaling, saturation or approximate comparison.

| m_error bit | Meaning |
|---|---|
| 0 | More than MAX_SYMBOLS kept symbols |
| 1 | An accepted input has s_error, including masked tokens |

Errors OR together and persist through the accepted LAST. Capacity saturates
at MAX_SYMBOLS while excess input drains; an upstream error can still arrive
after overflow. An error publishes exactly one masked FIRST/LAST token with
zero suffix, LCP, rank and count and the original tag. It skips computation.
There is no partial success output. All suffix IDs and LCP entries are cached
before the first successful output. The next frame cannot transfer until
the final output is accepted; there is no final-output/input fallthrough.
Ordinary ready/valid needs an explicit adapter to existing CE-qualified streams.

Reset gates ready, valid and output markers low immediately and cancels the
transaction on the active edge. Control and public data clear; payload RAM
does not. Capture count bounds symbol reads, insertion establishes every
order entry before use, and the complete LCP pass precedes publication.
A fresh transaction cannot consume a canceled frame's RAM ownership.

## Architecture and resource bounds

| Parameter | Default | Legal |
|---|---:|---|
| MAX_SYMBOLS | 32 | 1..64 |
| SYMBOL_W | 8 | 1..16 |
| TAG_W | 8 | 1..32 |

Let M=MAX_SYMBOLS, W=SYMBOL_W, T=TAG_W,
I=max(1,ceil(log2 M)), C=ceil(log2(M+1)). Invalid public parameters fail
elaboration through `suffix_array_lcp_invalid_parameters__see_README`.
Suffix IDs and LCP use I bits: different suffixes share at most M-1 symbols.
Counts use C bits, and address additions use C+1 bits before bounds testing.

Serial insertion sorting compares suffixes by synchronous symbol reads. A
shared character comparator walks equal symbols and resolves prefix ends
without fetching beyond the captured frame. The subsequent adjacent-LCP pass
reuses that comparator. The 18-state controller services three independent
single-port, clocked-read banks: M symbols, M sorted IDs and M LCP lengths.
Each read has a separate consume clock. There is no combinational array read,
reset loop, multiplier, divider, DSP, vendor primitive or external memory.

Logical RAM is `M*(W+2I)` bits: **576 default /1792 maximum**.
Clocked scalar and RAM-read declarations total `9+T+C+11I+2W` bits:
**94 /146**. This includes state5, errors2, started1, comparator-mode1,
tag T, count C, eleven I-bit registers and two W-bit registers. These are
declaration budgets, not mapped LUT/FF/BRAM measurements. Small memories may
map to registers or distributed RAM. Architecture risk is LOW default /MEDIUM
maximum, dominated by selectors and serial cubic work. Device fit, RAM
inference, Fmax, power and board throughput remain unmeasured.

Let A be insertion comparisons, P be sort character pairs, E be sort boundary
ends, S be shifts, Q be adjacent-LCP character pairs and F be LCP boundary ends.
For a successful nonempty length L, exact clocks from accepted LAST to first
valid are `4+2A+4P+E+S+5*(L-1)+4Q+F`. Each sort comparison has two ID setup
clocks; a character pair has bounds/read-A/read-B/use clocks. A boundary-only
end adds one. Each shift and insert write costs one clock. Each adjacent LCP
uses three ID setup clocks and one cache write. The fixed four clocks cover
CHECK, INIT and two output prefetch clocks.

Bounds A,S,E<=L*(L-1)/2 and P<=sum(i*(L-i))=L*(L*L-1)/6 follow from insertion
i comparing at most i older suffixes, each with at most L-i character pairs.
Q<=L*(L-1)/2: for each length threshold h, the adjacent suffix-length path has
at most L-h edges with both endpoints at least h. Summing these edges bounds
the adjacent minima. F<=L-1. Thus a safe bound, attained by identical symbols,
is `4+4L*(L-1)+2L*(L*L-1)/3+6*(L-1)`: **4 at L1, 25982 default,
191230 maximum**. Empty/error frames take one clock. Capture accepts one
token per clock. After a nonfinal result transfer, two prefetch clocks precede
next valid, so unstalled output acceptance interval is three clocks. External
input waiting and output backpressure are excluded from internal latency.

## Frozen finite qualification

`TEST_PLAN.json` and all eight fixtures were frozen before RTL creation.
The immutable matrix has five M/W/T profiles: 1/1/1, 3/2/3, 7/8/8,
32/8/8 and 64/16/32. Version, core/example syntax, five TB compiles,
eight main simulations, 53 reset simulations and six parameter rejects total
**75 child records**. Each compiler/simulator has a hard **20-second** timeout.
Maximum-profile main groups and reset groups of at most two targets were
split before RTL. A timeout is terminal, with no retry, smaller stimulus or
extended deadline. Ordinary failures preserve complete original source,
matrix, seal and receipt before an explicitly recorded unchanged-stimulus repair.

The primary oracle materializes tuple suffix keys and sorts them independently
of the hardware insertion schedule. A second rank certificate counts all
strictly smaller suffixes and checks the complete permutation. Adjacent LCPs
use direct zipped suffix sequences. A separate schedule certificate supplies
operation counts and exact latency, not expected output order. Main coverage
includes exhaustive small alphabets, identical/ascending/descending/periodic
frames, seeded data, late differences, full capacity, unsigned extremes,
masked first/tail tokens, ignored tags and overflow/upstream/combined errors.
Actual next frames are queued during busy work, every output is stalled for
two complete edges, and all held fields and synchronous RAM reads are checked.

There are 24 predeclared immediate-reset observations: all18 states, kept
capture, overflow before LAST, held upstream error, sort after an equal
character, later LCP write and held final output after prior retirement.
M1 explicitly excludes unreachable states3..14 and targets21..23, leaving9;
the other profiles use24 each, totaling **105 reset/fresh frames**. The target
is observed after a falling edge and reset asserted before the next active
edge. Every cancellation is followed by a full M-symbol identical frame,
exact maximum first-valid latency, retirement of every M result and complete
symbol/order/LCP bank checks. Shadow epochs enforce owned reads and complete
cache publication without clearing payload RAM.

Run once from repository root:
`python -B cores/acceleration/suffix_array_lcp/sim/run.py --run`.
`SOURCE_FREEZE.json` binds every source and fixture before the first HDL child.
`verification.json` retains actual stdout/stderr, partial main output, source
and plan hashes, statuses and finite totals. Missing work is never PASS.
Until a receipt exists, maturity is RTL_CANDIDATE /HW_UNVERIFIED. A successful
receipt adds UNIT_SIM_PASS only for this finite matrix. No synthesis, PnR,
STA, board test, inherited-matrix rerun or expanded regression is allowed.
The example is a complete default instantiation, not an integration test.
