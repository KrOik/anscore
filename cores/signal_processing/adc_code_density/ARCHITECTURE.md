# Numerical, resource and service contract

The measurement is a record reduction rather than a high-rate transform.
Storing all ADC samples would need8*N bits but would still need a histogram or
repeated recounting. A parallel256-counter bank would increase update decode
and read selection. The selected architecture reuses the existing synchronous
256-bin RAM histogram with one read/modify/write every two accepted clocks,
then shares one9-bit-factor serial multiplier and one iterative integer divider
for all report rows. The actual capture example supplies the distinct short
II1 acquisition window when needed. No PPA search or physical measurement has
been performed.

Let `C=max(1,ceil(log2(N+1)))`, `K in1..256`, `P=C+9`, `A=C+10`,
`F=FRAC_W`, `D=A+F` and `Q=F+10`.

| Quantity | Representation and bound |
| --- | --- |
|Histogram count, selected total, selected prefix|Unsigned C;0..N, N<=65535.|
|Selected bin count K|Unsigned9;1..256, not truncated to8.|
|Prefix*K and expected prefix ordinal*T|Unsigned P;0..256*N<2^(C+8).|
|DNL numerator|Signed A;`-T <= K*H-T <=255*T`.|
|INL numerator|Signed A;absolute value at most255*T.|
|Magnitude before scaling|Unsigned A;never the signed minimum.|
|Divider numerator|Unsigned D;abs(numerator) concatenated with F zeros.|
|Divider denominator|T zero-extended to D;division starts only if T>0.|
|RNE magnitude|D+1 bits, including carry;twice remainder uses D+1.|
|Signed rounded temporary|D+2 bits;positive magnitude explicitly sign-extended.|
|Public Q result|Signed Q;legal magnitude<=255*2^F, safely within±512*2^F.|

The conservative A and Q widths leave guard bits; no supported legal input
clips. Multiplications/subtractions are exact. Every unsigned product receives
an explicit positive sign bit before subtraction. The two signed errors are
normalized independently by their absolute magnitude, using the divider's
exact quotient/remainder. Add one when2*r>T or when2*r==T and the floor quotient
is odd, then restore the sign. Thus negative ties follow symmetric nearest-even
semantics; a zero result has no negative-zero encoding. Inexact means remainder
nonzero, independently of whether rounding changes the floor quotient.

First scan reads selected histogram bins and sums T. If T==0 it emits status3
without invoking arithmetic. The second scan adds H to a prefix, computes one
product K*prefix, and obtains DNL by subtracting the previous prefix product
and T. Expected-prefix accumulation adds T once per selected bin; INL subtracts
this exact accumulated expectation. This eliminates a second multiplication
per bin without moving a rounding boundary. At the final selected code,
prefix=T and expected-prefix=K*T, hence exact final INL numerator0. DNL numerators
sum to0 as an independent whole-record invariant.

The existing histogram's fixed FRAME_WIDTH=N/FRAME_HEIGHT=1 ensures that its
COUNT_WIDTH=C can hold the entire record even if every code is identical. No
array reset loop is added. Each accepted valid new command starts its256-write
clear pass. Collection and report readback never overlap. Both scans use one
request and one held response at a time, and check bin/tag/error before using
the count. No same-bin read/write forwarding assumption is needed: collection
already owns a complete synchronous read/modify/write pair per sample.

Logical storage is256*C bits,3328 bits at default4096 samples and4096 bits at
maximum65535 samples, plus the unchanged multiplier/divider registers and
control. The capture example adds256*8 bits. These are logical bit counts, not
claims about inferred BRAM, LUTRAM or device allocation. The multiplier performs
9 CSA iterations followed by `ceil(P/8)` byte carry folds; the divider performs
D restoring iterations per normalization. Exactly one multiplier and one
divider are instantiated, time-shared between all codes and DNL/INL divisions.
Expected bottlenecks are histogram update feedback and divider/RNE control;
there is no combinational wide divide or full-rate parallel multiplier bank.

With continuously available input and always-ready outputs, a conservative
command-to-DONE-retirement upper bound is:

```
2*N + 262 + K*(24 + 2*D + ceil(P/8)) clocks
```

It includes histogram clear, two-clock sample service, first-scan request/
response round trips, the two normalization operations per row, state handoffs
and final completion. It is a conservative structural budget, not a measured
latency or an Fmax claim. The global maximum is160004 clocks at N65535/F16/K256.
Output stalls, input gaps, missing trigger and held DONE can extend the elapsed
time without bound. Acquisition input II is2 after the256-clock clear; row
output is serialized by both divisions and source RAM requests. Repeated
commands wait until all current rows and DONE have retired.

The trigger example's PRE0/POST255 capture has a single synchronous RAM stage.
The trigger accompanies an actual accepted sample. Before the trigger, the
record has no prehistory requirement; after it,255 accepted observations finish
the256-code window. Capture replay honors the histogram's ready signal and
holds data/last while stalled. Arm acceptance is jointly fenced with the core;
an invalid reversed range produces an estimator error without leaving an armed
capture. No generic buffering layer or alternate protocol has been introduced.

The independent Python model uses Counter, direct selected-list prefix sums,
Fraction and whole-number divmod. It does not reproduce the two RAM scans,
prefix-product recurrence, expected-prefix accumulator or divider FSM. Its
only runtime path is one isolated archived child per profile after root gate.
The testbench consumes archived literal samples/expected rows, checks every
exact field and signed Q result, source/output/DONE stability, command ownership,
all-zero selected totals, endpoints, full capacity, malformed last markers,
live resets, and recovery. N257/F7 includes negative half ties and odd/even RNE
choices. The maximum record tests both signs at the largest possible magnitude.
The trigger example adds discarded pretrigger codes and an actual capture path.

No old testbench, regression, model, synthesis, routing, STA, board or PPA tool
is included in this qualification. Reset/error rows remain provisional until
successful DONE; a source that violates ready/valid has no delivery guarantee.
