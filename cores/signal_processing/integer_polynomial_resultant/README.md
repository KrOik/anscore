# Exact integer polynomial resultant

Original portable RTL receives raw integer coefficients of two polynomials and
returns their exact signed resultant. For nonzero polynomials of declared
degrees m,n, this is the determinant of the (m+n)-square Sylvester matrix.
For positive degrees, a zero resultant means the polynomials have a common root
over the algebraic closure of the rationals; it does not return root coordinates
or a GCD. This adds integer polynomial elimination/common-root detection beyond
GF(2) polynomial services, fixed 2x2 solves and node interpolation.

Qualification is recorded in `verification.json`: finite syntax/unit evidence
only; HW_UNVERIFIED. No synthesis, PnR, STA, hardware or expanded regression.

## Inputs, outputs and framing

`DATA_W=W` is1..16 (default8), `MAX_DEG=D` is1..3 (default2), `TAG_W` is1..32
(default8). Each accepted beat carries two signed W-bit integers `s_a,s_b`.
Beat index i provides the ascending coefficients of x^i. The first accepted
beat captures three-bit unsigned `s_degree_a`, `s_degree_b` and `s_tag`; later
degree/tag fields are ignored. Declared degrees must be0..D and each leading
coefficient must be nonzero. Leading zeros are rejected rather than normalized.
Unused channel coefficients above that polynomial's degree are ignored.

There is no KEEP or FIRST input. Every frame has at least one accepted beat and
ends with accepted `s_last`. Exactly `max(m,n)+1` beats are required. Excess
beats are drained until the accepted tail. Storage retains only the first D+1
pairs; `m_count` saturates at D+2, so every overlong frame remains detectable.
No accepted tail means an open frame and no autonomous result.

`m_status` uses ordered validation:1 bad declared degree, otherwise2 incorrect
frame length, otherwise3 zero leading coefficient, otherwise0 success. All four
statuses are reachable in every supported profile. On error, `m_resultant` and
`m_common_root` are zero; count, original captured degrees and tag remain
diagnostic outputs. Missing coefficients are never read. A short/long frame is
not separately labeled zero-leading. No numeric overflow/saturation status is
needed because the supported result width is exact.

Success returns `m_common_root=(m_resultant==0)`. For nonzero constants a,b,
`Res(a,g)=a^n`, `Res(f,b)=b^m`, and the constant/constant empty determinant is1.
Examples with ascending coefficient lists:

- f=`[0,-1]`, g=`[-1,-1]` return1.
- f=`[1,0,1]`, g=`[-1,0,1]` return4.
- f=`[1,0,0,1]`, g=`[-1,0,0,1]` return-8.
- Swapping f,g multiplies the resultant by `(-1)^(m*n)`.

One rising-edge clock, synchronous active-high `rst`, ordinary ready/valid and
no CE. Inputs transfer on `s_valid && s_ready`, with consecutive collection
beats at II1. Every source field must remain stable while valid and blocked.
One frame owns computation and output until `m_valid && m_ready`; input is
blocked during computation and held output. Every valid result field stays
stable under backpressure. A preoffered next frame can transfer on the edge
after the current result retires. Source gaps and sink stalls may be unbounded.

Reset gates ready/valid low immediately and cancels all owned work at the next
rising edge, including partial input, arithmetic, held result and blocked source.
Public registers clear. Coefficient RAM is unreset and overwritten within the
current required prefix before reads; permutation banks are initialized before
use. No CDC, memory-mapped side port, bus error or external memory is involved.

## Exact arithmetic, architecture and budget

Let `N=m+n`, `Nmax=2D`, `Fmax=Nmax!`. Signed result/working width is
`NB=Nmax*W+clog2(Fmax)+1`: default38 bits, supported maximum107. A determinant
term has N signed factors, each magnitude at most `2^(W-1)`, so its magnitude
is at most `2^(N*(W-1))`. At most N! such terms contribute to any partial sum;
NB covers the triangle bound, every intermediate product and sign restoration.
Magnitude conversion includes the minimum negative input. No quantization,
rounding, floating point, division or reduction occurs.

A paired coefficient RAM has one synchronous read port. Sylvester entries are
selected from that RAM by row, permutation column, degree and shift. Structural
off-band zeros still take a read and full multiply schedule. Heap's algorithm
enumerates every permutation using two tiny bounded register banks; each swap
flips parity. One reused unsigned NB-bit shift/add engine takes W steps per
factor, with separate sign. One signed sum accumulates all terms. There is no
runtime `*`/`/`, parallel multiplier bank, vendor primitive or coefficient image.

This deliberately caps factorial work at N<=6; it is not a scalable dense
matrix engine. Every valid nonconstant frame evaluates exactly N! terms and
N*N! factors. From an accepted tail to first valid, a conservative bound is
`3+N!*(N*(W+3)+N+2)` clocks. Errors and constant/constant success take exactly1.
Default full quadratic bound is1203; the full supported cubic/W16 bound is87843.
The permutation search depends only on N; values and zero terms do not shorten
service. Output transfer requires another edge, and caller stalls add delay.

Define `AW=max(1,clog2(2D))`, `RW=max(1,clog2(2D+1))`,
`CW=max(1,clog2(D+3))`, `SW=max(1,clog2(W))`. Declared storage comprises:

| Storage | Formula | Default | Supported maximum |
| --- | --- | ---: | ---: |
| Paired coefficient RAM | `2W*(D+1)` |48bit|128bit|
| Permutation/counter registers | `2*(2D)*AW` |16bit|36bit|
| Other scalar/read/output registers | `20+CW+3RW+SW+TAG_W+3W+5NB` |257bit|651bit|
| Total declared stored bits | sum |321bit|815bit|

These are declaration counts, not physical measurements. NB-wide addition and
conditional negation, small indexed register muxes and factor-address arithmetic
remain combinational. RAM inference, LUT/FF/BRAM/DSP mapping, clock rate, power
and device fit are unmeasured. Qualitative resource risk is LOW default/MEDIUM
maximum; the maximum also has a substantial bounded service-time cost.

## Offline closure and finite evidence

Compile `files.f` from this directory. `example/files.f` includes the default
`resultant_quadratic` wrapper exposing the full interface. The closure needs no
includes, packages, tables, generated coefficients, sibling RTL or network.
All local code is original Apache-2.0 under root LICENSE/NOTICE; fixed actual
upstream source and complete-license inspection are recorded in SOURCES.md.

`python -B run_tests.py` regenerates the frozen vector hashes and executes only
the21 children in TEST_PLAN.json. The primary oracle uses exact Fraction
polynomial Euclidean remainders and resultant recursion, rather than Sylvester
term enumeration. A second Gaussian elimination crosscheck and swap-sign
identity validate each successful fixture. The TB independently derives
permutation Lehmer ranks and inversion parity, rejecting duplicate terms and
requiring the complete N! population. It checks full public output, first-valid
bounds, exact factor/shift counts, coefficient ownership, collection II1, held
fields and actual next-frame acceptance after input backpressure.

Six fixed W/D/T profiles are1/1/1,3/1/3,4/2/8,8/2/8,8/3/8,16/3/32. Each has
29 immediate reset/full analytic fresh probes covering all12 states, multiplier
first/middle/last, permutation swap/carry/terminal, saturated collection,
structural/negative factors and held normal/common-root/all-error results.
W1 multiplier phases alias one step. D1 has no off-band structural zero or even
nonterminal Heap index: the frozen aliases use a present zero coefficient and
terminal index2. Degree0/1 small alphabets and monic quadratic grids supplement
all degree pairs/extrema; each D3 profile has exactly8 cubic/cubic fixtures.
The explicit finite domain does not prove every supported coefficient tuple,
degree, schedule or parameter combination.

Every compiler/simulator child has a20-second hard limit. Any TIMEOUT terminates
the matrix and preserves TIMEOUT/NOT_RUN without retry, smaller fixtures or a
larger timeout. Ordinary failures may be fixed and the identical frozen matrix
rerun; original failed records/source hashes remain embedded in the receipt.
