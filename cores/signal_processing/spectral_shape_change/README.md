# Adjacent normalized power-spectrum shape change

`spectral_shape_change` measures the exact total-variation distance between
adjacent valid ordered power spectra. It retains the last retired valid frame,
captures a new frame and performs all normalization and arithmetic in RTL.
`example/iq_spectral_shape_change.sv` actually composes the unchanged
`mag_squared` with the instrument for signed16 complex FFT bins.

Source status: **RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
The frozen finite plan is prospective. No preparation, model, AST, syntax, HDL,
synthesis, PnR, STA, board or PPA execution has occurred during authoring.
Any later qualification must be additive and identify the actual receipts.
Baseline: `3a58c99bda6f6f62a34d1c20247d3b42d8d89006`.

## Exact measurement

Let current powers be P[k], reference powers Q[k], A=sum(P), B=sum(Q).
For compatible frames with A>0 and B>0:

```text
U = sum(max(P[k]*B - Q[k]*A, 0))
D = A*B
TV = U/D = 0.5*sum(abs(P[k]/A - Q[k]/B))
change_q16 = round_to_nearest_ties_even(65536*U/D)
```

The output U and D are exact, unreduced integers. There is one final rounding,
and `m_inexact` identifies a nonzero scaled-division remainder, including a
positive distance that rounds to zero or a distance below one that rounds to
65536. Unity is65536. Legal data gives0<=U<=D and0<=change_q16<=65536;
no clipping, tolerance, saturation, logarithm, float or intermediate rounded
probability is used. Every unsigned32 power pattern is legal.

A positive common scale within either frame cancels independently. Upstream
quantization, clipping, bin remapping and unequal bin widths can change the
interpretation. All frames must have the same frequency grid and preprocessing;
assert `c_restart` after changes the core cannot observe. The input is already
transformed power or common-scale equal-width PSD. This module does not run an
FFT, generate a window, average spectra, identify a physical interference source,
measure a calibrated false-alarm probability or convert a bin to Hz.

The result describes spectral shape redistribution. Uniform gain changes have
distance zero. Moving all normalized power between distinct bins gives distance
one regardless of separation. Output totals retain the caller's power units.
Temporal resolution is the caller's frame/hop schedule; accepted-input pauses
stretch processing time. This instrument does not supply a physical sample rate.

## Parameters and interface

| Parameter | Default | Supported |
|---|---:|---:|
| MAX_BINS |256|1..256, including nonpowers of two|
| TAG_W |8|1..32|

All transfers use one rising-edge clock, ordinary `valid && ready`, with
synchronous active-high `rst`. Reset gates all public ready/valid low and cancels
the transaction and reference validity. There is no CE, CDC or automatic timeout.
Payload RAM is unreset; a candidate is completely written before replay.

| Ports | Meaning |
|---|---|
| c_valid/c_ready | Accept one command only while idle, after helper reset bridge |
| c_bins[31:0] | Full-width length, validated before narrowing |
| c_restart | Treat this legal frame as a new reference, returning WARMUP |
| c_tag | Captured opaque tag; later command mutations have no effect |
| s_valid/s_ready | One unsigned32 power, natural paired bin order |
| s_last | One exactly on the command's final bin |
| s_invalid | Marks the accepted bin as unusable; takes precedence over LAST |
| m_valid/m_ready | One summary per completed command; full bundle held stable |
| m_status[3:0] | Status below |
| m_bins[31:0], m_received | Captured length and accepted-bin count |
| m_total, m_reference_total | Exact current and compatible reference totals |
| m_numerator, m_denominator | U and D for a valid metric; otherwise zero |
| m_change_q16[16:0] | Final rounded value; zero for an invalid metric |
| m_metric_valid, m_inexact | Numeric validity and scaled nonzero remainder |
| m_tag, busy | Captured tag and outstanding command state |

Let S=32+ceil(log2(MAX_BINS)), taking the increment as0 at MAX_BINS1.
Totals are S bits, U/D are2S bits, count has clog2(MAX_BINS+1) bits, and
the divider has2S+16 bits. The maximum profile uses40/80/96 bits respectively.
Widths and complete product bounds are in ARCHITECTURE.md.

## Status and reference lifecycle

| Code | Status | Reference effect after summary retirement |
|---:|---|---|
|0|OK|Commit the complete current frame and total|
|1|WARMUP|Commit; no compatible prior frame existed, restart was set, or length changed|
|2|BOTH_ZERO|Commit the legitimate zero frame; metric undefined|
|3|REFERENCE_ZERO|Commit current frame; metric undefined|
|4|CURRENT_ZERO|Commit the legitimate zero frame; metric undefined|
|5|BAD_LENGTH|Consume no input; preserve old reference and validity|
|6|EARLY_LAST|Invalidate history and discard candidate|
|7|MISSING_LAST|Invalidate history and discard candidate|
|8|INVALID_INPUT|Invalidate history and discard candidate|
|9|ARITH|Flush helpers, invalidate history and discard candidate|

Status priority is BAD_LENGTH before loading, then accepted INVALID_INPUT,
EARLY_LAST, MISSING_LAST and arithmetic invariants. After a complete legal frame,
WARMUP takes precedence over zero-total classification. Undefined metrics have
zero U/D/q/inexact but retain both meaningful totals when a compatible reference
exists. Fatal frame errors zero both transmitted totals and numeric fields while
preserving received count, full command length and tag.

One command owns capture, calculation and summary through actual retirement.
There is no command/input fallthrough on that retirement edge. The old bank,
stored reference total and length remain unchanged while a result is held.
Successful or legitimate zero summaries switch the bank only at `m_valid &&
m_ready`. A malformed accepted frame clears history validity as soon as detected;
it leaves old reference payload/total/length untouched. The next legal frame is
WARMUP, preventing an implicit comparison across a damaged-frame gap.
Reset also clears history validity, including when cancelling a held result.

The sequence zero, zero, positive, zero, positive therefore reports WARMUP,
BOTH_ZERO, REFERENCE_ZERO, CURRENT_ZERO, REFERENCE_ZERO; no zero frame is skipped.
Bad commands consume no frame and permit correction without destroying history.
A changed length begins a new compatible sequence. The caller owns other grid
or processing changes and declares them with restart.

## Actual I/Q composition

The example accepts `s_iq[15:0]` signed real and `[31:16]` signed imaginary.
It feeds unmodified `mag_squared` with fixed shift0, carries LAST/invalid through
its four-stage globally stalled pipeline, counts in-flight bins, and forwards
each paired power/sideband to the instrument. Signed minima are legal; power is
I²+Q², with no phase sensitivity. A LAST/invalid input closes further admission,
and command admission waits for the magnitude pipeline to drain. Output contract
and reference retirement policy are the same as the bare core.

## Architecture and service

Two unchanged synchronous single-port RAM instances retain reference and candidate
powers. First pass writes candidate and totals; second pass reads both banks at
the same address. One unchanged carry-save serial multiplier performs2N per-bin
products and the final total product. One unchanged restoring divider performs
the scaled ratio. No run-time multiplier/divider is instantiated per bin.

Power capture can accept an II=1 burst. Capture and replay are separate phases;
this is not the continuous frame service interval. With always-valid input,
always-ready output and no reset/fault, define Lm=S+ceil(2S/8)+1 and
Ld=2S+17. For a nonzero compatible frame, the source-derived schedule gives
first summary validity `N*(2*Lm+5)+Lm+Ld+3` clocks after command acceptance.
Earliest retirement is one edge later; the next command can transfer one more
edge later. At MAX_BINS256 this is107N+151, or27543 clocks for N256 and6999
for N64. WARMUP/zero first validity is N+1. The actual I/Q wrapper adds four
clocks to those complete-frame paths. These are prospective source schedules,
not measured execution or hardware-frequency claims; the conservative proposed
budget113N+168 also covers the I/Q path. External gaps/stalls add waiting.

Maximum payload storage is2*256*32=16384 bits (2048 bytes). RAM/BRAM mapping,
wide divider carry delay, LUT/FF/DSP use, Fmax, power and device fit are unmeasured.
Architecture risk is MEDIUM: serialization limits service rate and a96-bit
restoring subtraction remains a timing concern. See FINITE_PLAN.json for the
only proposed pre-hardware qualification scope.

## Finite execution gate

The complete prospective suite is four isolated preparation children and eleven
HDL children: three syntax checks plus compile/sim for minimum, nonpower7,
maximum256 and actual I/Q64 profiles. Each child has20s, a tree termination helper
has5s, and the target gets one sole2s exit observation after termination.
Any failure retains all evidence and stops later children; there is no retry.
No project model is imported by the runner. The model is executed directly from
the archived frozen source once per profile. Simulation image SHA/prechecked
fields are fsynced in an immutable `.initial.json` before Popen, then retained
alongside terminal JSON and original raw streams/images. Execution requires
separate exact root and independent peer review, source seal and unused guard.
