# Numeric, architecture and ownership review

The final outputs need a centered phase slope and residual, rather than all
sample phases. Storing N phases then fitting is simple but needs RAM and another
pass; using the small existing stream_linear_fit loses legal phase precision;
a parallel multiplier tree is excessive for the accepted sparse transaction
budget. Selected: sufficient statistics with one phase in flight, one old
serial magnitude multiplier and one old final divider. The oracle instead uses
pairwise differences and arbitrary-precision Fraction, independently of those
statistics and the helper algorithms.

Let L=ceil(log2(MAX_BINS)), Q=ceil(log2(MAX_BINS+1)), A=P+L.
The first phase lies [-2^(P-1),2^(P-1)-1]. Every subsequent delta lies in that
same signed P range. At j accepted points the most negative unfolded value is
-j*2^(P-1); therefore signed A covers every prefix, including the legal
P24/N256 value -2^31. No extra point is ever unwrapped after declared N.

| Node | Width | Representation / bound |
| --- | --- | --- |
| phi | A | signed |
| Sy | A+L | signed, prefix sum includes -2^(A+L-1) bound |
| Sx | 2L | unsigned, N(N-1)/2 <2^(2L) |
| Sxx | 3L | unsigned, sum(k²) <2^(3L) |
| Sxy | A+2L+1 | signed, sum absolute products <2^(A+2L) |
| Syy | 2A+L | unsigned, sum squares <2^(2A+L) |
| B | Sxy_W+Q+1 | signed difference of two signed full products |
| C | Syy_W+Q+1 | unsigned nonnegative full product difference |
| D | Sxx_W+Q+1 | unsigned positive full product difference |
| E | max(C_W+D_W,2B_W)+1 | unsigned full CD minus full B² |

All prefixes fit; unsigned count/index is zero-extended before signed use.
The shared unsigned magnitude width M=max(B_W,C_W,D_W)+1 fits all operands,
including minimum-negative magnitudes. Each helper product is2M bits; neither
CD nor B² is truncated before the E subtraction. Cauchy gives CD>=B²;
pairwise identities give D>0 for N>=2 and E=0 for N2. Checks reject any violated
nonnegativity or zero denominator, resetting helpers before an error result.
For a finite range, sum(k²) is updated only after a non-final sample using the
old k in k²+2k+1; the unused k=N term is never formed or accumulated.

P16/MAX64: A22, Sy28, Sx12, Sxx18, Sxy35, Syy50, B43, C58, D26,
E87, multiplier59x59, divider75. P24/MAX256: A32, Sy40, Sxy49,
Syy72, B59, C82, D34, E119, multiplier83x83, divider91 (MAX_FFT16).
The divider numerator abs(B)<<fft_log2+16 is widened before shifting. Its
denominator D<<P fits the same width. Compare rem with den-rem for RNE, avoiding
an overflowing doubled remainder; equality increments only odd quotient.

The OLS slope equals a convex combination of nearest phase steps delta[j],
with weights 6*j*(N-j)/(N*(N²-1)), j1..N-1. Thus the slope is between negative
half-turn and positive half-turn minus one code. Delay magnitude is at most
NFFT/2 samples. At FFT_LOG2=16, the positive endpoint is32768 samples, i.e.
Q16 +2^31; signed32 cannot represent it. DELAY_W=MAX_FFT_LOG2+17 covers it.
The result restores the opposite sign to B only after exact final RNE.

Per sample, UNWRAP consumes the sole old elastic token, updates Sy/Sx/Sxx,
then SQR and XY request/wait pairs update Syy/Sxy. Eight final requests are
N*Sxy, Sx*Sy, N*Sxx, Sx², N*Syy, Sy², C*D, |B|², in that order. Every sign
and operand remains stable through its helper result consumption. All products
are exact. The host's sum and the reused multiplier's iterative carry chains
occupy distinct cycles. No blanket timing exception is assumed.

The serial multiplier retains four padded2M-bit vectors, an M-bit multiplier,
a2M-bit held product and small control: it is not a small single accumulator.
The divider retains five V-bit payload vectors plus control; unwrap retains
phase history and one result. Default combined logical register state is below
3200bits; no RAM is added by this core. The I/Q adapter adds CORDIC x/y/z and
one pending bit. These are paper logical bounds, not synthesized utilization.
MUX width, variable final shift and wide add/sub/compare paths remain timing
risks; all physical PPA is unmeasured. The selected long service time is explicit
and bounded only when sources and sinks supply bounded stalls.

Public input legality precedes unwrap/statistic changes. FEED only releases
one accepted phase to UNWRAP; no next phase can occupy the old unwrap slot.
Errors enter FENCE. During it unwrap and divider see synchronous high reset,
and the old CE multiplier sees asynchronous low reset with CE tied1. The fence
edge clears all mathematical outputs before HOLD. Metadata/received retain
the diagnostic request. Reset cancels everything immediately at public valid/
ready masking and at the active clock edge. No old result is reused or retried.

In the actual I/Q composition, source acceptance sets angle_pending; only the
matching angle/core handshake clears it. New I/Q cannot be accepted on that
same edge. At early zero/LAST error there is no next angle transaction that
could survive the fit fence. External reset also clears the actual atan.
