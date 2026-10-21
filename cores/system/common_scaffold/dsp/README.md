# Functional DSP development

This directory contains functional cores, separate from the generated legacy
`signal_video` rejection-only ABI. Those legacy names still reject commands.

`cip_dsp_fir`: parameterized signed FIR with runtime coefficient loading,
one shared serial multiplier, arithmetic right shift (round toward minus
infinity), and signed output saturation. Defaults: 16-bit data and coefficients,
16 taps, Q15 coefficients. An accepted sample requires TAPS enabled MAC cycles;
the next sample can be accepted on output consumption. Output is stable under
backpressure and CE pause. All transfers require CE. Last marks the final
computed sample and clears history, without emitting convolution tail samples.
Reset clears coefficients/history and cancels pending work. Coefficient writes
are accepted only when idle and without a pending output; out-of-range addresses
are ignored. Coefficient writes take priority over input samples. Reload a whole
bank before resuming samples if atomic coefficient changes are required.

Supported parameters: TAPS >= 1, DATA_W/COEFF_W >= 2,
ACC_W >= DATA_W+COEFF_W+ceil(log2(TAPS)), 0 <= SHIFT < ACC_W.
No synthesis resource or board validation result is claimed yet.

`cip_dsp_cic_decimator`: parameterized RATE >= 1 and STAGES >= 1, differential
delay M=1. Signed modular ACC_W-bit integrators and combs; no saturation or
normalization. Default width includes STAGES*ceil(log2(RATE)) growth bits above
DATA_W. ACC_W must be at least DATA_W. Each accepted sample updates integrators
using the new preceding-stage value. Each RATE samples yields one output.
Last emits a terminal output even for a partial decimation group, then clears
all histories; it does not pad the group with zeros. This is a defined partial
packet result, not a full-rate normalized sample. Output storage backpressures
the input when full. Reset cancels pending output and clears all state.

Run `python cores/system/common_scaffold/dsp/run_tests.py` from the repository
root. The runner retains small evidence logs and removes simulation images and
generated reference fixtures via TemporaryDirectory, including on failure.
CIC tests use a separate Python integer model with deterministic random signed
samples, source gaps, CE pauses, output stalls, partial packets, and resets;
RATE/STAGES cases are 1/1, 2/2, 8/3 and 5/4.

`cip_dsp_iir_biquad`: signed direct-form-I biquad with serial five-product MAC.
Coefficients at addresses 0..4 are b0,b1,b2,a1,a2, with implicit a0=1:
`y = sat((b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2) >>> SHIFT)`.
Feedback stores the saturated DATA_W-bit output. Defaults use Q14 coefficients.
Arithmetic right shift rounds toward minus infinity. Five enabled MAC cycles
follow each sample acceptance. Coefficient load, CE, backpressure, last/reset
semantics match FIR; last clears feedback and input delay history after its
output is computed. Invalid coefficient addresses are ignored. Supported widths
are DATA_W/COEFF_W >= 2, ACC_W >= DATA_W+COEFF_W+3, 0 <= SHIFT < ACC_W.
Coefficient stability is the caller's responsibility; loading an unstable
filter is allowed and can produce saturation/limit cycles. Tests compare 1200
outputs against an independent Python model over five coefficient sets.

`cip_dsp_cordic`: iterative 16-step rotation and vectoring, 16-bit signed x/y
inputs, 20-bit signed x/y outputs to preserve gain without saturation. Angles
are signed 18-bit radians*16384. Rotation accepts the full 18-bit angle range,
normalizes using quantized pi=51472, folds quadrants, and returns rotated x/y
and residual z. Vectoring returns gain*norm in x, near-zero y, and normalized
`s_z + atan2(s_y,s_x)` in z. The zero vector explicitly returns x=y=0 and
normalized s_z. Output gain is the 16-step CORDIC gain, approximately 1.64676;
this module does not compensate gain. Iterative shifts round toward minus
infinity; the atan table is rounded to nearest radians*16384. The final table
entry is zero due to finite angle resolution. Vector phase is quantized to
[-51472,51472]. Coordinate integer units are preserved, permitting any external
binary point assignment. Sixteen enabled iteration edges follow acceptance;
output then holds until CE and m_ready. Reset cancels pending work. Last is
metadata and is returned unchanged. No multipliers appear in this RTL.

CORDIC tests compare 1154 outputs bit-for-bit with a Python integer model and
also check floating-point sin/cos, norm, and atan2 bounds. Tested coordinate
error is <40 integer units; phase error is <0.006 radians for vector norms
above 2000. Those are regression bounds, not an exhaustive accuracy proof.

`cip_dsp_resampler`: signed rational FIR resampling, with elaboration-time UP,
DOWN and TAPS and runtime signed coefficient loading. Computes exactly the
causal sequence obtained by inserting UP-1 zeros between input samples,
convolving with coefficients, then retaining indices 0,DOWN,2*DOWN,... .
The RTL directly evaluates the applicable polyphase taps with one serial MAC.
No implicit coefficient gain adjustment is applied. Default coefficients are
Q15; coefficient design and anti-alias/anti-image cutoff selection belong to
the caller. Use arithmetic right shift and signed saturation as in FIR.

Last terminates a nonempty packet. Full convolution tail is flushed with zero
history updates; the final decimated result carries m_last. For L input samples,
output length is `floor(((L-1)*UP+TAPS-1)/DOWN)+1`. Next packet starts with zero
history and phase zero. Input pauses while each output is computed or stalled.
Coefficients can be loaded only between packets, preventing mid-packet bank
changes. There is no fixed input/output throughput ratio under backpressure.
Reset clears coefficients/history and aborts work. All transfers require CE.
Supported parameter domain: 1 <= UP,DOWN,TAPS <= 65535; TAPS >= DOWN;
DATA_W/COEFF_W >= 2; ACC_W >= DATA_W+COEFF_W+ceil(log2(TAPS));
0 <= SHIFT < ACC_W. TAPS >= DOWN ensures at least one not-yet-emitted output
after the last input, permitting streaming last metadata without lookahead.
This core deliberately does not silently alter filters that violate that domain.

Seven resampler parameter sets have 1950 output comparisons against explicit
zero-insertion/convolution/decimation, including non-coprime factors and UP
greater than TAPS. Generated fixtures and simulation binaries are temporary.

`cip_dsp_fft`: radix-2 DIT complex FFT/IFFT, elaboration-time LOG_N=1..8
(N=2..256). Natural-order input and natural-order output; input storage is
bit-reversed internally. Synchronous single-port RAM is not reset and is fully
overwritten by each complete input frame. Four real twiddle products use one
serial multiplier. A butterfly takes nine enabled edges (two RAM reads plus
capture, four products, two writes). Output uses read/capture/hold states and
honors CE/backpressure; no overlapping input/output frames are accepted.

Forward follows `sum(x[n]*exp(-j*2*pi*n*k/N))` with no scaling. Inverse uses
the positive exponent and divides by N at output. Twiddles are signed 17-bit
Q15, including exact +1. Real/imaginary twiddle recombinations are arithmetically
shifted right by 15, rounding toward minus infinity. Intermediate coefficients
and output use OUT_W=DATA_W+LOG_N+2 guard width by default, with no saturation.
Supported widths: 2 <= DATA_W <= 16, OUT_W >= DATA_W+LOG_N+2. Input coordinate
integer units are retained; assign any external fractional binary point.
No floating-point arithmetic appears in the RTL.

The first accepted sample captures s_inverse; subsequent samples cannot change
the frame mode. Exactly N samples are required, with s_last only on sample N.
Early last or missing last at N emits one zero-valued `m_error=1,m_last=1`
response, holds it under backpressure, then starts a new frame at the next
accepted sample. It does not scan/drain an overlong source packet for a later
last marker. Valid transforms emit N outputs with m_error=0 and m_last on the
final bin. A truncated frame with neither further samples nor last waits for
input until reset; no timeout is implicit. Reset aborts load/compute/output.

Tests cover every supported power-of-two N: 112 normal FFT/IFFT frames, 7140
normal output bins, 46 malformed-frame responses and 510 reset-recovery bins.
Integer reference comparisons are bit-exact; a separate direct floating-point
DFT checks sign, ordering and normalization. Tested worst component error is
53.02 integer units across the forward/inverse fixtures, not an exhaustive
accuracy bound. ROM regeneration is checked read-only by
`python cores/system/common_scaffold/dsp/generate_fft_twiddle.py --check`.
