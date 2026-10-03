# DSP11 causal cubic Catmull–Rom Farrow

Signed16 samples. Integer delay D=0..31 and fractional delay mu=U/4096,
U=0..4096 inclusive. The total nominal delay is D+1+mu input samples.
For current accepted sample index n, let a=x[n-D], b=x[n-D-1],
c=x[n-D-2], d=x[n-D-3], with x[k<0]=0. Define
A0=2b, A1=c-a, A2=2a-5b+4c-d, A3=-a+3b-3c+d.
y=(((A3*mu+A2)*mu+A1)*mu+A0)/2.
This is causal Catmull–Rom (cubic Hermite with centered slopes), not cubic
Lagrange. At mu=0/1 it reproduces b/c exactly. Startup uses zero history;
one output per accepted input, no implicit tail flush. Feed explicit zeros to
observe a finite signal tail.

RTL keeps eight fractional guard bits on branch/Horner values; each multiplication
by mu rounds nearest-even back to eight guard bits. Final /512 rounds nearest-even
and saturates signed16, flagging clipping. Signed29 intermediates and signed42
products cover all signed16 input extrema and all supported mu, with no wrap.
Conservative absolute branch bounds are |A3|<=8*32768, |A2|<=12*32768,
|A1|<=2*32768, |A0|<=2*32768. Since 0<=mu<=1, Horner absolute values
are at most (8+12+2+2)*32768*256 plus three half-unit rounding errors,
below 2^28. Products are below 2^40, within signed42. These deliberately
loose triangle bounds cover arbitrary discontinuous full-scale histories.
Bit-exact model is an independently expressed integer Horner implementation;
float model evaluates the four interpolation basis weights directly.

Five globally stalled pipeline slots; no-stall latency five clock edges,
initiation interval one. Output valid/data/clip are stable under backpressure.
Each of the three variable products uses explicit balanced logic shift/add;
no DSP inference is required. This trades LUTs and combinational delay for DSPs;
synthesis resources are measured, timing remains unqualified until P&R.

Configuration valid/ready is atomic and waits until all five pipeline slots are
empty. Asserting cfg_valid blocks new samples while old outputs drain. cfg_done
pulses for each accepted request; illegal D>31 or U>4096 returns cfg_error without
changing configuration/history. Legal clear=0 retains history, clear=1 invalidates
history. New settings apply to the first subsequently accepted sample. Reset is
synchronous active-low, aborts pipeline, clears history validity and selects D=0,
mu=0. Delay changes can intentionally jump output phase; continuity is only
claimed for smoothly varying fractional delay with fixed D (and equivalent
endpoint configurations), never arbitrary delay jumps.

No ASRC claim: input/output count is 1:1. Rate estimation, asynchronous clocks,
elastic rate-control buffer and sample insertion/removal are not implemented.
