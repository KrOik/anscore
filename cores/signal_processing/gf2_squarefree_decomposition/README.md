# Exact GF(2) squarefree decomposition by multiplicity

`gf2_squarefree_decomposition` decomposes a caller-supplied monic binary
polynomial into its complete squarefree multiplicity groups. It computes the
groups from the input coefficients. The caller supplies no factors or answers.

All hardware is **HW_UNVERIFIED**. Without a successful receipt this is an
**RTL_CANDIDATE**. No preparation, oracle, compiler or simulator result is
implied by the source. Only an actual successful `verification.json` establishes
LINT_PASS / UNIT_SIM_PASS for its explicitly sealed finite checks.
Synthesis, PnR, STA, formal, board, power and inherited regression are excluded.

## Complete numerical contract

`DEGREE=D` defaults to 16 and is legal from 1 through 64. `TAG_W` defaults
to 8 and is legal from 1 through 32. Input bit j is the coefficient of x^j:

```text
P = x^D + sum(s_poly[j] * x^j, j=0..D-1), in GF(2)[x].
```

Every D-bit pattern is legal. Zero low bits mean the nonzero polynomial x^D.
The zero polynomial, constants, arbitrary leading coefficients and runtime
degree changes have no encoding. For D=1, x and x+1 each produce one factor
equal to P, with multiplicity 1. No irreducibility assumption is made.

One accepted command produces a nonempty output frame of pairs `(F_e,e)`:

```text
P = product(F_e ^ e over every emitted pair)
e >= 1; F_e is monic, nonconstant and squarefree
gcd(F_e,F_j) = 1 for distinct pairs
sum(degree(F_e) * e) = D.
```

Every distinct multiplicity occurs once. Irreducible factors having the same
multiplicity are multiplied into the same F_e; F_e may therefore be reducible.
This is a complete squarefree decomposition, rather than irreducible
factorization, a squarefree predicate or one factor witness.

`m_factor` has D+1 coefficient bits and includes its monic leading bit.
`m_degree` is its exact degree. `m_multiplicity` has
`max(1,ceil(log2(D+1)))` bits, so it represents multiplicity D, including 64.
All results are exact XOR polynomial arithmetic, without integer carries,
signed coefficients, scaling, rounding, saturation or overflow truncation.

The deterministic streaming order is: positive odd multiplicities in increasing
order, then twice positive odd multiplicities, then four times, and so on.
Equivalently sort e by `(v2(e), e/2^v2(e))`. Missing groups and unit factors are
omitted. For example x^2*(x+1)^3 emits `(x+1,3)` followed by `(x,2)`.
This order permits a streaming implementation with no factor array or sorting
RAM. `m_last` marks exactly the final pair, and every pair carries the command tag.

## Ownership, backpressure and reset

One rising-edge clock, synchronous active-high reset and ordinary ready/valid;
there is no CE, CDC or external memory. Only `s_valid && s_ready` accepts a
complete command. Both source fields and valid must remain stable while stalled.
One frame owns the core until its final output retires or reset cancels it.
The source may offer another command during computation or any held factor.

Every valid output field remains stable while `m_ready` is low. A nonfinal
factor's retirement resumes the same command. Final retirement returns to IDLE;
the next command can first be accepted on the following edge, never on that
retirement edge. Invalid payload is unspecified. Arbitrary output stalls give
unbounded wall-clock completion delay.

Reset masks ready and valid and cancels the active command, pending factor and
remaining frame. Already retired factors form an aborted prefix: a receiver
must discard a frame that has not completed with `last`. Reset-high offers
do not transfer. Only ownership control is reset; arithmetic payload is not
cleared. A fresh accepted command initializes every value before it is consumed.

## Shared arithmetic and correct final-pair lookahead

The controller uses the characteristic-two squarefree decomposition. For each
Frobenius-root layer, C=gcd(F,F'), W=F/C. For i=1,2,... while W is nonunit:

```text
Y = gcd(W,C)
Z = W/Y
C_new = C/Y; W_new = Y
emit nonunit Z at multiplicity i * 2^level
```

When W is unit and C is nonunit, C is a perfect square. Replace F with sqrt(C)
and visit the next layer. Derivative-zero polynomials take this route naturally;
they are not rejected or silently treated as squarefree.

One shifted-XOR engine shares its U/V operands between Euclidean GCD and exact
quotient operations. Direct coefficient wiring forms derivative and square root.
No integer multiplier, divider, DSP primitive, factor RAM, answer ROM or runtime
library is required. Degree encoding and the variable shift are the expected
critical path; maximum-degree structural risk is MEDIUM, without a measured
device or frequency claim. See [COST.md](COST.md).

Z is a dedicated pending-factor register. After obtaining Z, the engine first
finishes C/Y, updates C and W, and only then asserts valid. At that point
`last=(C==1 && W==1)` is exact. A nonunit W guarantees a later current-layer
factor; a nonunit C guarantees a later root-layer factor. Thus `last` requires
no future speculative search and no hidden array. Pending Z, C, W, multiplicity,
root layer and tag all remain frozen during an output stall.

With L=floor(log2(D))+1, a conservative compute-clock bound is
`L*(4*D+7)+D*(5*D+8)`: 1763 at D=16 and 22833 at D=64. For an always-ready
consumer, add one retirement edge per emitted pair (at most D). The next
command's earliest acceptance is one further edge later. Every fixture records
exact first-valid gaps from acceptance or the preceding factor's retirement;
the upper bound is not used to relax those checks.

## Planned finite evidence and offline use

The primary oracle performs complete deterministic Berlekamp splitting and
recovers every multiplicity by repeated exact division of the original P.
This does not follow the RTL's W/C/Y/Z loop. A separate characteristic-two
squarefree decomposition must agree. At D<=5, a third exhaustive monic-factor
enumeration must also agree. Reconstruction, squarefreeness, pairwise coprimality,
unique multiplicities and weighted degree sum are checked independently.

The fixed profiles are (D,TAG_W)=(1,1),(5,3),(16,8),(64,32). Small profiles
exhaust every input. Each wider profile has 20 predetermined structural or
constructed cases and eight fixed-seed inputs: 90 main commands in total,
replayed in continuous and stalled modes. Constructions include zero derivative,
deep roots, maximal multiplicity, shared multiplicities, mixed odd/even groups
and a degree-64 input with six distinct groups. No DUT result selects an input.

Sixteen named reset predicates are selected from this same immutable input pool;
aliases and absent predicates are reported explicitly. They include a real
blocked next command during a nonfinal output and cancellation after a retired
prefix. Every selected probe is followed by a complete fresh command, including
arithmetic, tag, frame boundary, exact timing and stalls. Three reset-high
offers per probe must not transfer.

`PREPARATION_PLAN.json` is reviewed before running preparation. The generated
`TEST_PLAN.json` binds fixtures and all 21 HDL child argv/cwd: five legal
compiles, four named parameter rejects and twelve simulations. Every child has
a hard 20-second tree limit. The first failure or timeout stops the matrix,
preserves the receipt and raw evidence, and leaves all later children NOT_RUN.
There is no automatic retry, reseed, adaptive case split or golden repair.
Root must review and approve the exact source seal before any HDL child.

The source list is `files.f`; `example/gf2_sfd16.sv` is a minimal wrapper.
Both source lists are relative to this package root. All production dependencies
are local. Python standard library and the explicitly sealed installed tools
are used only for finite qualification. Upstream provenance is in [SOURCES.md](SOURCES.md).
