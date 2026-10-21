# DSP01 polyphase integer/rational resampler

Supported runtime L,M=1..8 (including unreduced ratios), L<=T<=128 coefficients.
Input/output signed16 Q1.15; coefficients signed18 Q3.15. The causal contract is
`y[m]=sum_n x[n]*h[m*M-n*L]`, rounded nearest-even then saturated once at output.
High-rate sample time starts t=0, output times t=m*M, input times n*L. Each phase
evaluates only coefficient indices t mod L, t mod L+L,... below T. No zero-insertion
buffer, dropped phase, shifted origin, or reordered outputs.

## Filter and numerical contract

Generator supplies Blackman-windowed sinc normalized sum h=L. Reference pass
edge0.1/max(L,M), cutoff0.3/max, stop begins0.5/max, all cycles/high-rate tick.
This deliberately specified narrow useful band is not the full original Nyquist
band. It supports anti-image/interpolation and anti-alias/decimation. Actual
passband ripple/stop attenuation after coefficient quantization are measured.
Shorter user filters and arbitrary runtime coefficients have no automatic spectral
guarantee. T>=L ensures every phase has at least one coefficient and streaming
outputs cannot already exceed the finite convolution support before flush arrives.

Each 18x16 signed product uses34 bits. At most128 terms, each magnitude<=2^32,
so magnitude<=2^39; signed41 accumulator is sufficient including negative extrema.
Only final /32768 rounding and signed16 saturation occur; output clip flag means
that result saturated. Intermediate wrap is prohibited. Negative half ties go to
the even integer. No deliberate numeric modulo arithmetic.

## Stream, configuration and flush

Single clk, synchronous low rst_n; data Stream s/m signed16 with output clip flag.
Atomic cfg contains L[3:0],M[3:0],tap_count[7:0], packed coefficients with h0 in low
18 bits. A legal accepted config clears history validity, phase, totals and errors;
illegal count/ratio rejects all fields, with cfg_done/cfg_error response. Config
waits for current MAC/output to finish, accepts in idle WAIT or completed DONE,
and has priority over new input. Clearing config discards prior unflushed tail.

Explicit flush_valid/flush_ready is accepted in WAIT with no pending output and
no config. Flush marks the current finite block end and feeds virtual zeros until
all t <=(N-1)*L+T-1 are emitted. Empty block flush emits nothing. Final flush_done
pulses and DONE blocks new input until fresh config/reset. Counters retain N real
accepted inputs and exact emitted outputs. Padding zeros do not increment input
count. Expected flushed count for N>0 is floor(((N-1)*L+T-1)/M)+1.

MAX_INPUTS static1..65535, default65535; source at capacity is backpressured and
sets sticky capacity_error, never silently wraps. Flush/config remain usable.
Reset aborts MAC/pending output/flush and clears validity; stale sample registers
are masked by history validity until overwritten. Coefficients default identity
L=M=T=1. No in-flight sample survives reset or a clear-state configuration.

## Resource and throughput configuration

One shared registered multiplier and one41-bit accumulator; coefficient and sample
history use small register arrays with validity count, not claimed as BRAM. For
phase p, K=ceil((T-p)/L) terms cost2K compute edges. First output transfer is
2K+1 cycles after the last input required by that output. Between no-stall output
transfers the interval is2K_next+max(1,input_gap), where input_gap is the number
of new real/padding samples required by the next phase advance. No II1 claim.

Long-term logical output/input ratio is L/M before finite-tail effects, but maximum
wall-clock throughput is bounded by serialized MAC work. Input can advance one
per clock only during a requested decimation gap; interpolation emits multiple
outputs while holding history. Global compute pauses if the single output slot
is occupied and downstream stalls. All valid/data/clip fields hold. Configuration
and flush must also hold valid/payload until accepted. Board/chain integration
needs this real rate contract and cannot assume both ports accept every cycle.
