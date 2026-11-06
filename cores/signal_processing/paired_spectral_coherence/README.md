# Paired spectral coherence

`paired_spectral_coherence` accumulates exact per-bin power and complex cross-spectrum over a finite batch of paired complex spectra. It reports magnitude-squared coherence as unsigned Q16, together with the unrounded sums. This adds a measurement of the relation between two spectral streams; two independently averaged power spectra do not retain the phase needed to reconstruct it.

Status: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**. The bounded checks below passed for the archived source bytes. Synthesis, placement/routing, STA and board testing were not run. No clock-frequency or physical-resource qualification is implied.

## Calculation and interpretation

For each bin, over the commanded `K=c_averages` segments:

```text
Sxx = sum(Xre² + Xim²)
Syy = sum(Yre² + Yim²)
R   = sum(Xre*Yre + Xim*Yim)
I   = sum(Xre*Yim - Xim*Yre)        cross = Conj(X)*Y
q16 = RNE(65536 * (R² + I²) / (Sxx*Syy))
```

`RNE` means round to nearest with exact ties to even. `65536` represents unity. All sums, squares and the ratio numerator/denominator are exact integers; there is one final Q16 rounding and no rounded intermediate means. For legal data the Cauchy inequality gives `0 <= q16 <= 65536`; the core does not use legal-data clipping or saturation. `Y=jX` gives positive imaginary cross-spectrum and unity coherence.

The factors of `1/K` in averaged spectra cancel. A fixed spectral normalization or fixed channel scale across the batch cancels in the coherence ratio; varying a channel's scale between segments changes the estimate. Raw sums retain input-code-squared units and the declared cross direction. Frequency-bin coordinates, one-/two-sided ordering, segment alignment, matched windowing and any FFT scaling policy belong to the upstream design. The output index is a bin number, with no built-in conversion to hertz.

**K=1 is diagnostic:** every pair with nonzero energies has coherence one by definition. It does not establish a statistical relation between the signals. Increasing K alone supplies no confidence interval or independence guarantee; overlapping/windowed segments may be statistically dependent. The core provides equal-weight finite sums, without detrending, windowing, FFT, calibration or statistical significance tests.

## Parameters and widths

| Parameter | Default | Supported |
| --- | --- | --- |
| `MAX_BINS` | 64 | 1..256 |
| `MAX_AVERAGES` | 16 | 1..64 |
| `TAG_W` | 8 | 1..32 |

Let `A=ceil(log2(MAX_AVERAGES))`, with `A=0` at one. `POWER_W=32+A` is unsigned, and `CROSS_W=33+A` is signed. Signed16 inputs are widened to signed17 **before** imaginary negation, so input `-32768` is legal. Each power is at most `2^31`, and the magnitude of each cross component is at most `2^31`; multiplying these bounds by the supported average count fits the sum widths. A `2*CROSS_W+1` numerator preserves both squared components and their sum. The divider receives an extra leading zero for each signed-positive operand.

## Core interface

All events are at rising `clk` edges. `rst` is synchronous active high. There is no external clock enable; ready/valid transfers are ordinary, unqualified transfers. Hold every valid beat and its associated fields stable until its own ready is high.

| Interface | Meaning |
| --- | --- |
| `c_valid/c_ready` | Start one batch. `c_bins` and `c_averages` are full unsigned32 values; `c_tag` is opaque. |
| `s_valid/s_ready` | One already paired X/Y spectral bin. Both LAST bits and all four lanes transfer together. |
| `m_valid/m_ready` | One bin result, or one fatal marker. All output fields remain stable under backpressure. |

`s_xy[15:0]` is X real, `[31:16]` X imaginary, `[47:32]` Y real, and `[63:48]` Y imaginary; each lane is signed16. Input order is segment 0 bins 0..N-1, segment 1 bins 0..N-1, continuing for K segments. **Both** `s_x_last` and `s_y_last` must be one exactly on each segment's final bin. The core does not infer alignment or repair unequal segment boundaries.

The command is captured only on `c_valid && c_ready`; later changes on its fields have no effect. Length and average count are validated at their full32 widths before narrowing. One batch owns the core until its final response retires. There is no command fallthrough on a response-retirement edge, no input accepted while results are emitted, and no output emitted until collection completes successfully. A producer that stops mid-batch leaves the batch pending until reset; no input timeout is implemented.

Successful collection emits index 0..N-1. Outputs are `m_sxx`, `m_syy`, signed `m_cross_re/m_cross_im`, unsigned17 `m_coherence_q16`, status, index, captured tag and `m_last`. Normally `m_last` identifies bin N-1. A fatal marker also asserts `m_last` and terminates every remaining bin.

| `m_status` | Name | Output rule |
| --- | --- | --- |
| 0 | OK | Exact raw sums and rounded Q16. |
| 1 | BAD_LENGTH | N=0 or N>MAX_BINS. One fatal zero-statistics marker, index 0. Takes precedence over bad K. |
| 2 | BAD_AVERAGES | K=0 or K>MAX_AVERAGES. One fatal zero-statistics marker, index 0. |
| 3 | BAD_LAST | Either LAST differs from the expected boundary on an accepted beat. Fatal zero-statistics marker at the expected input-bin index. No later input is accepted. |
| 4 | ZERO_ENERGY | Sxx=0 or Syy=0. Preserve raw sums and emit q16=0; continue to following bins. The estimate is undefined for this bin. |
| 5 | ARITH | Internal helper flag/invariant failure. Fatal zero-statistics marker; no subsequent bin is emitted. |

MAC-phase ARITH uses the expected input index. Later ARITH uses the current result index. Earlier successful responses may already have retired before a later arithmetic fault. Legal inputs cannot cause the checked overflow, nonzero zero-energy cross, ratio-above-one or divider-flag conditions; the TB exercises MAC and divider flags using explicit fault injection. A malformed LAST is a protocol error regardless of the sample values.

Reset cancels the command, stored ownership and pending output. RAM contents are not reset; the first segment of every new batch overwrites every commanded bin before any read of that batch. Readiness and validity are gated low while `rst` is high. After reset release, wait for `c_ready`: a registered helper reset bridge provides one recovery edge. The serial multiplier's asynchronous active-low reset changes only on clock edges, its CE is tied high, and the two synchronous active-low helpers observe a complete reset edge. ARITH also flushes every helper before presenting its marker, preventing queued products from leaking into the next batch. Reset is not a CDC synchronizer; all external interfaces share this clock.

## Architecture and cycle service

One unchanged `cplx_mac` computes X power, Y power and `Conj(X)*Y` in three successive issues. It contains four signed17 multiplier operators. One packed synchronous-read sum RAM stores `{cross_im,cross_re,syy,sxx}`. A shared unchanged serial unsigned multiplier forms R², I² and Sxx*Syy. A shared unchanged iterative divider performs the final RNE ratio. No combinational wide divide, per-bin multiplier bank or resettable RAM array is instantiated.

With ready inputs and no reset/fault, accepted pairs have **II=8 clocks**. Taking pair acceptance as edge 0: MAC issues are edges 1/2/3, results are consumed at 4/5/6, and RAM write is 7. The next pair may transfer at 8. The final write is followed by a synchronous bin read and energy check.

Define `C=CROSS_W`, `H=ceil(2*C/8)`, `Lm=C+H+1`, `D=2*C+2` and `Ld=D+16+1`. `Lm` and `Ld` are helper input-transfer to earliest output-transfer latencies. For a nonzero-energy bin, first result validity occurs `14+3*Lm+Ld` clocks after final paired input acceptance; its earliest transfer is one clock later. After retiring a result, the next nonzero-energy result's earliest transfer is `8+3*Lm+Ld` clocks later. The corresponding default values are 251 clocks to first validity, 252 to first transfer, and 245 between result transfers. Supported maxima are 261, 262 and 255 respectively. First zero-energy validity occurs after 9 clocks and its earliest transfer after 10; later zero-energy results can transfer 3 clocks after the preceding retirement.

For N bins and K segments with every bin nonzero and all peers ready, the last response transfers `8*K*N + N*(8+3*Lm+Ld)` clocks after command acceptance. Input gaps and output stalls add waiting time. This is an RTL cycle schedule; no actual hardware clock rate has been measured. The finite TB used a conservative 320-clock wait bound per result; maximum observed wait in its four profiles was 261 clocks for the direct core and 258 for the separate example profile's finite vectors.

RAM payload is `MAX_BINS*(2*POWER_W+2*CROSS_W)` bits: 9,344 bits at default (about 1.14 KiB), and 39,424 bits at supported maxima (about 4.81 KiB). Single-port synchronous read/modify/write phases do not collide. Architecture risk is **MEDIUM**: RAM packing/inference, four narrow signed multiplier operators, wide carry-save/fold logic and iterative division require later tool-specific implementation review. These are structural estimates, with no measured LUT/FF/BRAM/DSP use, timing or power claims.

## Actual connecting example

`example/dual_fft_coherence64.sv` connects two independent ordered complex-spectrum streams to the core with one holding slot per lane. Each stream is signed16 complex `{imaginary,real}` with ordinary ready/valid and its own LAST. Independent skew is allowed; each lane is paired with the matching ordinal beat from the other lane. A per-lane 11-bit remaining counter limits input to commanded N*K. The small setup multiplication uses the validated 7-bit N and 5-bit K fields.

This example fixes maxima 64/16/tag8 but still accepts runtime N and K. It accepts spectral outputs of upstream FFT engines; it does not instantiate an FFT or synchronize sampling, windows, clocks, frame identity or frequency axes. Upstream logic must already ensure matching spectra. No same-edge refill is allowed for a full slot, so the adapter can add bubbles and up to one pending sample per lane. On a fatal LAST/ARITH marker, it discards at most one already prefetched sample from each lane and cancels the remaining counts. Upstream must restart both streams with a new command; silently continuing the abandoned batch would lose alignment. Invalid commands accept no spectral input.

From this package root, `files.f` resolves the core's entire HDL closure. `example/files.f` adds the actual connecting example. Reuse dependencies by their existing canonical paths; the three helper files have no local edits. Licenses, provenance and pre-implementation semantic comparison are in [SOURCES.md](SOURCES.md).

## Finite evidence

`reports/20261105T191643_574520Z/results.json` records the only attempted run: 10 PASS HDL children (2 syntax, 4 compile, 4 simulation), four completed numerical preparations, no failure, timeout or automatic retry. Exact executable-source bytes were archived before numerical preparation; all four vector files were archived and hashed before the first HDL child. Current source and vector hashes remained unchanged. Each HDL child had a 20-second wall deadline with fail-stop behavior. All compile diagnostics are the inherited/design-module missing-timeunit warning; syntax checks and simulations have empty stderr.

| MAX_BINS / MAX_AVERAGES / TAG_W | Subject | Responses / accepted pairs / commands |
| --- | --- | --- |
| 1 / 1 / 1 | Core | 29 / 27 / 34 |
| 17 / 4 / 8 | Core | 74 / 135 / 41 |
| 256 / 64 / 32 | Core | 313 / 434 / 41 |
| 64 / 16 / 8 | Actual dual-stream example | 121 / 195 / 41 |

Counts include reset-cancelled setups, recovery transactions and fault injections. Totals are 537 responses, 791 accepted pairs, 157 commands, 2,148 stalled-output cycles, 24 resets including initial resets, and 8 injected faults. The example exercised 195 independently skewed pairs. The direct multibin profiles observed 501 II=8 intervals. The suite tests signed minima/maxima, positive-imaginary conjugation convention, opposite and orthogonal segments, Q16 zero/half/unity, exact ties 0.5→0 and 1.5→2, zero energy, high-bit/zero/excess commands, LAST mismatch/early/missing cases, config mutation and stable held outputs. Maximum N at K=1 and maximum K at N=1 are separate cases; there is no largest N×K replay.

After vectors, each profile cancels partial collection, in-flight MAC work, serial multiplication, division and a held output with reset, then verifies a clean unit-coherence recovery. MAC and divider fault injections verify fatal ARITH termination and recovery; the adapter MAC injection also exercises cancellation of prefetched lane slots. This finite evidence does not constitute exhaustive parameter testing, statistical validation, synthesis, full regression or physical verification. `run_tests.py` is retained for an explicitly authorized future run; this delivery does not require a repeat.
