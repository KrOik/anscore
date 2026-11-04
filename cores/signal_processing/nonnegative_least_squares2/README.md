# Exact two-variable nonnegative least squares from raw sample rows

`nonnegative_least_squares2` accepts signed integer rows `(a0,a1,b)` and solves

```text
minimize sum_i (a0[i]*x + a1[i]*y - b[i])^2, subject to x>=0 and y>=0.
```

It returns the unique optimum as exact nonnegative rational coordinates for
full-column-rank input matrices. The service constructs its own sufficient
statistics from raw rows; the caller supplies neither a Gram matrix nor an
active-set certificate. Useful applications include two-component nonnegative
mixture fitting and bounded calibration. There is no rounding, tolerance,
fixed-point fractional scale, clipping or approximate iteration.

The existing `stream_linear_fit` fits an unconstrained slope/intercept with a
fixed intercept column and final quantization. `linear_solve2x2` solves a supplied
square system without inequality constraints. `weighted_isotonic` constrains
the ordering of a fitted vector. None provides this arbitrary two-column,
nonnegative, overdetermined row-to-solution contract. None is modified or needed.

## Parameters and public numerical contract

| Parameter | Default | Legal values |
| --- | ---: | --- |
| `DATA_W` | 8 | 1..16 |
| `MAX_SAMPLES` | 16 | 2..16, including non-powers of two |
| `TAG_W` | 8 | 1..32 |

All three row inputs are signed W-bit two's-complement integers. Their entire
domain, including minimum signed values, negative columns, negative RHS and
zero RHS, is legal. Retain the first MAX_SAMPLES kept rows. A further accepted
kept row marks overflow and is drained without writing beyond capacity. A
masked row has no numeric effect. No zero/negative coefficient is invalid.

Let `L=clog2(MAX_SAMPLES)`, `CW=clog2(MAX_SAMPLES+1)`, `EW=4W+2L+4`.

| Output | Meaning when valid |
| --- | --- |
| `m_num_x`, `m_num_y` | Unsigned EW-bit nonnegative numerators |
| `m_denominator` | Unsigned EW-bit shared positive denominator on success |
| `m_determinant` | Signed EW-bit exact determinant of `A' A` on success |
| `m_positive[0]`, `[1]` | Coordinate x, y is strictly positive |
| `m_count` | CW-bit retained kept-row count, including error frames |
| `m_tag` | Captured first accepted token's tag |
| `m_status` | 0 success, 1 empty, 2 capacity overflow, 3 rank deficient |

The fitted coordinates are `m_num_x/m_denominator` and
`m_num_y/m_denominator`. Fractions are deliberately unreduced; zero coordinates
can share a denominator larger than one. The positive flags describe numeric
coordinates rather than the internal choice of formula. Returned equality to
the mathematical optimum is exact. The core does not report residual norm or
the unconstrained answer.

Overflow status has precedence over empty/rank checks. Empty means no kept rows;
rank deficiency includes a singleton, zero columns and proportional columns.
Every error returns canonical zero numerators, denominator, determinant and
positive flags, retaining count/tag. **Rank deficiency is a service-domain
rejection, not a claim of mathematical infeasibility.** NNLS always has feasible
zero coordinates; a deficient matrix can also have an optimum. This core only
qualifies the unique, strictly convex, full-column-rank domain. There is no
near-singular threshold: every exact positive determinant is accepted.

## Clock, framing, backpressure and reset

Use one rising-edge clock, synchronous active-high rst, ordinary ready/valid
and no external CE or CDC. A source token transfers on `s_valid && s_ready`.
`s_last` ends a frame, including a masked tail. Every frame contains at least
one accepted token. The first accepted token owns tag even when masked; later
tags are ignored. There is no FIRST, byte mask, runtime configuration or packet
bus adaptation hidden in the ports. Missing LAST waits for more input or reset.

Collection accepts one row per clock while ready. After the tail, one frame
owns compute and its single response; ready remains low until result retirement.
Source valid/payload remain stable while blocked, unless reset cancels them.
All output fields remain stable while valid and not ready. A command is not
accepted on the result-retiring edge; it may transfer on the next edge.

Reset assertion immediately gates public ready/valid low. At its active edge it
clears scalar state and outputs and cancels partial collection, arithmetic or a
held response. RAM and its read register are intentionally unreset. Every read
address belongs to the newly written retained prefix, so stale rows cannot enter
a subsequent solve. There is no reset sweep or initialization file.

## Exact solve, ranges and architecture

From the captured raw rows calculate:

```text
g00=sum(a0*a0), g11=sum(a1*a1), g01=sum(a0*a1)
h0=sum(a0*b), h1=sum(a1*b)
D=g00*g11-g01*g01
nx=h0*g11-h1*g01, ny=h1*g00-h0*g01
```

For full rank, `D>0` and the Gram matrix is positive definite. The KKT conditions
are `x,y>=0`, `g=A'*(A*[x,y]-b)>=0`, and coordinatewise `x_j*g_j=0`.
The exact two-variable selection is:

1. If nx and ny are nonnegative, return `(nx,ny)/D`.
2. Otherwise, if h0>0 and ny<=0, return `(h0,0)/g00`.
3. Otherwise, if h1>0 and nx<=0, return `(0,h1)/g11`.
4. Otherwise, return `(0,0)/1`.

For example the inactive y-gradient in case 2 is `-ny/g00>=0`; the x-gradient
is zero. The symmetric argument applies to case 3. Positive definiteness makes
these cases exhaustive and the optimum unique; remaining zero coordinates have
nonnegative gradients. This is a degree-two specialization of convex KKT
conditions, without a generic iterative active-set solver or division. Zero
RHS, exact variable boundaries and correlated/negatively correlated columns
are supported. A zero determinant rejects before selecting any answer.

Let `H=2^(W-1)` and n<=N<=2^L. Every raw product has absolute value <=H²,
and each of the five statistics has magnitude <=N*H². Every subsequent product
has magnitude <=N²H⁴; each difference D/nx/ny has magnitude <=2N²H⁴, at most
`2^(4W+2L-3)`. Positive capacity of signed EW is `2^(4W+2L+3)-1`, strictly exceeding the proved bound for all legal products, differences and
partial sums. In particular the minimum negative input is included. No useful bound
depends on cancellation or floating-point conditioning. Output numerators and
denominators are selected from these same exact registers and fit in EW.

One packed `3W`-bit synchronous row RAM is written during collection and read
in disjoint compute states. Each row requires five sample products of exactly
W shift/add steps. The same EW-wide signed-magnitude multiplier performs six
wide products of exactly EW steps. A read/setup/save controller reuses the
datapath; no source-level data `*`, `/`, `%`, vendor primitive, matrix-product
array, divider, QR array or external solver is needed. General QR/active-set
architectures would support more variables but need much more state/control;
parallel products trade area for latency. This bounded two-component service
selects exact serial reuse instead.

Logical RAM is `3WN` bits: **384 default / 768 maximum**. Declared scalar state,
including unreset row read data, is
`16EW+3W+IW+CW+2clog2(EW)+TAG_W+18` bits with IW=clog2 N:
**775 default / 1337 maximum**. There are 16 EW state registers, one 3W read
register and explicit count/address/control/flags/tag. These are declaration
budgets, not physical FF/BRAM/LUT/DSP measurements. Resource risk is LOW default,
MEDIUM maximum due to wide add/compare paths and scalar reset routing. Actual
inference, timing, power and device fit remain unknown.

After accepted LAST, empty/overflow first-valid latency is exactly one edge.
All nonempty nonoverflow frames, including rank errors, take exactly
`14+n*(5W+11)+6EW` edges: one CHECK, one read per row, five `(setup+W+save)`
products per row, six `(setup+EW+save)` products, and final selection. The
first-valid maximum is **1094 default / 1926 maximum** clocks. Result transfer
and next-frame admission add edges; source gaps and sink stalls add unbounded
external waiting. No frequency or physical-throughput promise is made.

## Offline closure and finite verification

Compile `files.f` from this directory. `example/files.f` adds `nonnegative_fit16`,
the complete default direct instance; example evidence is syntax/instantiation
only. Production closure is the local RTL; root Apache LICENSE/NOTICE apply.
There are no includes, sibling modules, ROMs, generators, memory contents,
runtime Python libraries or network dependencies. SOURCES records actual
semantic dedup and pinned upstream full related implementation/license reads
before RTL. Local `.gitattributes` was created first and enforces LF.

`TEST_PLAN.json` and six fixtures are frozen before the first HDL child.
`python run_tests.py --run` consumes those bytes and writes the authoritative
raw receipt, including canonical source_sha256 for every nonreceipt file.
The original matrix has 21 children: version, core/example syntax, six compile/
simulation pairs and six named illegal-parameter rejects. Every compiler or
simulator child has a hard 20-second limit. TIMEOUT is terminal; no retry,
fixture shrink, larger limit or promotion is permitted. Existing receipts block
automatic reruns. Concrete ordinary failures require preserving original source
and receipts before any identical-matrix repair. No synthesis, PnR, STA, board,
expanded regression or inherited numerical reruns are part of this package.

The independent oracle enumerates variable subsets, solves each restricted
system by exact Fraction Gaussian elimination, and checks primal/dual feasibility
and complementary slackness using original-row residuals. All accepted full-rank
certificates agree on one rational vector. Rank and determinant use a separate
Cauchy-Binet sum of squared raw row-pair minors. The oracle does not reproduce
the RTL's closed-form numerator/branch tests. Known basis, fractional axis,
fractional interior, negative-column and zero solutions check the oracle itself.

Finite inputs include complete small signed two-row alphabets, directed variable
boundaries, zero RHS, negative correlations, signed extrema, full maximum rows,
proportional/zero columns, all errors, masks and first-tag ownership, deterministic
random frames and overflow drain. The maximum W/N/T tuple is numerically tested.
Every next frame's actual frozen token stays offered through held-result retirement
and its own acceptance. TB checks complete response metadata, exact rational
coordinates by cross multiplication, raw RAM images and original-row residual
KKT/coordinate slackness on every successful main result, exact first-valid time,
all ten states and every sample/wide operation. Every full product is independently
checked at 2EW precision before sign restoration.

Immediate low-clock reset probes cover idle/partial/full/overflow collection,
masked first ownership, first/last RAM reads, every sample/wide operation,
first/middle/last iterations of both multiplier modes, all KKT/result/error
branches and a blocked next source. W1 cannot encode negative A'b statistics,
so only its impossible negative-product/zero-fallback probes are excluded;
sample first/middle/last alias naturally at W1. Every reset is followed by a
complete analytic two-row identity-basis solve with all fields, original RAM/KKT,
exact latency, held output, retirement and absence of stale output checked.
`verification.json` determines actual finite maturity. All versions remain
**HW_UNVERIFIED**; finite tests do not prove every parameter/history or physical
implementation.

The original matrix passed all 21 children on its first attempt, including six
expected parameter rejections, with no warning, failure, timeout or rerun.
Main traffic completed 2470 frames / 8962 tokens: 1432 successful, 95 empty,
146 overflow and 797 rank-deficient frames. Successful positive-coordinate
masks 0/1/2/3 occurred 504/329/331/268 times; 420 solutions were fractional.
Every successful result passed the independent rational optimum and original-
row KKT checks. All 7186 retained raw-row images were checked at results;
31425 sample and 13374 wide products consumed 573855 shift/add steps.
All 2464 actual queued next-frame tokens survived through acceptance, with
682307 stable blocked-source and 7393 held-output checks. All 268 immediate
reset probes completed their full fresh two-row solve. The six maximum observed
latencies were 106/212/282/674/1094/1926 clocks, reaching the declared full-row
bound in every profile. The longest tool child took 1.328 seconds.

Current evidence is UNIT_SIM_PASS with core/example syntax PASS, and always
HW_UNVERIFIED. Only this measured-results prose and an arithmetic-bound wording
correction follow qualification. The receipt preserves the original README,
tested/current hashes and reconstructible original receipt SHA; implementation,
TB, oracle/runner, frozen plan, fixtures, lists and example remain unchanged.
