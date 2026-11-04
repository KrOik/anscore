# Exact distinct real-root count in a closed interval

`polynomial_real_root_count` accepts signed integer coefficients for a declared
degree 0..3 polynomial and returns the exact number of **distinct** real roots
in the closed interval `[lower,upper]`. It also marks exact roots at each
endpoint. Repeated roots count once. No approximate root coordinates, tolerance,
root isolation intervals, multiplicities, or complex-root count are returned.

This is an independent numerical capability: the existing polynomial resultant
tests common complex roots of two polynomials, scalar nth/cube-root cores take
roots of integers, interpolation evaluates a polynomial from nodes, and the
symmetric 2x2 eigen core solves a constrained matrix spectrum. None counts the
distinct real roots of an arbitrary coefficient polynomial in a runtime interval.

## Interface and numerical contract

| Parameter | Default | Legal range |
| --- | ---: | --- |
| `DATA_W` | 8 | 1..16 |
| `MAX_DEG` | 3 | 1..3 |
| `TAG_W` | 8 | 1..32 |

All coefficient and bound ports are signed `DATA_W`-bit two's-complement
**integers**, without fractional bits. The entire signed domain is supported.
One accepted command captures `s_c0..s_c3`, `s_degree`, `s_lower`, `s_upper`,
and `s_tag`. The polynomial is `sum(c_i*x^i, i=0..degree)`; coefficients above
the declared degree are ignored. Degree is a 3-bit unsigned value so invalid
degrees remain representable. Illegal static parameters fail elaboration through
the unresolved `polynomial_real_root_count_invalid_parameter__see_README` module.

| Output | Meaning |
| --- | --- |
| `m_count[2:0]` | Number of distinct real roots, 0..3 |
| `m_endpoints[0]` | Exact polynomial zero at lower bound |
| `m_endpoints[1]` | Exact polynomial zero at upper bound |
| `m_status[1:0]` | 0 success; 1 bad degree; 2 reversed interval; 3 zero declared leading coefficient |
| `m_degree`, `m_tag`, `m_lower`, `m_upper` | Captured command diagnostics |

Status precedence is the table order: bad degree first, then reversed bounds,
then zero leading coefficient. Errors return canonical zero count and endpoint
flags. A zero polynomial is rejected, including degree zero with `c0=0`;
the service never encodes infinitely many roots. A nonzero constant succeeds
with zero roots and zero flags. For `[x,x]`, count is one exactly when `f(x)=0`,
and both flags then equal one. No arithmetic rounding, clipping, or epsilon is used.

`clk` is the sole clock. `rst` is synchronous, active high; assertion immediately
gates `s_ready` and `m_valid` low, and the next rising edge clears every register
and cancels the active command/result. There is no CE. Commands transfer only
on a rising edge with `s_valid && s_ready`; results transfer with
`m_valid && m_ready`. One command owns the core through computation and held
output. Source payload must remain stable while valid and blocked, except when
reset cancels it. Output and diagnostics remain stable under backpressure.
`s_ready` returns after result retirement; no same-edge replacement is accepted.
There is no frame/packet/last/keep protocol or runtime configuration update.

## Exact arithmetic and shared architecture

Normalize coefficients into `a,b,c,d` in descending degree order. For quadratic
`f=a*x^2+b*x+c`, let `delta=b^2-4*a*c`. If nonzero, the Sturm signs are those of
`[f, 2*a*x+b, sign(a)*delta]`; multiplying the true constant remainder
`delta/(4*a)` by a positive number preserves its sign. If zero, the single
distinct root is rational `-b/(2*a)` and is checked inclusively by cross products.

For cubic `f=a*x^3+b*x^2+c*x+d`, calculate:

```text
A = 2*(b*b-3*a*c)
B = b*c-9*a*d
C = -3*a*B*B + 2*b*A*B - c*A*A
```

The negative remainder of `f/f'` is `(A*x+B)/(9*a)`. For `A!=0,C!=0`, use
`[f, f', sign(a)*(A*x+B), C]`. The constant C is the negative remainder of
the derivative divided by the scaled linear remainder, multiplied by its
positive squared leading coefficient. If `A=0,B!=0`, the third term is constant
and the sequence ends there. If `A=B=0`, the triple root is `-b/(3*a)`.
For `A!=0,C=0`, the two distinct rational roots are `-B/A` and
`(2*a*B-b*A)/(a*A)`. These repeated-root branches avoid applying a square-free
Sturm endpoint rule at a shared polynomial/derivative zero. Linear roots use
`-b/a`. Rational denominators are normalized positive before comparing against
`lower*denominator` and `upper*denominator`; no divider is instantiated.

For square-free branches, Horner evaluation obtains each sequence value at
both bounds, ignores zeros when counting sign variations V, and returns
`V(lower)-V(upper)+is_root(lower)`. The variation difference includes an upper
endpoint root and excludes a lower endpoint root; the final term restores the
closed interval. Identical bounds therefore count a root only once.

Set `H=2^(DATA_W-1)`. Coefficients and bounds have absolute value at most H.
Conservative bounds, valid also for the minimum signed input, are:

| Quantity | Absolute bound |
| --- | ---: |
| quadratic delta | `5*H^2` |
| cubic A, B | `8*H^2`, `10*H^2` |
| C summands | `300*H^5`, `160*H^5`, `64*H^5` |
| C and partial sums | `524*H^5` |
| cubic Horner endpoint value / derivative | `4*H^4` / `6*H^3` |
| scaled linear Sturm value | `18*H^3` |
| simple rational numerator / denominator | `28*H^3` / `8*H^3` |
| rational bound cross product | `8*H^4` |

The signed work width `EW=5*DATA_W+7` has positive magnitude capacity
`2^(5W+6)-1`, exceeding `524*2^(5W-5)` by ample margin. All operands are extended
to EW before fixed shifts and adds. Intermediate Horner partials and every
scheduled multiplication are within these bounds. No cancellation assumption
is required. The testbench additionally compares every full unsigned product
against an independent `2*EW`-bit multiply and rejects signed overflow.

One signed-magnitude, fixed EW-cycle shift/add multiplier is time shared by
coefficient invariants, Horner evaluation and rational comparisons. Ten products
form a cubic's invariants; at most three further products form a second rational
root. The longest square-free cubic uses 22 products total. There are no data
`*`, `/`, `%`, floating-point operations, square-root units, vendor primitives,
RAMs, arrays of coefficients, or external arithmetic dependencies in production
RTL. Fixed constant scaling uses shifts/adds. The alternative generic fraction
polynomial-division architecture would require wider rational state and a
divider; parallel product/Horner paths trade substantially more logic for lower
latency and were not selected for this bounded scalar service.

The exact declared persistent state is `16*EW + 2*W + TAG_W + clog2(EW) + 46`
bits: 13 signed EW registers, three unsigned EW multiplier registers, command
diagnostics, and explicit control. This is 828 bits by default and at most 1509
bits. There is no state memory. Qualitative resource risk is LOW within the
supported range, based on structure rather than synthesis. No DSP, LUT, FF,
frequency, power, or implementation-area measurement is claimed.

With uninterrupted clocks, first-valid latency is at most `22*EW+100` rising
edges after command acceptance (1134 default, 2014 maximum). Errors and constants
complete after one edge. The cubic maximum follows from ten invariant products,
twelve endpoint Horner products, and fewer than 100 fixed controller edges;
other branches are shorter. Input/sink stalls add unbounded external waiting.
The design is iterative, accepts no concurrent command, and claims no clock
frequency or physical throughput. All state has a synchronous reset, which may
affect implementation routing even though its source-level size is small.

## Offline integration and bounded evidence

Compile from this directory using `files.f`; the independent default wrapper is
`example/polynomial_real_root_count_example.sv`. Every production dependency is
local. Python 3 standard library and native Icarus are required only for tests.
`SOURCES.md` records the fixed upstream read-only reference and full-license
inspection; no external code or run-time Python package is needed by the core.

`TEST_PLAN.json` and six committed fixture files are frozen before the first HDL
child. `run_tests.py --run` verifies those hashes, runs the frozen 21-child matrix
with a 20-second limit per child, and writes raw receipts to `verification.json`.
TIMEOUT is terminal; remaining work is NOT_RUN, with no retry or smaller fixture.
Compilation failure leaves its simulation NOT_RUN. The matrix has version and
core/example syntax checks, six compile/simulation pairs, and six named illegal
parameter elaboration rejects. It performs no synthesis, PnR, STA, hardware,
external dependency checks, or inherited numeric reruns.

The oracle first obtains the square-free part using exact Fraction polynomial
gcd/division, then counts positive roots under a Mobius interval transform by
Descartes sign variations and rational bisection. It does not reproduce the DUT's
closed-form invariant/degeneracy formulas. Fixed analytic examples check that
oracle before generation. Main fixtures include exhaustive small coefficient
alphabets/ordered intervals, signed extrema, ignored upper coefficients, all
errors/precedence, deterministic random vectors, irrational/repeated roots,
endpoint and singleton intervals. Every next main command is actually offered
while the previous is blocked and survives through retirement and acceptance.

Immediate reset probes cover all 17 FSM states where applicable, multiplier
first/middle/last iterations, each invariant operation, rational second-root
operations, Horner polynomials/endpoints, degeneracies, error/success held outputs
and a blocked source. Each reset is followed by a full analytic `-x` command,
checking count/flags/status/degree/tag/bounds, held output, retirement and absence
of stale output. `verification.json` is the authority for actual finite test
status and receipts. The source is always **HW_UNVERIFIED**; finite unit evidence
does not establish physical implementation or unrestricted formal correctness.
