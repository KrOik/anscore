# DF-II transposed Biquad/SOS: bounded shared-multiplier configuration

DSP02 covers a complete recursive filter with 1..4 active SOS, configurable
coefficients, stability screening and atomic state policy. This implementation
shares one multiplier and does **not** meet II=1. It is a resource-oriented
configuration; any future II=1 implementation remains separately tracked.

## Arithmetic and stability

Input/output signed16 Q1.15 (sign included); each coefficient signed18 Q3.15,
range [-4,4-2^-15], order b0,b1,b2,a1,a2, a0=1. Per section:

```
y  = sat16(RNE((b0*x+s1)/32768))
s1 = b1*x - a1*y + s2
s2 = b2*x - a2*y
```

Products retain all 34 signed bits; state is signed36 with 30 fractional bits
in normalized units. No intermediate rounding or saturation. Both x and feedback
y are bounded16-bit, every product magnitude<=2^32, |s2|<=2^33 and |s1|<=2^34;
state36 and guarded36-bit addition cover the ranges including full-scale input.
Conversion is nearest ties even for both signs, then signed16 saturation. The
clipping flag ORs saturation across sections for that transaction. Feedback uses
the clipped/quantized y, so overload is a nonlinear filter response, not linear
transfer-function equivalence. Cascaded section output quantizes once per section.

For every active quantized section reject unless all integer Jury inequalities
hold with margin>=32: 32768+a1+a2, 32768-a1+a2, 32768-a2. This conservative
margin2^-10 is a documented supported subset of stable denominators. B-coefficients
may be arbitrary in the signed18 range; gain can saturate. No arbitrary-coefficient
stability claim. Quantization can cause small fixed-point limit cycles even with
Jury-stable poles; coefficient/range and zero-tail tests measure rather than hide it.
Jury screening proves the linear quantized denominator condition only. It does
not prove arbitrary state-preserving coefficient switching stability or overload
nonlinear behavior. Near-unity supported poles can have appreciable quantization
deadbands; no universal precision or settling-time bound is promised.

## Interfaces and state policies

`clk`, synchronous active-low `rst_n`; signed16 Stream input/output, output
`m_tuser` = any section clipped. Valid and data/flag hold under backpressure.
Static `MAX_SOS` supports1..4, default4. Runtime `cfg_sections[2:0]` supports
1..MAX_SOS. `cfg_coeffs[90*MAX_SOS-1:0]` packs section0 first in low bits,
each section [b0,b1,b2,a1,a2] in ascending18-bit slices.

Atomic `cfg_valid/cfg_ready` accepts only idle with no output pending; it takes
priority over input. It validates all active denominators before committing any
field. `cfg_done/cfg_error` pulse for accepted requests, with error rejecting the
entire request and preserving active coefficients/state. `cfg_clear=1` clears
all section state; `cfg_clear=0` retains DF-II-T state exactly and is allowed only
if section count is unchanged. Retain may create an audible/large transient;
it is not a promise of bumpless transfer. Reset defaults to a single identity
section and clears all state/pending work. Tiny SOS state uses registers, no RAM.

## Throughput architecture

One registered signed18x16 multiplier; seven compute edges per SOS after input
acceptance: b0 multiply; y convert; b1 multiply; a1 multiply/accumulate; b2
multiply/s1 write; a2 multiply; s2 write and advance/emit. No combinational
feedback loop. No-stall transfer latency and initiation interval =7*S+1 clocks
(8/15/22/29 for S=1/2/3/4). Output buffer capacity1; accepting new input is allowed
on the edge draining the previous output. Long stalls add wall-clock delay but
do not recompute states or lose transactions. There is no clk_en or gated clock.

Real timing and resource evidence are separate from cycle counts. A one-DSP
serialized configuration cannot be advertised as one-sample-per-clock. The
resource/throughput tradeoff remains explicit for later chain planning.
