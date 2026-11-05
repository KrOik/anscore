# Architecture, exact widths and paper cycle budget

No physical resources or frequency have been measured. Default structural risk
is LOW; DEGREE64 is MEDIUM because priority encoding, degree subtraction, a
variable shift and XOR occupy the GCD cancellation path. Ordinary portable RTL,
without a device primitive or a specified operating-frequency claim, is used.

Let I=max(1,ceil(log2(D+1))) and C=max(1,ceil(log2(D))). Sequential declarations:

|Declaration|Bits|Lifetime|
|---|---:|---|
|polynomial,h,a,b,acc|5D|owner polynomial; whole residue; square operands and partial sum|
|u,v|2(D+1)|GCD remainders, including the complete monic P|
|tag|TAG_W|captured owner metadata, also directly drives the held output tag|
|round_index,square_left|I+C|round1..D; steps remaining0..D-1|
|state|3|seven stages|
|m_irreducible,m_kind,m_check_index,m_delta,m_witness_gcd|1+2+I+D+(D+1)|registered held result|

Total declared scalar storage is 9D+TAG_W+2I+C+9 bits:175 at16/8 and637 at64/32.
`degree_u`, `degree_v` and the loop variable `scan` are assigned entirely in
the combinational degree-encoding process, not sequential storage. The
checkpoint vector and X_BITS are elaboration constants. There are no arrays,
RAM ports, DSP/integer multipliers, dividers, ROM files or payload-reset loops.
Actual tool optimization and device mapping remain unverified.

For each square, A starts at H, B at H, and acc at0. After j steps:
acc is the XOR of the first j selected reduced shifted multiplicands;
A=x^j*H mod P and B=H>>j. Reduction of x*A replaces its x^D term with the
low coefficients of P. Thus A and every partial acc always have degree<D.
XOR has no carry. D bits suffice even though an unreduced square can have
degree2D-2. No high-degree product term is discarded before modular reduction.

GCD starts u=P and v=H XOR (x mod P), with degrees at mostD and D-1.
Both are unsigned coefficient vectors of D+1 bits. A swap changes neither
the represented polynomials nor their common divisors. A cancellation is used
only when u,v are nonzero and deg(u)>=deg(v); the shift amount is nonnegative.
Its highest product term has degree deg(v)+(deg(u)-deg(v))=deg(u)<=D, so the
entire shifted polynomial fits D+1 bits. XOR cancels the old leading term,
strictly reducing deg(u), with degree(0)=-1. Hence no valid shifted term or
remainder bit is lost. The gcd is monic automatically over GF(2).

Each cancellation strictly decreases deg(u)+deg(v); that sum starts at most
2D-1 and finishes at least-1, giving at most2D cancellations. Swaps occur
only when deg(u)<deg(v), including u=0, so each strictly decreases the degree
of the second remainder: at mostD swaps. One final v=0 check gives GCD
latency L<=3D+1 measured after its LOAD edge. More precisely, ordinary whole
Euclidean quotient polynomials q_j give
L=sum(popcount(q_j))+number_of_divisions+1, including the final swap to v=0.
For initial v=0, L=1 and the full P is the correct GCD.

An acceptance at E moves IDLE to SQ_LOAD. Each processed round costs one LOAD,
D STEP clocks and one CHECK: D+2 clocks. Each visited GCD adds one GCD_LOAD
clock and L GCD_STEP clocks. Consequently, if r rounds are processed:

```text
first_valid_clock - E = r*(D+2) + sum(L_i+1 over visited checkpoints)
                     <= D*(D+2)+omega(D)*(3D+2).
```

There is no hidden initializer or result-copy state. Final CHECK or the
rejecting GCD check writes all result fields and moves directly to HOLD.
D=1 still executes its true one-bit modular square: first valid is E+3 for
both P=x and P=x+1. The D-bit representation of x mod P is P's constant bit.
Default16 has one checkpoint at8 and upper338. Degree30 has three checkpoints
at6,10,15 and upper1236; degree63 has two at9,21 and upper4477; degree64 has
one at32 and upper4418. Using D<=64 and omega<=3 gives the conservative
global upper4806. These are paper bounds, not measured service rates.

HOLD does no arithmetic. Always-ready retirement is one edge after first valid;
the next owner can be accepted one further edge later. Output stalls preserve
all result fields and owner tag, and add arbitrary wait. A reset cancels all
such ownership and controls without initializing arithmetic payload storage.
