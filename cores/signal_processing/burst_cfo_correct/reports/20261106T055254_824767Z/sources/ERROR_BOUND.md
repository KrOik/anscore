# B39 complete numerical budget

The reference is the exact integer prefix correlation, not an unknown physical
carrier. Let received complex signed12 words be `r[n]=I[n]+jQ[n]` and

```
P = sum(k=0..15, conj(r[k])*r[k+16])
E = sum(k=0..31, I[k]^2+Q[k]^2)
```

All prefix products/sums and `4*|P|^2/E^2 >= threshold/65536` are exact through
the unchanged detector's width contract. The qualification comparison is the
integer inequality `(|P|^2 << 18) >= threshold*E^2`; the floor includes equality.
Each complex term is signed25, accumulated P signed29; E unsigned29 covers
`32*2*2048^2=268435456`. Prefix storage is24*16 +24*32 +50*16=1952bits.

For nonzero P define `theta=atan2(Im(P),Re(P))` on the principal interval
`[-pi,pi)`. A positive rotation across the repeated halves gives positive theta.
The principal CFO estimate is `theta/(32*pi)` cycles/sample, modulo1/16. With
signed24 binary-turn estimate `p`, the exact correction word is
`FCW32=-(signextend(p)<<4) mod2^32`. This division by16 is exact in the32-bit
binary-turn format; there is no quotient rounding. The accumulator starts at0
and adds FCW only after each accepted corrected output. It has exact modulo
arithmetic; phi[n]=n*FCW32 mod2^32. Output stalls do not change sample time.

The existing atan2 guard-bit derivation with P24/ITER24 bounds circular phase
error by2 phase24 codes. In output-code units it is

```
ceil((2^24/6)*(2^(1-24)+8*24/(2^32-2*24))+24/512+1/2) = 2.
```

This includes finite iteration residual, coordinate shift errors, rounded Q62
angle constants and final phase RNE. It is independent of nonzero integer P's
magnitude. Axes are exact; zero is rejected. B39 does not inherit any historical
simulation, synthesis or temporal proof from this analytic helper bound.

Circular proximity alone is insufficient at the signed half-turn discontinuity:
choosing the other signed branch changes correction by1/16 cycles/sample. The
wrapper therefore rejects estimated signed p when
`p >= 8388604 || p <= -8388604`, including the exact half-turn. Every accepted
estimate is over4 codes from the discontinuity, so a <=2-code circular error
has the same principal branch as theta. This guard does not detect CFO aliases
outside the principal physical interval. Guard admission is defined by the
actual estimated code; near its4-code threshold it need not match a rounded
mathematical phase's admission. Frozen tests use exact axes, <1-code boundary
proximity and >40-code boundary separation, away from that uncertain admission.

For the replay sincos configuration PHASE32/OUT18/ITER24, S=65536 and AW=40.
The full helper component bound (angle constants/iteration, coordinate floor
shifts, inverse-gain constant and coefficient RNE included) is

```
D = 44/(7*2^40)
ceil(S*(2^(1-24)+2*24*D)+(3*24+2)/256+1/2) = 1 coefficient LSB.
```

Thus each actual coefficient differs from65536 times ideal sin/cos of the
exact accumulator phase by at most1. This is Q2.16, with both +/-unity
representable. It is not a unit-circle normalization claim for the rounded
coefficient pair.

Magnitudes: sample2048 needs unsigned12, coefficient magnitude needs18. One
unchanged unsigned serial multiplier, A18/B12, computes four exact30-bit full
products. Zero-extension to signed31 before optional negation preserves every
product. Signed32 registers hold `I*cos-Q*sin` and `I*sin+Q*cos`; these are well
within signed32 even for the complete representable18-bit coefficient domain
(`4096*131072=536870912`). Final RNE by65536 is exact for either sign, including
half-LSB ties. Signed12 saturation follows RNE and reports clips per component.
There is no internal saturation, product truncation or arithmetic wrap before
the deliberate phase-accumulator wrap.

For n<=4095, phase estimation contributes angle error at most
`delta_n=2*pi*n*2/(16*2^24)` radians. Both sin and cos are1-Lipschitz. For each
unrounded IQ lane, error from the exact-P mathematical rotation is therefore

```
epsilon_n <= (abs(I)+abs(Q)) * (1/65536 + 2*pi*n*2/(16*2^24))
          <= 4096 * (1/65536 + (44/7)*4095*2/(16*2^24))
          < 0.849 output LSB < 1.
```

The first term is coefficient CORDIC/quantization; the second is phase-CORDIC
and its final phase quantization accumulated over the burst. Computing RNE on
both the ideal and actual unrounded IQ adds at most1 to their difference, so
the rounded integer difference is strictly<1.849 and hence at most1 integer
LSB in exact arithmetic. The declared verification limit is a conservative
**2 signed12 output LSB per lane**, including numerical oracle rounding near
ties. Saturation is nonexpansive and cannot increase that difference. This
bound applies to arbitrary payload IQ and exact integer P, whether or not a
physical repeated waveform/CFO model exists.

The independent Python oracle uses direct integer sums and math.atan2/cos/sin,
never the CORDIC recurrence. The TB separately checks actual coefficients
against mathematical sin/cos of the exact phase accumulator (<=1LSB), then
computes direct full integer complex products, quotient/remainder RNE and clip
from those coefficients for an exact comparison. A second comparison checks
whole-burst outputs against the ideal exact-P rotation within2LSB. The phase
check permits2 circular codes relative to the independently rounded ideal
phase; the analytic bound above, rather than empirical maxima, controls the
contract. Double precision and a1e-6 allowance are used only for coefficient
oracle evaluation, far below one output/phase LSB, not to tune the RTL bound.

No physical CFO precision, detection probability, noisy-channel residual,
absolute phase recovery, frame synchronization, device frequency or hardware
qualification is established by this source-level analysis.
