# Interface and numerical contract

`MAX_SAMPLES` is a static integer in 3..256 (default256); `TAG_W` is 1..32
(default8). Unsupported static values instantiate an undefined named module and
must be rejected at elaboration. Input samples are fixed signed16 integers.
Phase is fixed unsigned24 binary turns: `0x000000` is zero and `0x400000` is a
quarter turn. Upstream owns phase correctness and alignment with the sample.

A command is accepted only on `c_valid && c_ready`. `c_count` is unsigned32;
legal N is 3..MAX_SAMPLES. Its tag and requested count are returned verbatim.
No sample is accepted with the command or before it. Samples are accepted only
on `s_valid && s_ready`, and may have arbitrary gaps. Each accepted sample and
phase pair is retained while the serial computation runs. Unaccepted input pins
have no effect. This is a backpressured measurement interface, not an unbuffered
full-rate ADC interface.

Exactly N sample beats belong to a command. `s_last` must be asserted if and only
if the accepted beat is the Nth. Early last returns FRAME_ERROR immediately;
missing last on the Nth beat also returns FRAME_ERROR immediately. The offending
beat is included in `m_count`. No further beat belongs to that failed command.
An illegal command returns BAD_COMMAND and consumes zero samples. A legal
command without all required sample beats can wait indefinitely; there is no
wall-clock input timeout.

The reference basis is the unchanged `stream_sincos` at PHASE_W24, OUT_W18,
ITER20. Its signed outputs c and s use Q2.16, with unit Q=65536. The fit target is
these quantized c/s values, including their rounding, not ideal real trig.
For accepted samples x, accumulate C=sum(c), S=sum(s), X=sum(x), CC=sum(c*c),
SS=sum(s*s), CS=sum(c*s), XC=sum(x*c), XS=sum(x*s), then form:

```
A = N*CC - C*C       B = N*CS - C*S       D = N*SS - S*S
u = N*XC - X*C       v = N*XS - X*S       delta = A*D - B*B
I_num = 65536*(u*D - v*B)
Q_num = -65536*(v*A - u*B)
```

The estimated model is `x ~= dc + I*c/65536 - Q*s/65536`. `I=I_num/delta`
and `Q=Q_num/delta` are physical sample units. The shared denominator is exact
and unreduced; numerator signs use two's complement. There is no boxcar
half-amplitude factor. The DC nuisance term is eliminated but is not output.

Status is unsigned3:

| Value | Name | Numerical fields |
|---|---|---|
|0|OK|Exact rational fit; positive denominator and A/B/D diagnostics|
|1|BAD_COMMAND|I/Q/denominator/Gram zero; accepted count zero|
|2|FRAME_ERROR|I/Q/denominator/Gram zero; offending accepted beat counted|
|3|RANK_DEFICIENT|I/Q/denominator zero; A/B/D retained|
|4|INTERNAL_RANGE|I/Q/denominator/Gram zero; accepted count retained|

An exact zero determinant means the three-column [c,s,1] fit lacks full rank.
A positive determinant is not an error or conditioning guarantee: a nearly
singular window can magnify sample noise, phase error, and trig quantization.
The host can assess the reported centered Gram matrix [A B; B D]. There is no
near-singular threshold, frequency search, PLL, residual statistic, confidence
estimate, calibration, or amplitude/phase conversion. INTERNAL_RANGE guards are
defensive; WIDTH_PROOF.md shows they cannot trigger for legal reachable inputs.

One result is held until `m_valid && m_ready`. Every output field remains stable
while held. Neither commands nor samples are accepted during that hold, and the
next command may begin only after retirement. `m_requested`, `m_count`, and
`m_tag` are meaningful for every status. Other numerical fields are meaningful
only as specified above. Results are not promised while `m_valid` is low.

`rst` is synchronous, active high: assert it across at least one rising edge.
Handshake outputs are suppressed while high. The rising edge cancels the active
window, in-flight CORDIC/multiplier operation, and any pending result. A
registered bridge drives the reused multiplier's asynchronous active-low reset
from that edge. Ready returns only after a complete reset bridge edge, preventing
stale product ownership. Reset supplies no completion/error result. Without a
reset edge, startup state is unspecified.
