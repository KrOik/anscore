# Symbol-frame EVM squared measurement

B38 baseline: `816d461b12fd402f6a146ca74c7491c7afbd3091`.

`symbol_evm_measure` measures a finite frame of already aligned complex received/reference symbols. It reports exact error energy, reference energy, maximum complex error energy with earliest position, and an explicitly rounded EVM squared ratio. It composes the existing scalar squared-distance engine and iterative divider. The actual `qam16_evm` connection obtains decision-reference symbols from the existing 16-QAM demapper's nearest-point indices.

State: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**. The separately reviewed [PRECHECK_PLAN.json](PRECHECK_PLAN.json) passed its first approved attempt: **10 PASS children, four successful simulations, four preparation calls and no historical HDL failure or retry**. No synthesis, placement/routing, STA, board or large regression has run.

## Numerical contract

For N accepted, paired complex symbols rx[k] and ref[k]:

```text
e[k] = (rx_re[k]-ref_re[k])² + (rx_im[k]-ref_im[k])²
Eerr = sum(e[k])
Eref = sum(ref_re[k]² + ref_im[k]²)
peak = max(e[k]); peak_index = first k attaining peak
q = min(2^32-1, RNE((Eerr * 2^16) / Eref))       when Eref>0
```

RNE means nearest integer with exact ties to even. `m_evm2_q16` is unsigned Q16.16 **EVM squared**, so its physical ratio is q/65536. Its positive saturation endpoint is 65535.9999847412109375; `m_clip` means the rounded quotient exceeded that endpoint. Energy sums and peak stay exact even when the ratio clips. This module does not compute a square root, EVM percent or dB. For an unclipped ratio, quantization error is at most 0.5/65536 in EVM squared units.

If Eref=0, `ZERO_REFERENCE` preserves exact Eerr, Eref, peak and position, but reports ratio=0 and clip=0. This includes the all-zero 0/0 frame: the zero ratio field has no defined EVM interpretation. Eerr=0 with Eref>0 is ordinary OK and ratio0. Equal maxima retain the earliest accepted-symbol index, including peak0 at index0.

The reference must use the same amplitude scale and symbol order as the received signal. Gain/phase/delay alignment, carrier correction, symbol timing, equalization and constellation normalization are caller responsibilities. The statistic includes residual gain/phase/DC errors unless the caller removes them. This package supplies no standard-compliant instrument calibration or complete receiver.

## Parameters and ranges

| Parameter | Default | Supported |
| --- | --- | --- |
| DATA_W | 16 | 8..16 signed bits per I/Q lane |
| MAX_SYMBOLS | 1024 | 1..4096, including nonpowers of two |
| TAG_W | 8 | 1..32 |

Let D=DATA_W and A=ceil(log2(MAX_SYMBOLS)), A=0 at cap1. Per-lane differences are in `[-(2^D-1), +(2^D-1)]`, represented by D+1 signed bits inside the unchanged distance engine. Each scalar square fits unsigned 2D. The complex error is less than `2^(2D+1)`, so `PEAK_W=2D+1`. Reference symbol energy is at most `2^(2D-1)`, including both signed-minimum lanes.

`ERR_W=2D+1+A` and `REF_W=2D+A` retain exact finite-frame sums. Defaults are 43 and42 bits, maximum supported widths45 and44. Accumulator adders have a carry guard. The divider receives one extra leading zero on each unsigned sum; AW=ERR_W+1, BW=REF_W+1, FB=16. Its signed33 output has positive endpoint `2^32-1`, matching the unsigned ratio's saturation exactly. Derived parameters COUNT_GROW/REF_W/ERR_W/PEAK_W are exposed only to size ports and must retain their defined values; static checks reject overrides.

## Interface and ownership

Single `clk`, synchronous active-high `rst`. Reset cancels a command, partial energies and held response. Ready/valid are gated low while reset is high. All external transfers use ordinary `valid && ready`; there is no CE or CDC. The two core helpers share synchronous reset through explicit polarity adaptation. The example's asynchronous-low demapper reset is driven by a registered bridge that changes only on rising edges; readiness remains closed until release.

`c_valid/c_ready` captures full-width `c_symbols[31:0]` and opaque tag. N must be 1..MAX_SYMBOLS; validation precedes narrowing. Exactly one command owns the core through final response retirement. A command offered while busy is not accepted. Configuration mutations after acceptance cannot change the frame.

Each `s_valid/s_ready` transfer carries `s_rx` and `s_ref`, packed `{signed_imaginary, signed_real}`, plus strict `s_last`. The LAST bit must be one only on the Nth accepted symbol. Both payloads and LAST must stay stable under stall. Only accepted symbols change index/history; input gaps stretch wall time. There is no input timeout. Sources connected to a physical converter must buffer and preserve the sampled sequence.

One response per command contains status, accepted count, captured tag, exact error/reference energies, peak error/position, Q16.16 ratio and clip. It stays stable until `m_valid && m_ready`. A new command cannot transfer on that final retirement edge. Malformed accepted LAST terminates the frame immediately; no remaining symbols are accepted.

| Status | Meaning | Output |
| --- | --- | --- |
| 0 | OK | Exact statistics; rounded ratio, possibly clipped. |
| 1 | BAD_LENGTH | Count0, zero statistics/ratio/peak; captured tag. |
| 2 | BAD_LAST | Count includes malformed beat; zero statistics/ratio/peak. |
| 3 | ZERO_REFERENCE | Preserve exact statistics; ratio0 and clip0. |
| 4 | ARITH | Guard/helper invariant failed; zero statistics/ratio/peak, accepted count. |

ARITH is unreachable for legal parameters/data. The controller checks the distance engine's overflow flag, expected error/reference tag order, sum carries, and impossible divider divzero/negative results. It flushes both helpers through a full reset edge before showing an ARITH marker. An externally asserted reset may cancel any marker. No underlying helper qualification is inherited by this combination.

## Architecture and cycle budget

One unchanged `vector_l2sq` is configured for two scalar components per complex vector and TAG_W1. Four consecutive scalar transfers compute received-minus-reference I/Q, then reference-minus-zero I/Q. Tags distinguish the two results. This reuses one signed(D+1) multiplier, its product register and scalar accumulator. The new controller adds the exact frame accumulators and earliest-peak comparison. No symbol RAM, coefficient ROM, sample replay buffer or external memory is needed.

For symbol acceptance edge0, four scalar issues occur at1..4; error/reference vectors become visible at4/6 and are consumed at5/7. A nonfinal next symbol can transfer at8, so the core's no-stall sample II is8. On a final symbol, the divider accepts at8. Let K=ERR_W+1+16 (its quotient iterations): ratio-valid is at K+9 and earliest response transfer at K+10. Defaults K60 give69/70; maximum K62 gives71/72. A zero-reference response is valid at8 and can transfer at9. Finite latency checks passed for all four profiles below, and no-stall II8/9 checks passed where a frame has multiple symbols. The default D16/cap1024 profile received syntax checking only. These cycle schedules imply no measured clock-frequency or physical sample-rate claim. Arbitrary input/output stalls add unbounded waiting.

Architecture risk: **MEDIUM**. One narrow inferred multiplier, serial division, guard adders, wide state and control; no device-fit, LUT/FF/DSP, Fmax, power or board measurement is available. A four-square fully parallel alternative was rejected because a frame measurement tolerates the eight-clock sample service and the existing one-multiplier engine already supplies exact arithmetic.

## Actual 16-QAM decision-reference example

`example/qam16_evm.sv` fixes signed8 I/Q, MAX_SYMBOLS1024, tag8 and parameter SPACING=3 (full integer legal range1..7, checked before narrowing). It directly instantiates the unchanged `acc_comm_qam16_llr`, with CE tied high and LLR gain0. Its nearest indices select levels `-3S,-S,+S,+3S`, using the lower coordinate on a tie. Reference coordinates are calculated in signed9 before retaining signed8, and their proven extent is [-21,+21].

A metadata slot retains original received I/Q and LAST until the matching demapper response enters the EVM core. It closes upstream readiness during that ownership. Demapper overflow/fault diagnostics never discard an accepted symbol: `m_qam_faults` and `m_qam_over_range` count them over the current frame and hold with its final response. With gain0 and valid constant spacing, a fault is the original over-range diagnostic. The response otherwise retains the core's exact measurement. A malformed LAST still includes its demapper diagnostics before terminating.

The example's no-stall input II is9 clocks and final-input-to-valid is one clock more than the corresponding core schedule. Decisions can be incorrect at poor SNR or severe distortion; decision-reference EVM can then understate error relative to the actually transmitted symbols. It measures the chosen local decision reference, with no automatic ambiguity resolution, decoder or proof of a correct symbol decision.

## Finite evidence

The explicit plan contains two syntax checks and four compile/simulation pairs (10 children), each at most20 seconds, fail-stop and no automatic retry. Profiles are D8/cap1/tag1, D16/cap17/tag8, D16/cap4096/tag32 with N<=37, and the actual D8 QAM16 connection. Full4096 playback is excluded. A durable INCOMPLETE receipt was written before preparation; all12 executable inputs were archived before four preparation calls, and all four vector sets were archived before the first HDL child. Current/archive sources, vector bytes and actual final/archived check order were rechecked on exit. A separate static audit verified these inputs, twenty raw log streams, both tool hashes and all four VVP images. Immutable baseline QAM source bytes also match the current/archived source. Any existing report entry blocks an automatic new attempt.

The [first receipt](reports/20261106T051041_639726Z/results.json) has SHA-256 `f6826f45014118b84a027ca32b2db201c480ff8b6c9a160a78856a032e41f284`. Its source hashes and check history are retained by [QUALIFICATION.json](QUALIFICATION.json) and [B38_DELIVERY.json](B38_DELIVERY.json).

| Successful simulation | Records | Symbols accepted | Resets | Held clocks | Exact tail timing | II checks |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| D8/cap1/tag1 | 27 | 28 | 7 | 108 | 20 | 0 |
| D16/cap17/tag8 | 32 | 156 | 7 | 128 | 24 | 85 |
| D16/cap4096/tag32, N<=37 | 32 | 236 | 7 | 128 | 24 | 125 |
| Actual QAM16 D8/cap1024/tag8, N<=37 | 31 | 235 | 8 | 124 | 23 | 124 |

Totals are122 results,655 accepted symbols and147 commands including canceled setups,29 resets,8 injected helper faults followed by recovery,488 held-output clocks,4 clipped ratios,6 zero-reference records,91 exact tail-latency checks and334 II checks. The longest result wait was71 clocks. The D16 profiles each include an even and odd exact half-LSB tie and a peak tie first reached after index0. The actual QAM connection retained and checked118 over-range/fault diagnostics without discarding samples. All counts describe the finite cases and do not qualify arbitrary channel models or hardware timing.

The independent Python reference uses whole-frame integer expressions, `max`/first index and `divmod` for exact rational RNE. It contains no scalar-vector pipeline or restoring-divider recurrence. The example reference minimizes distance over four mathematical levels; it does not call the existing QAM model. Directed cases include full signed ranges, zero/reference cases, earliest ties away from index0, even/odd half-LSB ties, clipped ratios, invalid full-width lengths, LAST errors, held outputs, exact latency/II, reset in each active phase and the demapper metadata slot, plus two injected invariant faults followed by recovery.

Source lists are package-root relative. See [SOURCES.md](SOURCES.md) for fixed upstream references, licenses and support-source baseline distinctions.
