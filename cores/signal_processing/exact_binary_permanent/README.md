# Exact binary matrix permanent

`exact_binary_permanent` counts every perfect matching of a runtime N-by-N
binary compatibility matrix. A result is the exact number of bijections p
such that A[r,p[r]]=1 for every row r. It counts alternatives rather than
returning one matching, maximum cardinality, minimum cost or a sampling estimate.
No host-supplied matching or topology is consumed.

## Transfer, row order and errors

One rising-edge clock, synchronous active-high reset, ordinary ready/valid,
no CE or CDC. A token transfers on `s_valid && s_ready`. Every offered field
must remain stable until that transfer. The kth kept token is row k, starting
at zero; `s_row[j]` is the compatibility bit for column j. Bit zero is column
zero. All N row bits are ordinary data. There is no reserved symbol, sparse
index truncation or implicit transposition. The matrix is square and its
dimension is the static N parameter, not a narrowed runtime input.

Exactly N kept rows are required. Masked tokens ignore the entire row word,
but their LAST, upstream error and first tag remain meaningful. The first
accepted token owns `s_tag`, including a masked token. Later tags are ignored.
An accepted LAST closes the frame even when masked; missing LAST leaves
capture open until the source completes or reset cancels it. Capture accepts
one word per clock. More than N kept rows are drained through LAST without
overwriting the captured N-row prefix.

| m_error bit | Meaning |
|---|---|
| 0 | Fewer than N kept rows at accepted LAST |
| 1 | More than N kept rows accepted at any point |
| 2 | Any accepted token has s_error, including masked tokens |

Bits are independent sticky indications, with no priority suppressing another
bit. Short and overflow are structurally mutually exclusive because the row
count saturates at N; legal result error values are 0,1,2,4,5,6. An empty or
short frame is a shape error, not a smaller matrix. Any error rejects the
whole frame and produces value zero. `m_rows` reports the retained saturated
row count, and the first tag is preserved even on errors.

Exactly one response transfers on `m_valid && m_ready`. Its fields are
`m_value,m_error,m_rows,m_tag`; all remain stable with valid high under
arbitrary backpressure. A complete valid matrix can successfully return zero,
for example a Hall-deficient graph. `m_error` distinguishes this from a rejected
frame. Processing and the response block further input. There is no response
retirement/input fallthrough: the next token can transfer on the following
edge. Computation does not wait for output ready. External stalls are unbounded.
Existing CE-qualified streams need an explicit adapter.

Reset immediately gates ready/valid low. Its active edge clears scalar/public
ownership and cancels capture, arithmetic, RAM reads or a held result. Both
payload banks and their registered read values are unreset. A receiver must
discard the canceled result. No implicit timeout or partial result exists.

## Exact representation and architecture

| Parameter | Default | Legal |
|---|---:|---|
| N | 8 | 1..12 |
| TAG_W | 8 | 1..32 |

Let V=max(1,ceil(log2(N!+1))), I=max(1,ceil(log2 N)),
C=ceil(log2(N+1)). Output `m_value` has V unsigned bits, `m_rows` has C.
The factorial expression is elaboration-only and fits a signed 32-bit integer
through 12!=479001600. It creates no data multiplier or runtime ROM. Illegal
public parameters fail elaboration via
`exact_binary_permanent_invalid_parameters__see_README`. Derived widths are
local parameters. There is no rounding, saturation of the permanent, signed
arithmetic, floating point, modulo result or approximate counting.

For a column subset mask with k set bits, dp[mask] counts assignments of the
first k rows onto exactly that subset. Initialize dp[0]=1. For every nonempty
mask, scan columns j in increasing order and sum dp[mask without j] precisely
when mask[j] and A[k-1,j] are both one. Partitioning injections by the last
row's selected column proves this recurrence. Ascending numeric masks put
every strict predecessor before its consumer. The final entry is the permanent.

Two synchronous single-port banks store N row words and 2^N DP values. A row
read is issued once per mask. Each column spends one scan edge; an eligible
column adds a separate DP-read edge and add edge. Each mask has a distinct
write edge. The final value also has separate read/load edges. There are no
asynchronous bank reads, collisions, replicated candidate adders, data multiply,
divide, remainder, DSP, vendor primitive or external memory.

All N rows are written in the current frame before a valid computation starts.
INIT overwrites dp[0]; every subsequent DP read addresses a smaller mask that
has already been written in the same computation. Old payload is hidden by
these lifetimes, including after reset. No clear sweep or resettable RAM is
required. Every intermediate entry counts injections into k columns, so it is
at most k!<=N!. Partial sums are nonnegative subcounts of that same set. A V+1
combinational sum therefore has zero carry and can safely narrow to V bits.
An all-ones matrix attains N!, including 40320 default and 479001600 maximum.

All clocked scalar, public and read-q declarations total
`8+C+TAG_W+2N+I+3V`: **87 default /159 maximum**. This includes state4,
started1, errors3, captured count C, tag T, mask N, column I, row_q N,
dp_q V, accumulator V and response value V. Combinational popcount and widened
sum are excluded; no clocked register is excluded. Logical RAM is
`N*N+2^N*V`: **4160 /118928 bits**. Qualitative risk is LOW default /MEDIUM
maximum, with the maximum dominated by the DP bank and serial work. These are
source declaration budgets, not mapped LUT/FF/BRAM results. RAM inference,
device fit, Fmax, power and board throughput remain unmeasured.

Let E be the number of eligible predecessor reads. A fixed row i is used for
subsets of size i+1; each allowed column occurs in choose(N-1,i) of them.
Thus `E=sum(popcount(row[i])*choose(N-1,i))`, independently of the DP values.
From the accepted LAST at edge zero, exact clocks to first valid are:

```text
error: 0
success: 3 + (2^N-1)*(N+3) + 2*E
```

There is one INIT edge; each mask has two setup, N scan, one write and two
edges per eligible predecessor; two final read/load edges remain. All-ones
E=N*2^(N-1) attains the maximum: **4856 default /110580 maximum**. The earliest
response transfer is the following edge, and the next input transfer is the
edge after retirement. Input gaps and output waiting add their actual time.

## Frozen finite qualification

`MATRIX_FREEZE.json` and all206 fixture files were written before any original
HDL. Six N/T profiles are 1/1,2/3,3/8,5/8,8/8,12/32. The742 main matrices
include every 1x1,2x2 and3x3 binary matrix (2/16/512), zero/full/identity,
cyclic permutations covering every input bit position, triangular and block
graphs, Hall deficiencies, seeded densities, row/column permutations and
transpose, all error combinations, short/excess rows, masks and ignored tags.

The primary oracle uses unbounded integer Ryser inclusion/exclusion over
column subsets. Every written DP prefix minor is independently certified by
Ryser's subset Mobius transform, not the hardware's ascending DP recurrence.
There are195840 frozen main minor certificates and573 explicit complete
permutation crosschecks for N<=5. Exact first-valid latency and the complete
row/DP read/write schedule are checked separately from expected values.
The TB verifies all fields, every synchronous read, written row words, strict
previous-mask ownership, zero widened carry and complete final bank images.

All32 reset targets/profile cover all11 states, initial/final/interior masks,
zero predecessor contribution, partial/full/overflow capture, first valid,
held count/zero/error results and actual queued offers. N1 has ten explicit
aliases and N2 one; no target is silently dropped. Every one of192 immediate
cancellations is followed by the complete frozen full-capacity all-ones fresh
frame, exact maximum latency, full bank-image certificates, held output and
actual response retirement. A held target includes three blocked edges and a
real next packet before cancellation; reset follows its observed boundary
without another active edge.

Main groups contain 654 actual queued transitions between their completed
frames. Every N12 main group has one frame, so that profile has no internal
main-group cross-frame acceptance. No extra prefix is appended. The 42 held
reset targets across six profiles offer a real next token under blockage,
cancel it at reset, then accept and complete the declared fresh packet.

Three preamble children, six TB compiles,88 main simulations,112 reset
simulations and four static rejects total **213 children**. Grouping is fixed
in the pre-RTL matrix. Every compiler/simulator child has a hard **20-second**
limit. TIMEOUT is terminal: no retry, smaller stimulus or larger deadline.
An ordinary failure archives complete original sources, plan, receipt and
NOT_RUN before any root-authorized repair. A successful package is immutable.

`files.f` and `example/files.f` are complete offline production closures.
The example is a complete default port wrapper, with syntax/instantiation
evidence only. The standard-library runner seals every source before the
first compiler, then executes the fixed matrix once. Until an actual successful
receipt exists maturity is RTL_CANDIDATE /HW_UNVERIFIED; a receipt adds finite
UNIT_SIM_PASS only. No synthesis, PnR, STA, board, inherited regression or
expanded matrix is run.

From the repository root, the qualification entry points are:

```text
python -B cores/signal_processing/exact_binary_permanent/run_tests.py --seal-source
python -B cores/signal_processing/exact_binary_permanent/run_tests.py --run
python -B cores/signal_processing/exact_binary_permanent/run_tests.py --audit
```

The source seal binds the exact ordered command templates, every local source,
both closure lists, the generator, matrix and all fixtures. Tool and temporary
path placeholders alone are expanded at execution. The receipt retains every
actual argv, return code, full stdout/stderr and elapsed time. Positive checks
reject warnings and stderr; negative checks require the named parameter guard.
An initial NOT_RUN record exists for every child and is replaced only when
that child executes. Failure archives preserve the complete sealed package.
