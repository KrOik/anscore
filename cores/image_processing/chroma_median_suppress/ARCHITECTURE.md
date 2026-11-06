# B40 paper architecture and finite scope

Baseline: `a68ca46815777c15c638c42a03899c83385bf052`.
The selected architecture reuses three original row-capture/padded windows and
two ten-stage unsigned median networks. The luma min/max trees have four compare
levels, followed by exact BITS-bit subtraction and threshold comparison; only
the predicate and original center travel alongside the median pipelines.
The new core adds no multiplier, divider, coefficient ROM or vendor primitive.

Using three independent DATA_WIDTH=BITS windows avoids changing the old
DATA_WIDTH<=16 contract. Input fanout qualifies all planes on their common
readiness, and each window retires only alongside the other two. All plane
valid schedules, geometry, reset and output advance are identical. Both median
networks likewise share one offer, identical readiness and downstream readiness.
The delayed original triplet and gate use that exact common global advance;
valid bubbles need no meaningful payload. Output position counters advance
only on public retirement. Frame state remains owned until held DONE retires.

Each reused padded window declares W row entries plus three banks of W+2
entries, explicitly `ram_style="registers"`. Thus all three plane row arrays
occupy `3*BITS*(W+3*(W+2)) = 3*BITS*(4W+6)` logical payload bits:

| Structure | Default W64/BITS8 | Maximum W512/BITS10 |
| --- | ---: | ---: |
| Three window row arrays |6288 bits |61620 bits |
| Two padded16-value,10-stage median payload networks |2560 bits |3200 bits |
| Ten-stage original triplet and gate |250 bits |310 bits |

These figures exclude window history/tap/read registers, network valid/marker
bits and small counters/control. The row arrays have explicit fabric-register
style, so no BRAM inference or physical packing claim is made. There is no frame
RAM and no reset loop on payload arrays. Default storage risk MEDIUM; maximum
HIGH, independent of frame height. The supported area limit keeps17-bit counts
exact through65536. Y/chroma/order statistics remain in0..2^BITS-1; subtraction
uses max>=min and cannot underflow. No core rounding or saturation is needed.

The actual example has the same three windows/two median networks plus two
unchanged CSCs. Each CSC declares1152 arithmetic payload register bits plus
3*BITS output bits and22 control/marker bits, or1198/1204 bits at BITS8/10;
the pair adds2396/2408 logical declared bits before any synthesis optimization.
Their existing nine coefficient products use registered shift/add partial
products, rather than runtime `*` or a downloaded table. Config coefficient
constants come from the checked-in include. Device fit, physical register/RAM
mapping, DSP use, Fmax and power remain unmeasured.

Median service is II1 in valid output bursts, with ten globally advanced
arithmetic stages. Row capture/replay reduces sustained frame service below
one input pixel per clock. In the absence of source/output stalls the windows
must accept W*H original samples and replay (W+2)*(H+2) padded samples, plus
registered handoffs/drain; CSCs add four stages each. This is a cycle-work
description, not a measured exact latency or hardware real-time claim. Unbounded
backpressure means no finite unconditional completion deadline.

Finite plan: three syntax children (default, maximum512x128/BITS10/TAG32 and
example), then compile/sim for1x1/BITS8/TAG1,9x7/BITS10/TAG8,
17x13/BITS10/TAG32 and actual16x12 RGB/BITS8/TAG8. Total11 HDL children,
four simulations. Each simulation checks32 complete frames,34 accepted STARTs,
32 DONE payloads, four resets (initial plus after first input, held first output,
held checked DONE), held final output/DONE, busy command exclusion, pin mutation
and deterministic gaps/backpressure. Expected output comparisons are32,2016,
7072 and6144 respectively, totaling15264. Full maximum geometry is syntax-only;
no maximum traversal or independent height512 functionality test is planned.

Sixteen source cases include sparse chroma impulses, disabled gate, unchanged
constant plateaus, exact luma range6*scale and one-code-too-small threshold,
full-range luma edges with maximum and maximum-1 thresholds, random full-range
chroma, block boundaries, black/maximum codes, gradient and malformed markers.
The integer oracle sorts ordinary immutable2-D samples and uses direct specified
CSC matrices, without modeling sorting stages, window RAM, bitonic pairs or RTL
control. No image-quality reference comparison or exhaustive parameter proof is
claimed.

The runner first archives all14 exact executable inputs, including the frozen
plan, before importing the oracle. One preparation writes/hashes all20 vector
files before any HDL child; checkpoints distinguish import attempts, preparation
attempts and preparation completion. Strict20-second child deadlines and bounded
7-second cleanup are fixed. First failure/timeout stops later children. Existing
report directories block automatic retries. Every raw stdout/stderr stream,
exact argv/cwd, expected marker and binary/input/archive/vector hash is recorded.
Final PASS requires all planned children in order, unique completion markers,
`$finish`, reviewed counters and immutable evidence. No execution is authorized
until complete A/B/root source review and root's explicit once-only first-run
instruction. Planning invocation count is recorded separately; no hidden oracle
smoke test or preliminary HDL is part of planning.
