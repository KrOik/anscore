# Per-bin spectral kurtosis

`spectral_kurtosis` reduces BINS ordered power samples in each of FRAMES spectra
into one statistic per bin. It retains exact first and second power sums and
reports the finite unaveraged spectral-kurtosis estimator with one final RNE
quantization. `iq_spectral_kurtosis64` actually composes the unchanged
`mag_squared` with this core for already transformed signed16 complex bins.

Status is **RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED**. The complete
source is prospective until independent root review and the exact seal gate.
No model, preparation child, HDL child, synthesis, PnR, STA, board or PPA has run.
Later qualification, if authorized, must supplement the frozen source bytes.

## Definition and statistical boundary

For a fixed bin, M=FRAMES observations P[j] are nonnegative unsigned powers:

```text
S1 = sum(P[j])
S2 = sum(P[j]*P[j])
numerator   = (M+1)*(M*S2-S1*S1)
denominator = (M-1)*S1*S1
SK = numerator/denominator                     if S1>0
sk_q = RNE(SK * 2^FRAC_W)
outside = (sk_q < lower) or (sk_q > upper)       inclusive accepted interval
```

Raw integer numerator and denominator are **not reduced**. `m_inexact` means
the scaled exact division had nonzero remainder, even when RNE returns zero.
There is no rounded intermediate mean, sample-variance rounding, clipping or
saturation. For legal nonzero observations, `0<=SK<=M+1`: constant positive
power gives zero; a single nonzero observation gives M+1. A common positive
scale across all observations of that bin cancels from the exact ratio. A
frame-dependent scale changes the statistic.

This is the N=1, d=1 normalization for **unaveraged** periodogram powers. Its
noise reference near unity assumes independent identically distributed
exponential powers, as obtained from suitable circular complex Gaussian noise
bins with fixed mean/processing. The core does not validate those assumptions,
FFT windowing, overlap dependence, stationarity, quantization adequacy or
calibration. Preaveraged powers require a different normalization. Real FFT
DC/Nyquist bins need separate statistical treatment. Bin order and frequency
coordinates belong to the caller; no FFT is instantiated here.

Caller-supplied bounds compare the **quantized** statistic, so classification
near a bound includes final quantization. Bounds carry no built-in confidence,
false-alarm probability, RFI diagnosis or certification. The output is a useful
finite spectral-shape/time-variability screening statistic under a caller-owned
model. Zero total power makes the ratio undefined, not a clean-noise decision.

## Parameters and ports

| Parameter | Default | Supported |
|---|---:|---:|
| BINS |64|1..256|
| FRAMES |16|2..64|
| POWER_W |24|1..32|
| FRAC_W |12|0..16|
| TAG_W |8|1..32|

Lengths are static configuration. A different ordered FFT length or averaging
depth uses another elaboration; commands change bounds and opaque tag only.
Let A=ceil(log2(FRAMES)), C=ceil(log2(FRAMES+2)):

| Field | Width | Units |
|---|---:|---|
| s_power |POWER_W|unsigned power code|
| m_sum |POWER_W+A|exact S1, power code|
| m_sum2 |2*POWER_W+A|exact S2, power code squared|
| m_numerator, m_denominator |2*(POWER_W+A)+C|exact integers, power code squared|
| c_lower, c_upper, m_sk_q |FRAC_W+C|unsigned Q(FRAC_W)|
| m_bin |max(1,ceil(log2(BINS)))|ordinal bin|

All transfers use a single rising-edge clock and ordinary `valid && ready`;
there is no CE or CDC. `rst` is active high; hold it across a rising edge. It
gates external ready/valid low, cancels partial collection, arithmetic and held
responses, and resets helpers. The unchanged serial multiplier has asynchronous
active-low reset driven from `!rst`; reset release is a same-clock integration
responsibility, not a CDC synchronizer. RAM data is not reset: every command's
first frame overwrites each bin before any subsequent-frame accumulation read.

Hold valid and all associated fields stable until accepted, unless reset
cancels the offer. One command owns the core from `c_valid && c_ready` through
retirement of its final result. No future command is admitted while collecting,
calculating or holding a result, including the final-result retirement edge.
The next command may handshake on a later edge after ownership returns idle.

Input order is frame0 bins0..BINS-1, frame1 bins0..BINS-1, through FRAMES-1.
`s_last` must assert exactly at every frame's last bin. It is not the batch-end
flag. A bad accepted LAST aborts immediately and consumes no following beat.
A source that stops early leaves the batch pending until reset; there is no
timeout, automatic resynchronization or implicit frame split. Restart the input
at a new batch after a fatal marker. Bounds with lower>upper accept no samples.

Results appear only after error-free collection completes. Normal results are
in bin order; `m_last` marks the final bin. All fields remain stable under output
backpressure. A zero-energy bin still occupies its ordinal result position.

| m_status | Meaning | Output |
|---:|---|---|
|0|OK|exact raw fields, RNE Q, inexact and bound flag|
|1|BAD_BOUNDS|one terminal zero-statistics marker at bin0|
|2|BAD_LAST|one terminal zero-statistics marker at expected input bin|
|3|ZERO_ENERGY|undefined ratio; all statistics/flags zero; continue bins|
|4|ARITH|terminal zero-statistics marker at current result bin|

ARITH checks negative dispersion, zero derived denominator and divider/result
flags; these cannot occur for legal data and correct helpers. A late internal
fault may follow earlier retired results. The finite plan checks legal
arithmetic, bounds and LAST errors; it does not inject internal helper faults.
Consumers needing transaction-wide success must retain rows until a normal
final result and discard the transaction on a fatal marker.

## Architecture and service

The implementation uses one packed synchronous-read/write RAM and one existing
serial square operator, shared between every input P squared and each final
S1 squared. One existing restoring integer divider serves every bin. FRAMES,
FRAMES+1 and FRAMES-1 are bounded compile-time coefficient multiplications;
the code does not create a multiplier/divider bank per bin. Acquisition and
reporting do not overlap. `ARCHITECTURE.md` derives widths and budgets.

For S=POWER_W+A and H=ceil(2*S/8), acquisition has II=S+H+4 clocks with ready
peers. A conservative always-ready batch bound from command acceptance is:

```text
BINS*FRAMES*(S+H+4) + BINS*(S+H+DIV_W+12) + 4
DIV_W = 2*S+C+FRAC_W
```

It is 47,620 clocks at default and 892,676 at supported maxima. Source gaps and
output stalls add unbounded wait; this is no clock-rate or physical-throughput
claim. Logical RAM payload is BINS*(3*POWER_W+2*A), default5,120 and maximum
27,648 bits. Implementation risk is MEDIUM, especially RAM inference, wide
coefficient/add paths and iterative divider mapping. No resource/Fmax/power
measurement is supplied.

## Actual power composition and finite plan

`example/iq_spectral_kurtosis64.sv` accepts `{imaginary,real}` signed16 FFT-bin
codes and LAST. It instantiates `mag_squared` at reset shift0, yielding exact
unsigned32 `real²+imag²`, including both lanes=-32768. There is one outstanding
complex beat and a held LAST bit, so the global-stall power pipeline cannot
detach framing metadata. The adapter limits input to BINS*FRAMES and stops on a
malformed LAST; no speculative beat crosses fatal retirement. It resets the
power helper while idle. Input must honor ready; no free-running ADC or FFT
drop-free claim is made. It supplies no FFT, window or capture logic.

The frozen prospective plan has four isolated archived preparations before
eleven HDL children: three syntax checks and four compile/simulation pairs.
Profiles cover tiny1-bin/2-frame/1-bit/F0/tag1, non-power-of-two7-bin/3-frame
with exact half/even and half/odd RNE cases, actual256-bin/64-frame/32-bit/F16/
tag32 maximum simulation, and the actual complex-power composition at4 bins/
5 frames. Tests compare literal independent whole-column integer/Fraction
expectations, exact raw fields, all flags, tags and errors. They hold future
commands until real handshake and check their separate held BAD_BOUNDS marker.
Reset probes cover collection, square, RAM boundary, S1 square, division,
held result, held invalid command, and the example's in-flight power beat.

This is finite verification, not exhaustive input/state proof. No inherited
runner/checker/model, regression, synthesis, PnR, STA, board or PPA is invoked.
Only root may authorize the exact reviewed SOURCE_SEAL for the sole runner call.
