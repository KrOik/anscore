# Reachable range and sign proof

All bounds below use legal N<=256=2^8 and signed16 |x|<=32768=2^15. The fixed
reused CORDIC has unit65536 and default error bound1 LSB, hence |c|,|s|<=65537
<2^17. The same coarse 2^17 bound also covers the complete signed18 domain
(including magnitude2^17 at its minimum, with non-strict inequalities). Thus the
storage proof does not depend on assuming that only ideal trigonometric points
are reachable. Bounds are mathematical integer bounds before narrowing.

| Quantity | Reachable magnitude bound | Storage |
|---|---|---|
|C,S|<2^25|signed56|
|X|<=2^23|signed56|
|CC,SS,CS|<2^42|signed56|
|XC,XS|<2^40|signed56|
|A,D|0..2^50|signed56|
|B|<=2^50|signed56|
|u,v|<=2^48|signed56|
|delta|0..2^100|unsigned112|
|u*D-v*B; v*A-u*B|<=2^99|signed113 temporary, checked signed112|
|I_num,Q_num|<=2^115|signed128|

The sums follow directly from N times each per-beat bound. For the tighter
centered quantities define cbar=C/N, sbar=S/N and xbar=X/N. Then
`A=N*sum((c-cbar)^2)`, `D=N*sum((s-sbar)^2)`, and
`F=N*sum((x-xbar)^2)`. Removing the nonnegative squared mean term proves
`0<=A,D<=N*sum(c^2 or s^2)<=2^50` and `0<=F<=N*sum(x^2)<=2^46`.
Cauchy-Schwarz applied to the centered vectors gives
`|B|<=sqrt(A*D)<=2^50`, `|u|<=sqrt(A*F)<=2^48`, and
`|v|<=sqrt(D*F)<=2^48`. It also proves `0<=delta=A*D-B^2<=2^100`.
Triangle inequality gives each final unshifted numerator magnitude at most
`2^48*2^50 + 2^48*2^50 = 2^99`. Multiplication by2^16 gives2^115,
well below signed128's positive limit2^127-1. Near-singularity changes the
ratio, not these unnormalized integer bounds.

All multiplier operands are signed56. Each absolute value is unsigned56
complement-plus-one, so even signed56 minimum has its correct unsigned magnitude
2^55; a signed negation in56 bits is never used as a magnitude. The reused
56x56 unsigned unit produces exact unsigned112. Prefixing a zero extends it to
positive signed113 before a possible signed113 negation. This safely handles
every signed56 product, including minimum times minimum. Paired products are
subtracted at signed113; products of arbitrary signed56 inputs fit within this
difference width, and legal fit values are substantially smaller.

For sample-product accumulation, `fits56(product)` is tested before taking the
low56 bits. The old sum and low56 product are sign-extended to57 bits for
addition; the top two bits must agree before narrowing to56. All legal partial
sum prefixes satisfy the table's same N<=256 bounds. C/S/X direct accumulators
also satisfy those bounds at every prefix. Centered A/B/D/u/v results must pass
`fits56`; A/D must be nonnegative. The determinant must be nonnegative and pass
`fits112` before storage.

The final signed113 difference is not blindly shifted. The mathematical bound
2^99 proves reachability safety, and `fits112` checks that bit112 equals bit111.
Only then `{difference[111:0],16'b0}` creates an exact128-bit two's-complement
representation of multiplication by2^16. For Q, negation first occurs at113
bits; both original and negated values must pass `fits112` before concatenation.
Consequently no reachable sign, negation, or shift is lost. Any defensive range
failure emits INTERNAL_RANGE and clears all numerical fields.
