# Spectral harmonic quality instrument

`spectral_harmonic_quality` finds the strongest FFT bin in a commanded search
range, derives separated windows for its fundamental and harmonics, and reports
exact fundamental, harmonic and remaining in-band power. It also reports three
nearest-even Q16 linear power ratios. The actual arithmetic is composed from
the unchanged canonical peak search, band monitor and iterative divider. The
new logic owns framing, spectrum RAM, window generation, classification and
the transaction protocol. `SOURCES.md` records semantic deduplication and the
read-only upstream reference.

Frozen status is **RTL_CANDIDATE + HW_UNVERIFIED**. The prospective finite plan
does not establish a PASS. Later results, if authorized, are recorded separately.
No synthesis, PnR, STA, board, PPA, inherited regression or combined IP suite is
requested. The recorded development baseline is
`2e7a6fb51f32e525c1026c28d1f2f45e36545ebc`.

## Power-domain definition

The input is one complete, natural-order unsigned32 power spectrum with
`N=2^L` bins indexed `0..N-1`. For a real-valued time-domain signal, only the
interior positive-frequency bins `I={1,...,N/2-1}` are measured. DC, Nyquist
and the negative-frequency half are excluded, even if they contain very large
values. The equal factor of two for interior bins of a real one-sided power
spectrum cancels in all reported ratios. A caller supplying a different power
representation owns its interpretation. Ready/valid gaps do not change bin
indices. The core does not perform an FFT, windowing, scaling calibration or
real-signal symmetry validation.

Let `k0` be the earliest bin with maximum nonzero power in the inclusive
commanded search interval. For runtime highest harmonic `H` and half-width `r`:

```text
W[h] = {h*k0-r,...,h*k0+r}                       h=1..H
component[h] = sum(P[k] for k in W[h])
F = component[1]
Hp = sum(component[2..H])
T = sum(P[k] for k in I)
R = sum(P[k] for k in I minus union(W[1..H])) = T-F-Hp
thd2_q16 = RNE(65536*Hp/F)
snr_q16 = RNE(65536*F/R)
sinad_q16 = RNE(65536*F/(Hp+R))
```

`thd2_q16` represents THD(F) **squared**, relative to fundamental power.
`snr_q16` and `sinad_q16` are linear power ratios for these exact masks.
The core computes no square root, amplitude THD, logarithm, percent, dB or
weighted audio metric. `R` includes both nonharmonic spurs and noise. Signal
leakage outside the fundamental window enters `Hp` or `R` according to its
bin; noise inside any harmonic window contributes to that component. The
search interval must identify the intended fundamental, which need not be the
largest bin of the entire spectrum. The core cannot distinguish a true
fundamental from a harmonic inside the search interval. This is a discrete,
finite-band measurement definition, not a complete analog instrument accuracy
claim. Harmonics beyond `H` remain in `R`; there is no alias folding or
out-of-band distortion estimate.

Static parameters support `MAX_LOG2N=4..12` (default8),
`MAX_HARMONICS=2..8` (default8), and `TAG_W=1..32` (default8). Full unsigned32
commands require `4<=L<=MAX_LOG2N`, `2<=H<=MAX_HARMONICS`, `0<=r<=2`, and

```text
2*r+1 <= search_low <= search_high
H*search_high+r < N/2
```

Validation precedes narrowing. These constraints prove that every selected
window lies strictly inside `I` and adjacent window centers differ by at least
`2*r+1`, so windows are pairwise disjoint. A command violating either condition
is rejected, rather than clipping or assigning overlapping bins arbitrarily.
No valid configuration exists for some small-N/r/H combinations.

`SUM_W=32+MAX_LOG2N-1`, at most43. Every exact sum is bounded by
`(N/2-1)*(2^32-1) < 2^SUM_W`. The divider receives explicit unsigned leading
zeros (`AW=BW=SUM_W+1`), retains all numerator bits with `FB=16`, and returns
`RATIO_W=SUM_W+17`, at most60. For any nonzero denominator the positive rounded
ratio fits its signed positive range; no legal result clips. Full integer
quotient/remainder RNE handles even and odd half-LSB ties. There is no floating
point or intermediate power truncation.

## Interface and ownership

All public transfers occur at rising `clk` with valid and ready high and `rst`
low. `rst` is synchronous active-high and immediately masks public ready/valid;
its rising-clock action cancels the owned command and held result without a
response. It clears control, not spectrum RAM. Peak, divider and magnitude
helpers use synchronous active-low reset with a registered local reset fence;
the band monitor uses synchronous active-high reset.
Error responses also reset the helpers before the next command is accepted.
There is no CE and no same-edge command fallthrough on result retirement.

| Channel | Fields | Rule |
| --- | --- | --- |
| Command | `c_valid/c_ready`, u32 `c_log2n,c_harmonics,c_radius,c_search_low,c_search_high`, tag | Captured only idle; hold until accepted. Changes after acceptance do not affect the record. |
| Spectrum | `s_valid/s_ready`, u32 `s_power`, `s_last,s_invalid` | Exactly N accepted bins in natural order; LAST only on bin N-1. Invalid is sticky. |
| Result | `m_valid/m_ready`, all fields below | One held record per command; every field remains stable under backpressure. |

Results retain all original u32 command fields and tag. `m_received` is the
actual accepted count (13 bits). `m_fund_bin,m_peak_power` identify the selected
search peak. `m_total,m_fund,m_harm,m_residual` are exact `SUM_W` sums.
`m_components[h*SUM_W+:SUM_W]` is harmonic order `h+1`, including the fundamental
at slot0; unused slots are zero. The three Q16 fields have `RATIO_W` bits.
`m_ratio_valid[0]` qualifies THD-squared, bit1 SNR power and bit2 SINAD power.
A zero denominator gives valid0 and numerical zero for that field. In
particular, a pure fundamental returns valid001, not a finite SNR or SINAD.
Successful zero harmonic power still gives a valid zero THD-squared.

| Status | Meaning |
| --- | --- |
| 0 OK | Complete valid nonzero-fundamental measurement. |
| 1 BAD_CONFIG | Full-width validation failed; no bins consumed. |
| 2 EARLY_LAST | LAST before bin N-1; ends immediately at that accepted bin. |
| 3 MISSING_LAST | Bin N-1 had LAST0; stops after N bins. |
| 4 SAMPLE_INVALID | One or more accepted bins flagged invalid. |
| 5 NO_FUNDAMENTAL | All search-interval powers were zero. |
| 6 INTERNAL_FAULT | Unexpected helper configuration/band protocol, partition or divider flag. |

Priority is config, early LAST, missing LAST, invalid, no fundamental, helper
fault. Every error zeros all numerical results and ratio-valid bits, while
retaining original command fields, tag and actual received count. Errors do
not leak partial sums. No command or sample is accepted while computing or
holding a result. Fewer than N bins without LAST hold the transaction until
more samples or reset; there is no physical-time timeout.

## Architecture and cycle service

First pass accepts one power bin per clock, saves the positive half including
a forced-zero DC slot in a single synchronous RAM, accumulates total interior
power, and streams a masked spectrum through unchanged `peak_search`.
After the peak is known, a short controller generates the windows. The RAM
is replayed at one bin per clock to unchanged `spectral_band_monitor`, whose
unused bands point to the zero DC slot. Exact band responses become the
component powers. The same unchanged `fp_div_iter` computes the three ratios
serially; zero denominators skip the operation. The band monitor's common
weighted product is present but its moment output is unused. The reused monitor
still describes a32-by-INDEX_W weighted-moment multiplication per replayed bin;
no synthesis evidence establishes its removal. Configuration also describes
a32-by-4 variable harmonic-factor multiplication, and the I/Q example retains
two16-by-16 squares in mag_squared. No replicated H-order multiplier bank or
H-dependent spectrum RAM is introduced.

Logical RAM is512B at default `MAX_LOG2N=8`, at most8KiB at12. There is one
write phase and one read phase, with no reset, read/write collision or external
memory dependency. Qualitative resource risk is MEDIUM: RAM inference, band
accumulator routing, its unused moment logic and the wide iterative divider
require later implementation evidence. No LUT/DSP count, Fmax or board fit is
measured here.

With continuously valid bins and no result stall, the conservative bound from
accepted command to earliest result transfer is `N+N/2+320` clocks, at most6464.
It includes peak configuration, N collection cycles, peak response, at most8
window-generation cycles, band configuration, one synchronous read pipeline,
N/2 replay bins, band flush and at most16 band-response clocks, residual
classification, and three divider input/result sequences of at most62 clocks.
It is a cycle budget to be checked by the finite test, not a measured hardware
sample rate. Source gaps and response stalls add time. The next frame waits
for result retirement and idle/helper readiness; continuous back-to-back FFT
frames require an upstream buffer or a producer that honors ready.

## Actual I/Q composition

`example/iq_spectral_harmonic_quality.sv` instantiates the unchanged canonical
`mag_squared` at shift0 and the instrument. It accepts signed16 complex FFT
bins packed `{Q[15:0],I[15:0]}`, not time-domain samples. The old four-stage
global-stall pipeline has a matching marker/invalid pipeline. The wrapper
stops input at the accepted LAST or Nth bin, so an early LAST cannot leave
younger bins in flight. Configuration ownership, error output and reset apply
to the complete chain. Power is exactly `I*I+Q*Q`, at most2^31. No FFT or
quantization to signed16 is hidden inside the example. Its conservative
no-stall service bound is `N+N/2+324` clocks.

## Frozen finite verification plan

Both `files.f` lists resolve from this package directory and include the full
offline source closure, with no nested source list, generated ROM, vendor
primitive or network requirement. Only after independent root review and an
explicit gate, the intended single command is:

```text
python -B run_tests.py --execute-approved-plan
```

Four isolated integer-oracle preparations precede two syntax children and four
compile/simulation pairs. Profiles cover Lmax4/Hmax2/TAG1, default8/8/TAG8,
maximum12/8/TAG32 and the real I/Q chain8/8/TAG8. The frozen model computes
whole-record integer sets and sums with divmod RNE, independently of the helper
recurrences. It exercises masks, ties, full power/capacity, malformed command
high bits, LAST/invalid precedence, all12 active-state reset cancellations,
recovery after each cancellation/error, held output and one defensive divider
flag fault/recovery. Every child has a20s deadline, tree kill5s and pipe drain2s;
any failure stops later launches and existing attempt evidence prevents retry.
The runner archives source bytes before preparation and all vectors before
HDL, hashes tools/argv/raw logs/images, and archives `.gitattributes` as `.txt`
data. Completed children are persisted before parsing preparation summaries or
collecting image metadata; each simulation verifies the previously recorded
compile-image hash. The TB offers the next actual vector's command during a
held old response and keeps valid/configuration stable until acceptance, with
both command and sample held-source assertions. It does not clean, stage or
commit anything.
