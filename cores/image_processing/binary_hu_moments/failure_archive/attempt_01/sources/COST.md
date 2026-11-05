# Bounds, declarations and static schedule

Let N=W*H, A=max(1,ceil(log2 N)), L=max(1,ceil(log2 max(W,H))), U=A+L,
and D=2^L. Every coordinate is0..31 and strictly less than D. A nonempty
foreground population satisfies1<=m<=N<=2^A. Define

```
RAW_W=A+3L+1
WORK_W=max(12U+9,18A+2)
COUNT_W=ceil(log2(N+1))
XW/YW=max(1,ceil(log2 W/H)); SW=max(1,ceil(log2 WORK_W))
```

All ten raw moments are nonnegative and at most m*D^(p+q), strict for a
positive degree; M00=m can reach2^A. RAW_W covers every raw accumulation,
including the final accepted pixel. Coordinate-square helpers use2L bits,
cubic helpers3L. Finite differences are evaluated only for an actual next
in-row coordinate or next row, never for an out-of-domain x=W/y=H.

For degree2, `Qpq=m*mu_pq` is integer; direct centered coordinates give
`|Qpq|<m^2*D^2`. For degree3 `Tpq=m^2*mu_pq` is integer and
`|Tpq|<m^3*D^3`. The strict bounds follow from |x-cx|,|y-cy|<D, including
negative centered coordinates. At m=1 these values are exactly zero.
The integer expansions in the fixed DAG are:

```
Q20=m*M20-M10^2; Q11=m*M11-M10*M01; Q02=m*M02-M01^2
T30=m^2*M30-3*m*M10*M20+2*M10^3
T03=m^2*M03-3*m*M01*M02+2*M01^3
T21=m^2*M21-m*M01*M20-2*m*M10*M11+2*M10^2*M01
T12=m^2*M12-m*M10*M02-2*m*M01*M11+2*M01^2*M10
```

Every component product before cancellation is <=m^3*D^3. The central
expression prefixes have absolute coefficient at most6 (Q at most2), so
those intermediate values fit even before applying the refined centered
bound at each completed Q/T. No narrowing is performed at a refinement.

INSTRUCTIONS.json lists all79 instructions, original variables, allocated
source/destination words, source shifts, and both `pre_bound` and `bound` as
`[C,p,q]`, meaning absolute value <=C*m^p*D^q. Bounds are propagated through
every add/sub prefix by triangle inequality and through every multiply by
the product of operand bounds. Only a completed Q/T uses the independently
proved centered bound above. Sources shifted by1/2 are bounded before the
operation. Static multiplication/shift/adds for coordinates are absent.

With B=m^3*D^3, |p|,|q|<4B, |u|,|v|<2B, so the two H5/H7 terms are each
<128*B^4 and their signed sum/difference is <256*B^4. This covers every
factor, product, prefix and final numerator, including signs and cancellation.
All other descriptor intermediates are smaller under m,D>=1. Thus every
descriptor magnitude is strictly below2^(12U+8), the signed limit of
WORK_W>=12U+9. Denominators use five positive products m^3,m^6,m^9,m^12,m^18;
the maximum is <=2^(18A), strictly inside the signed WORK_W range because
WORK_W>=18A+2. Their magnitude conversion cannot encounter signed minimum.
Neither zero numerators nor the all-zero m=1 descriptors change the schedule.

Each signed multiplication loads nonnegative magnitudes a,b via the same
adder in two separate ABS states. At bit t, accumulator is
`a*(b mod 2^t)` and remaining factor is `b>>t`. The next accumulator is at
most the full nonnegative product. If a remaining significant factor bit h
exists at h>=t, then `a<<t <= a<<h <= a*b`; therefore every used shift fits.
Once no remaining factor bit exists the shift freezes. If b starts zero,
the initial a still satisfies its own operand bound and no shift occurs.
All WORK_W steps execute even after the factor becomes zero. Restoration of
a negative result uses a separate adder state; there is no extra combinational
absolute-value/negation carry chain. No signed-minimum operand or result is
reachable. Testbench512-bit arithmetic safely covers all actual products,
centered prefixes and Fraction cross-products (<2^378 conservatively).

## Logical storage and operators

| Declaration | Bits |
|---|---:|
| scratch[32] | 32*WORK_W RAM payload |
| raw[10] (ten parallel-update scalar accumulators) | 10*RAW_W |
| scratch_q; operand_a/b/result; mul_shift/factor/acc; m_numerator/denominator | 9*WORK_W |
| xx,xy,yy; xxx,xxy,xyy,yyy | 18*L |
| x,y; capture_count,m_area; tag_q; mul_step | XW+YW+2*COUNT_W+TAG_W+SW |
| state/errors/raw_index/pc/out_index/mul_negative | 4+4+4+7+3+1=23 |
| Total scalar | 9*WORK_W+10*RAW_W+18L+XW+YW+2*COUNT_W+TAG_W+SW+23 |

Decoded op/addresses/shifts and ALU selections are fully assigned combinational
signals, not scalar storage. The elaboration loop integer is not an additional
runtime accumulator. No full-frame RAM, multi-read RAM, reset array clearing,
dynamic lookup data or external memory is required. The 32-word scratch has
exactly one synchronous read OR write each enabled edge and no collision.
RAW_STORE10 writes every initial source. Static liveness peaks at20 words;
READ_A/READ_B precede any aliased destination overwrite.

Default8x8/T8: RAW_W16,WORK_W117, RAM3744,scalar1325bits.
Maximum32x32/T32: RAW_W26,WORK_W189,RAM6048,scalar2246bits.
The capture frontend contains ten RAW_W accumulation adders and the bounded
coordinate finite-difference additions. The wide arithmetic engine contains
one WORK_W add/sub carry chain plus data selection, shifts by0/1/2 and fixed
single-bit multiplier shifts; it has no data `*`, divider, sqrt or ROM. Address
generation is word indexing. A source-level operator count is not measured
LUT/DSP/BRAM utilization. No synthesis or physical mapping was run.

## Paper-exact cycles and actions

RAW_STORE10; each of45 MUL instructions uses READ_A,READ_B,EXEC,ABS_A,ABS_B,
WORK_W bit cycles,SIGN_RESULT,WRITE: WORK_W+7. Each of34 ADD/SUB instructions
uses READ_A,READ_B,EXEC,WRITE:4. First output uses OUT_NUM,OUT_DEN,OUT_LOAD:3.
Consequently first-valid offset after final capture is
`10+45*(WORK_W+7)+34*4+3 = 45*WORK_W+464`. It is independent of pixel values
for every legal nonempty good raster. First handshake offset is +1; seven
continuously-ready retirements are separated by4 edges, so last-retire offset
is45*WORK_W+489. The TB deliberately stalls each response for two edges and
adds source bubbles; those pauses do not alter first-valid or action counts.

Per completed good frame: scratch actions10+79*3+7*2=261; non-bit ALU
operations34+45*3=169; multiplier bit checks45*WORK_W; direct raw checks10.
An erroneous frame performs none of these actions. A reset summary adds the
exact canceled-owner pre-execution prefix to one complete fresh good frame.
OBS records state/pc/step/raw-index/output-index, ownership mask, population,
accepted and retired counts. The checker uses those static ordinals to account
for every action without re-running arithmetic. Source/sink backpressure
does not cause repeated RAM or arithmetic actions while OUT_HOLD is stalled.
