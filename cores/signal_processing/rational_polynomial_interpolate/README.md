# Exact rational polynomial interpolation

Original portable RTL accepts unsorted, nonuniform signed `(x,y)` nodes and a
signed query captured on the first accepted frame beat. It returns the exact
unique polynomial of degree below the retained node count, as a signed integer
numerator over a positive, intentionally unreduced denominator. It supports
interpolation, extrapolation and evaluation at a node without host sorting,
weights or coefficient generation. A singleton is a constant polynomial.

Status is recorded in `verification.json`: finite syntax/unit checks only;
`HW_UNVERIFIED`. No synthesis, PnR, STA, hardware or expanded regression.

## Interface and numerical contract

`DATA_W=W` is 1..16 (default 8), `MAX_LEN=M` is 2..6 (default 4), and `TAG_W`
is 1..32 (default 8). Coordinates, values and query are signed W-bit integers,
with no implied fractional bits. `COUNT_W=clog2(M+1)`.

One rising-edge clock, synchronous active-high `rst`, no clock enable. Input
transfers on `s_valid && s_ready`; every beat, including a masked beat, contributes
to framing. `s_keep=0` ignores only that beat's x/y. The first accepted beat captures
`s_tag` and `s_query`, even if masked; later tag/query inputs are ignored.
`s_last` closes the frame when accepted. Input collection accepts consecutive
beats at II=1. The source must hold every input field while valid and blocked.

Retain the first M kept nodes, drain further kept beats and set overflow. Error
bits are bit0 empty, bit1 any repeated retained x (even equal y), bit2 overflow.
Duplicate detection covers the retained prefix even when overflow is set.
Reachable codes are 0,1,2,4,6; codes 3,5,7 cannot arise under this contract.
Any error returns zero numerator and denominator, while retaining count, captured
query and tag diagnostics. Excess-only duplicates do not set bit1.

Output transfers on `m_valid && m_ready`. All output fields remain stable while
blocked. One frame is owned until output retirement; input is blocked during
computation and held output. Reset gates ready/valid low immediately and cancels
all owned work at the next rising edge, including a held result and blocked
source. Sample RAM has no reset: only the current overwritten prefix is read.
There is no external memory, CDC or vendor primitive dependency.

For retained nodes indexed in arrival order, define `P=N*(N-1)/2` and
`V=product_{a<b}(x[b]-x[a])`. For a valid frame:

```
T = sum_i (-1)^(N-1-i) * y[i]
          * product_{j!=i}(query-x[j])
          * product_{a<b; a!=i; b!=i}(x[b]-x[a])
m_denominator = abs(V)
m_numerator   = sign(V)*T
```

Empty products equal one. Positive denominator normalization makes the exact
encoded result invariant to node permutation. Examples: `(0,0),(2,1)`, query1
returns 1/2; `(0,0),(1,1),(2,4)`, query3 returns 18/2, whose value is9.
There is no division, fraction reduction, quantization, rounding or saturation.

Let `Pmax=M*(M-1)/2`. Denominator width `DB=max(1,W*Pmax)` is unsigned;
numerator width `NB=W*(Pmax+1)+clog2(M)+1` is signed. Raw signed differences
extend to W+1 before subtraction. Each magnitude is at most `2^W-1`, so its
low W magnitude bits are exact. A numerator term has P nontrivial difference
factors; its magnitude is at most `2^(W-1)*(2^W-1)^P`. The N-term triangle bound
fits NB, including signed negation, intermediate terms and partial sums. The
denominator fits DB. Defaults are NB59/DB48; maximum W16/M6 is NB260/DB240.

## Architecture, timing and resource budget

A single `2W`-bit sample RAM has one synchronous read port and writes only during
collection. Pair factors use two sequential read edges. One unsigned NB-bit
shift/add multiplier processes W bits per factor, with separate result sign.
Identity factors pad omitted cofactor/query entries, so zero values and query
matches do not shorten timing. No data-dependent loop, runtime multiplication,
variable division, reciprocal table, parallel MAC bank or DSP is requested.

At an accepted tail edge E, first `m_valid` occurs after exactly:

```
empty:                     1 edge
duplicate and/or overflow:  2 + P*(W+4) edges
valid: 3 + P*(W+4) + N*(3 + N*(W+3) + P*(W+4)) edges
```

Singleton valid latency is W+9. Full default latency is551; full supported
maximum is2805. These are clock-edge counts from the accepted tail; source
gaps and sink stalls have no finite wall-clock bound. Consecutive complete
frames additionally require output retirement and a following collection edge.

Declared storage is `2WM` sample bits plus
`14+5*COUNT_W+max(1,clog2(W))+TAG_W+5W+5NB+DB` scalar register bits:
64+423=487 bits default;192+1685=1877 bits maximum. This counts RTL declarations,
including read data and public registers, and is not a synthesis result.
NB-wide addition/conditional negation and input muxes remain combinational;
only the shift/add multiplication is reused. RAM inference and achieved clock
rate are unmeasured. Qualitative resource risk is LOW default / MEDIUM maximum
because of the 260-bit arithmetic. No physical claims are made.

## Offline use and finite verification

Compile `files.f` from this directory. `example/files.f` adds the concrete
four-node 8-bit `interpolate4` wrapper with the complete interface. No generated
coefficients, memory images, packages, includes or network dependencies exist.
All local original files use the repository Apache-2.0 LICENSE/NOTICE.
Upstream semantic reference and full-license review are in `SOURCES.md`.

`python run_tests.py` regenerates the frozen exact vectors locally and executes
the 21 children in `TEST_PLAN.json` using the repository native Icarus/vvp.
The independent oracle solves a rational Vandermonde linear system by Gaussian
elimination, then evaluates by Horner; it does not reproduce the RTL cofactor
formula. It independently derives the positive encoding denominator from sorted
pair gaps. Full public outputs, exact first-valid delay, factor/shift counts,
sample read ownership, II1, held outputs, source stability and27 reset/fresh
probes per profile are checked. W1 multiplier phase aliases are explicit in the
plan. Fractional/nonuniform fixtures require a representable domain; they are
not claimed for the two-value W1 domain.

Each compiler/simulator child has a20-second hard limit. Any TIMEOUT terminates
the matrix, preserves TIMEOUT/NOT_RUN and is never retried or worked around by
changing fixture size or timeout. Ordinary failures may be fixed and the same
frozen matrix rerun, retaining prior failed records and source hashes.
The finite evidence is not exhaustive verification of all supported widths,
node sets, runtime schedules or arithmetic values.
