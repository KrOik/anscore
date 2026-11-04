# Congruence merge

Original, dependency-free SystemVerilog preparation service for two simultaneous
periodic constraints. For positive unsigned moduli `m,n`, merge signed residues
`a,b` into the unique `0 <= solution < period` satisfying both congruences;
`period=lcm(m,n)` is the least positive repeat period. Noncoprime moduli are
accepted exactly when compatible. Modulus one is legal.

Parameters: `W=8` (legal 1..16), `TAG_W=8` (legal 1..32). Residues are signed W
bits; moduli unsigned W; solution and period unsigned 2W; tag opaque TAG_W bits.
The full input range includes signed minimum and unsigned maximum. Status is
0 success, 1 only m zero, 2 only n zero, 3 both zero, 4 incompatible positive
moduli. Every error returns zero solution and period and preserves the tag.
Illegal static parameters fail elaboration with named marker
`congruence_merge_invalid_parameters__see_README`.

Ordinary ready/valid, one clock and one command owner. Capture on
`s_valid && s_ready`; response retires on `m_valid && m_ready`. Hold every input
field and valid until acceptance or reset; every output field and valid remains
stable under backpressure. Input stays blocked through response retirement;
the next command can be accepted no earlier than the following edge. High `rst`
immediately gates both ready and valid low; its next rising edge cancels the
owner and clears public output registers. Reset is synchronous high, with no
clock enable, CDC, or external memory. `m_solution/m_period/m_status/m_tag` are
meaningful only with valid. Internal arithmetic state is initialized before use.

The chosen low-area residue-orbit architecture trades throughput for a small
bounded arithmetic datapath. One restoring remainder unit performs four W-step
jobs: `abs(a)%m`, `abs(b)%n`, `m%n`, and normalized `a%n`, each followed by one
RETURN edge. Signed normalization produces `r1=a mod m` and `r2=b mod n` in
their nonnegative intervals. It then traverses `candidate=r1+k*m` and its residue
modulo n until the residue repeats. The first match supplies the canonical
solution; the complete orbit supplies the exact least period. A final edge
subtracts r1 from the end candidate. An inverse/multiply chain and extended
Euclid were considered; avoiding those operators suits a low-rate alignment
preparation service. This core does not generate clocks or synchronize payload.

Exact latency, accepted edge to first post-edge response valid:

- Zero-modulus error: 0 cycles.
- Positive moduli, success or conflict: `4W+5+n/gcd(m,n)` cycles.
- Domain maximum: `4W+5+2^W-1`, default 292, W16 65,604.
- Always-ready acceptance interval is latency+2 cycles; arbitrary output
  backpressure adds an unbounded wait. The whole orbit runs even after a match.

Width and termination proof: signed magnitudes fit unsigned W, including the
minimum negative input. The restoring invariant is remainder<divisor, so the
W+1-bit trial is sufficient. Orbit residue and step are both <n; their sum<2n
fits W+1 and needs at most one subtraction. The orbit length is
`L=n/gcd(m,n)`, between 1 and n, and enumerates exactly one residue class of
candidate modulo lcm. It contains exactly one match if compatible and none
otherwise. For `M=2^W-1`, the temporary end candidate satisfies
`r1+L*m <= (m-1)+m*n <= M^2+M-1 = 2^(2W)-2^W-1 < 2^(2W)`.
Thus even the temporary end value fits unsigned 2W. The final period m*L<=M²
also fits; every pre-end candidate is less than m*L, proving canonicality.

Source-level declaration budget is exactly
`16W+12+max(1,clog2(W))+TAG_W` register bits: default 151, maximum 304.
There are no arrays, RAM, ROM, multiplier, divide/modulo operator, DSP primitive,
vendor primitive, or sibling dependency. Arithmetic includes a 2W candidate
add, a separate FINISH subtraction, a W+1 restoring subtract/compare and a W+1
orbit add/reduce path. They are source-level bounds, not mapped-cell counts.
Resource risk is qualitatively LOW; the bounded orbit has exponential-in-W
worst latency and targets preparation workloads. No LUT/FF/DSP mapping, timing,
power, synthesis, PnR, STA or board result is claimed (`HW_UNVERIFIED`).

From this directory, `files.f` compiles the core and `example/files.f` compiles
the complete `phase_merge16` wrapper (W16, TAG8). The wrapper exposes the same
protocol and 32-bit solution/period. No generated simulation file is required
for either compilation.

`python run_tests.py --freeze` writes the finite TEST_PLAN and fixtures before
the first HDL child. `python run_tests.py --run` executes exactly the frozen
19 compiler/simulator children, each with a hard 20-second timeout. A TIMEOUT
is terminal; no retry, matrix reduction or larger limit is permitted. Every
ordinary failure preserves the exact source, plan, receipt and NOT_RUN suffix
under `failure_archive/`; receipt replacement is refused. A same-stimulus repair
must retain that evidence. A successful receipt is immutable. `--audit` checks
all source/fixture/plan/receipt hashes and certificates offline without HDL.

Six frozen profiles are W/TAG_W=(1/1,2/3,3/8,5/8,8/8,16/32). W1..3 exhaust
every a,b,m,n bit tuple (16,256,4096). Larger profiles have fixed directed and
seeded inputs including signed extrema, zero and one moduli, equal/noncoprime
compatible/conflict cases, full-width coprime moduli, 32-bit results above 2^31,
and the 65,535-edge orbit. The independent Python oracle uses GCD and modular
inversion; W1..3 also enumerate every candidate integer below the LCM. No
upstream code executes. Exact arithmetic certificates check all four divider
returns, every orbit candidate and residue, match count, period and latency.

The harness queues the actual next frozen token until its acceptance and checks
all input fields on every stalled edge. Every result is held for at least three
cycles with all fields checked. Each profile also resets immediately at 21
observed boundaries: idle; first/last restoring step of each job; each RETURN;
ORBIT before/after the first match; FINISH; success and all reachable error
outputs. There is no intervening active edge before reset assertion. W1 cannot
have a conflict or a second orbit edge after matching: targets 20 and 14 have
explicit success/FINISH aliases recorded in trace. After every reset a complete
analytic fresh transaction is accepted, held, checked and retired. Coverage
includes every state, all four jobs and every status reachable at that width.

See SOURCES.md for actual semantic deduplication, the pinned upstream semantic
reference and its full-license preflight. Delivered production code is original
Apache-2.0 under the repository LICENSE/NOTICE.
