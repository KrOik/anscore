# Exact Euclidean simplex projection

Status: **RTL_CANDIDATE / HW_UNVERIFIED**. Authoring only: no numerical preparation,
oracle, compiler, simulator, synthesis, PnR, STA or board execution has occurred.
The finite plan and source seal require separate root approval before execution.

This core computes the unique exact Euclidean projection of an integer vector:

```
minimize sum_i (y[i]-x[i])^2, subject to y[i]>=0 and sum_i y[i]=M.
```

Each output is the unreduced rational `m_numerator / m_denominator`. There is no
fixed-point approximation, division, rounding or saturation. Input order is
preserved. Projection is distinct from L2 normalization, ordered/isotonic
regression, and two-column nonnegative least squares.

## Parameters and ports

| Parameter | Legal values | Default |
|---|---:|---:|
| `N` | 1..64, fixed samples per frame | 16 |
| `DATA_W` (`W`) | 2..24, signed integer data and unsigned mass width | 16 |
| `TAG_W` | 1..32 | 8 |

Define `L=ceil(log2(N))`, including `L=0` for N=1; `INDEX_W=max(1,L)`;
`COUNT_W=max(1,ceil(log2(N+1)))`. Unsupported parameters deliberately elaborate
the missing module `exact_simplex_projection_invalid_parameters__see_README`.

| Port | Direction and type | Meaning |
|---|---|---|
| `clk` | input | Single rising-edge clock |
| `rst` | input | Synchronous, high reset; masks both handshake outputs while high |
| `s_valid`, `s_ready` | input, output | Ordinary ready/valid input handshake |
| `s_data` | input signed W | Integer sample, every bit pattern legal |
| `s_mass` | input unsigned W | M, 0..2^W-1; captured only with the first input sample |
| `s_tag` | input TAG_W | Captured only with the first input sample |
| `m_valid`, `m_ready` | output, input | Ordinary ready/valid output handshake |
| `m_numerator` | output unsigned W+L | Nonnegative exact rational numerator |
| `m_denominator` | output unsigned COUNT_W | Common positive active-set count, or 1 for M=0 |
| `m_index` | output unsigned INDEX_W | Original input index, 0..N-1 |
| `m_last` | output | True only for output N-1 when `m_valid` is true |
| `m_tag` | output TAG_W | First-sample tag |

There is no CE, CDC, run-time frame-length configuration or external memory.
Exactly N accepted samples form a frame; there is no input last. Later-sample
mass/tag fields are ignored. A producer holds all input fields stable while
`s_valid && !s_ready`. A consumer accepts output only on `m_valid && m_ready`.
All output fields remain stable during backpressure. Fields are unspecified
when valid is low.

The core owns one frame from its first accepted sample through its last retired
output. It cannot accept the next frame on the last retirement edge; acceptance
can occur on the following edge. Input gaps preserve partial frames. Output
backpressure can extend occupancy without limit.

Reset aborts a partial input, active computation or held output. It clears control
ownership and index, masks both handshakes, and does not reset RAM or arithmetic
payload registers. A subsequent frame overwrites every RAM location before any
read and initializes all live arithmetic state. The receiver must discard an
aborted output prefix that has no last. It may see a last accepted before reset
as a completed earlier frame.

## Exact algorithm and termination

For M>0 initialize A to all indices. At each pass hold `k=|A|` and
`T=sum_A(x)-M` fixed, retaining only indices satisfying `k*x[i] > T`.
Recompute survivor sum/count; if count dropped, start another pass. Equality
corresponds to zero projected value and is removed. When count stops changing:

```
numerator[i] = max(k*x[i]-T, 0)
denominator[i] = k
```

For M=0 the only feasible vector is zero; output N zero numerators with denominator
1. This case skips active-set passes.

Nonempty proof: for any nonempty current set, the sum of its tested differences
is `sum_A(k*x[i]-T)=k*M>0`. Therefore at least one difference is strictly positive;
deletion cannot empty the set when M>0. Every nonterminal pass removes at least
one index. Starting at N and never falling below 1 gives at most N-1 nonterminal
passes followed by one terminal pass: at most N passes total.

Let tau=T/k. If a pass removes d entries with sum R, then R<=d*tau and
`tau_new=(k*tau-R)/(k-d)>=tau`. Previously removed entries can therefore never
become positive and need no reinstatement. At termination retained entries are
strictly positive, discarded entries satisfy `x[i]<=tau`, and the sum of retained
numerators is `k*sum_A(x)-k*T=k*M`. Thus nonnegativity, exact mass and the KKT
threshold conditions hold. Strict convexity gives the unique Euclidean minimizer.
The denominator counts strictly positive outputs; zero boundary terms are excluded.

## Width and sign proof

Let H=2^(W-1), `A_W=W+L+2`, `P_W=W+COUNT_W+1`, `U_W=W+L`.
All sample and accumulator arithmetic is integer, with no binary fractional bits.

| Quantity | Signedness/width | Bound over all legal data |
|---|---|---|
| x | signed W | -H..H-1 |
| M | unsigned W | 0..2H-1 |
| k, kept count, round | unsigned COUNT_W | 0..N; live k>=1 |
| partial or subset sum S | signed A_W | -N*H..N*(H-1) |
| T=S-M | signed A_W | -(N+2)*H+1 .. N*(H-1) |
| k*x | signed P_W, sign-extended to A_W | -N*H..N*(H-1) |
| k*x-T before clamp | signed A_W | -2*N*H+N .. (2*N+2)*H-N-1 |
| final numerator | unsigned U_W | 0..k*M <= N*(2^W-1) < 2^(W+L) |

`A_W` has signed magnitude capacity 2^(W+L+1)=4*2^L*H. The lower bound and upper
bound above fit even at N=1; for N>=1, `2*N+2<=4*2^L`, and the upper endpoint is
strictly smaller. This also covers the shared sum adder's intermediate retained
prefixes. The unsigned ALU implements two's-complement addition/subtraction in
A_W bits; every live mathematical result fits, so its low A_W bits are exact.

The multiplier receives natural signed W-bit RAM data and a **zero-prefixed**
signed COUNT_W+1-bit k. Full product width is P_W, so unsigned k is never mistaken
for a negative multiplier. P_W<=A_W for all supported N; the entire registered
product is sign-extended before comparison/subtraction. M is zero-extended before
being interpreted as signed, including its largest unsigned values. No same-width
signed cast of M, expression truncation before comparison, abs(minimum-negative),
or threshold division is used. Only a proven nonnegative final numerator is sliced
to U_W bits, justified by the exact-mass bound rather than sample observations.

## Architecture and cost

One frame RAM stores N*W bits, with synchronous write and registered synchronous
read. LOAD and read states are mutually exclusive, so there is no read/write
collision or hidden extra read port. The N-bit active bitmap supports one indexed
test/update per pass step. Each scan visits all N addresses, including inactive
ones, keeping latency deterministic for a given pass count.

PASS_READ→PASS_MULT→PASS_CHECK separates synchronous RAM access, the shared
multiplier, and comparison/conditional survivor summation. PASS_END commits the
new k/T. OUTPUT_READ→OUTPUT_MULT→OUTPUT_CHECK→HOLD uses the same RAM and multiplier.
A muxed A_W-bit adder/subtractor serves input sums, survivor sums, S-M and final
numerators. One signed comparison of the product and T serves deletion and output
clamping; small address/count/control comparators are additional. There is no
division, sqrt, sorting network, result ROM or vendor-specific primitive.

See [COST.md](COST.md) for default/maximum register and cycle accounting. RAM
inference and DSP mapping are tool/device dependent. None of LUT, FF, BRAM, DSP,
Fmax, power, physical feasibility or hardware behavior has been measured.

## Finite qualification plan

The mathematical contract covers all legal bit patterns. The planned evidence is
the **explicit finite** named collections in `prepare.py`: N1=12, N3=32,
default=28, maximum=28 frames. There is no Cartesian input-domain enumeration,
reseed, adaptive owner selection, substitute vector or expanded regression.
An earlier unexecuted authoring proposal for a Cartesian collection was removed
before freezing this plan and must never be executed.

The independent numerical oracle sorts descending and selects the largest strict
admissible prefix, then certifies exact KKT, nonnegativity and sum=M with Python
integers and `Fraction`. For N<=3 an additional support-subset certificate checks
every possible mathematical positive support **for each named vector**; it does
not enumerate additional inputs. RTL deletion rounds are not used as the oracle.
`control_walk.py` is a separate reset-witness scheduler. It freezes live register
predicates and is checked against the sorted oracle's final k/T; it supplies no
expected output numerators.

Each named main frame runs once always-ready and once with exactly three stalled
edges for every output. Input gaps and an actual queued next frame exercise source
holds and first-beat metadata lock. Eighteen named reset targets cover partial LOAD,
zero/positive INITIALIZE, READ/MULT/CHECK, strict retain/delete, threshold equality,
dropping/terminal PASS_END, a later pass, output READ/MULT/CHECK, held nonlast/last,
computation after a retired prefix, and a real next-frame offer held behind the
owner's last output. N1 excludes seven mathematically unreachable targets, leaving
11; other profiles run all 18. Every reset is followed by an entire fresh frame
with a different vector and tag, independently certified and fully retired.

`TEST_PLAN.json` fixes 23 children: four parameterized TB compiles, one full-port
example compile, six named invalid-parameter rejection compiles, then twelve
simulations. `prepare.py` requires the exact approved PREPARATION_PLAN hash and
refuses existing fixtures/receipts. Root must supervise that one preparation with
a hard 20-second process-tree deadline. After fixture review, `run_tests.py --seal`
binds sources, fixtures, the fixed plan and tool hashes. A separately approved
seal is required by `--execute`. Windows children start suspended, are assigned
to a kill-on-close Job, and resume only after containment; deadlines terminate
the complete Job at 20 s. First failure/timeout stops all later children as
NOT_RUN, saves raw streams and original failure artifacts, and permits no retry.
The runner does not import or rerun the numerical oracle.

The example is `example/simplex16.sv`, with every port exposed. Source dependencies
are listed in `files.f`; no old package is modified or required.

Original RTL, wrapper and verification tooling are Apache-2.0; see LICENSE, NOTICE
and [SOURCES.md](SOURCES.md). The mathematical paper is cited, not vendored.
