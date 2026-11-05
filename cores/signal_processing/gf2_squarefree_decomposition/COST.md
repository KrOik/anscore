# Width, storage and finite-work proof

No physical area, frequency, power or hardware throughput has been measured.
Default structural risk is LOW; the degree-64 priority-encode/variable-shift/XOR
path is MEDIUM. This is a shared scalar design, without RAM or DSP assumptions.

Let W=D+1, I=max(1,ceil(log2(D+1))), K=floor(log2(D)), and
J=max(1,ceil(log2(K+1))). Sequential declarations are:

| Register | Bits | Meaning |
|---|---:|---|
| f,c,w,y,z | 5W | current root-layer polynomial, residuals, GCD, pending factor |
| u,v,q | 3W | shared GCD/division remainders and quotient |
| iteration | I | current layer's multiplicity index, from 1 through D |
| level | J | root layer 0 through K |
| tag | TAG_W | owner metadata |
| state,operation | 3+2 | six controller states and arithmetic return role |

Total scalar storage is `8*(D+1)+TAG_W+I+J+5`: 157 bits at D16/T8 and 567
at D64/T32. Z is the explicit pending-factor/lookahead register. Output factor
is Z; degree is a combinational encoder of Z; multiplicity is iteration shifted
by level; last is the unit test of committed W/C. There are no extra output
payload registers, RAMs, arrays or factor buffers. `degree_u/v/z` and `scan`
are assigned entirely in the combinational encoder and are not sequential state.

## Exact coefficient widths

Every stored polynomial has degree at most D, so W bits include its entire
monic leading term. This includes F/1 and a possible full-degree emitted factor;
D-bit storage would be insufficient. All polynomials are unsigned GF(2)
coefficient vectors, not signed integers or fixed-point values.

For GCD, nonzero U/V permit cancellation only if deg(U)>=deg(V). The shift
is nonnegative, and the highest term of V shifted by their degree difference
has degree deg(U)<=D. The complete shifted value therefore fits W bits before
XOR. Cancellation strictly decreases deg(U), with deg(0)=-1. Swapping preserves
both polynomials exactly. A zero U is explicitly swapped before degree encoding
is used, so the encoder's zero convention does not change arithmetic.

Every division divisor is nonzero. Initial C is gcd(nonzero F,F'), so C is
monic and divides F even when F'=0. Layer Y=gcd(W,C) divides both nonzero W
and C. Thus F/C, W/Y and C/Y are all exact, nonzero quotients and terminate
with zero remainder. Quotient bits are at positions 0..D, so Q also needs W
bits. The TB checks divisor nonzero, cancellation identity, quotient-bit update
and zero remainder at every actual division completion.

Over GF(2), the initial derivative gcd has only even factor multiplicities.
After all current-layer odd-multiplicity components are removed, residual C
again has only even multiplicities. C is therefore a perfect square whenever
the root transition is taken. Reading its even coefficients computes its exact
square root; no discarded odd coefficient may be nonzero. Root degree halves,
so level never exceeds K. There are at most K+1 initializations.

At level k, any emitted factor with layer index i has positive degree and
global multiplicity e=i*2^k<=D by the weighted degree identity. I bits represent
every e through D, including e=64. Iteration values that do not emit a factor
are still bounded by that layer's largest remaining odd multiplicity. A
nonfinal output cannot require increment past D: a multiplicity-D component
already consumes the entire input degree. Layer and iteration have separate
registers and separate range proofs; shifting never narrows a valid result.

## Group correctness and last

For an irreducible h with multiplicity e, the derivative removes one power
exactly when e is odd. In the current layer, W contains one h for each odd
remaining multiplicity. Repeated gcd/division steps retain h in Y until i=e;
then Z contains it exactly once and removes it from W. Consequently Z groups
all components of one multiplicity, is squarefree, and is coprime to every
other emitted group. Even residual multiplicities pass through a square root
and use the next power-of-two scale. Every original irreducible is recovered.

Before iteration i, the current layer satisfies
`F = product(previous_Z_j^j) * W^i * C`.
After computing Y, Z=W/Y and C_new=C/Y, the remaining part after pending Z is
`W_new^(i+1)*C_new`, where W_new=Y. The controller computes and commits both
new values before entering HOLD. The remaining product is unit exactly when
both W_new and C_new are unit; a nonconstant product over GF(2)[x] cannot cancel
to 1. This proves last directly, including subsequent root layers. Holding Z
through C/Y is the required lookahead, already counted above.

## Work and timing

A GCD cancellation decreases deg(U)+deg(V), initially at most 2D, to a final
sum at least -1: at most 2D+1 cancellations. Each swap strictly decreases
deg(V), initially at most D, so there are at most D+1 swaps. Add the final
V=0 check: `G<=3D+3` clocks. More precisely, whole Euclidean quotients q_j give
`G=sum(popcount(q_j))+number_of_divisions+1`, including an initial zero quotient
when the input degrees require a first swap. Initial V=0 takes one clock.

Exact quotient division takes one clock per monomial in the whole quotient,
then one terminal check: `Q=popcount(quotient)+1<=D+2`. There are no hidden
operand-copy stages between GCD termination and division, or between the two
layer divisions. INITIALIZE and each layer-loop dispatch each cost one edge.

At layer k, the number of inner iterations is the largest odd part of a
multiplicity belonging to that layer, or zero if none exists. Summing those
maxima is at most the sum of each group's degree times its odd part, which is
at most `sum(degree(F_e)*e)=D`. Hence at most D inner GCD calls, two divisions
per inner iteration, and K+1 initial GCD/division pairs are needed.

Writing L=K+1 and allowing one additional root-transition dispatch per layer:

```text
compute_clocks <= L*(1 + (3D+3) + (D+2) + 1)
                + D*(1 + (3D+3) + 2*(D+2))
               = L*(4D+7) + D*(5D+8).
```

The bounds are 24/246/1763/22833 at D=1/5/16/64. Compute clocks exclude HOLD
edges. Each emitted pair needs one retirement edge under an always-ready sink;
there are at most D pairs, so final retirement occurs no later than
acceptance+1779 at the default and acceptance+22897 at D64. Next acceptance
needs one further edge. Backpressure adds arbitrary HOLD edges and does not
change the exact compute gap after the preceding retirement. These are paper
bounds, not physical service rates or unrestricted formal results.
