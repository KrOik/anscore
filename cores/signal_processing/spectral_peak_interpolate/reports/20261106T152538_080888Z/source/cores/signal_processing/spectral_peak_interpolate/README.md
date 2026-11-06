# Quadratic spectral peak interpolation

`spectral_peak_interpolate` accepts one natural-order unsigned32 FFT power
frame and estimates the fractional bin location of its strongest bin inside a
runtime inclusive search interval. This adds sub-bin peak location to the
existing integer `peak_search`; it does not identify a fundamental among
harmonics, estimate multiple tones, run an FFT, compute dB, or calibrate an
instrument. The actual I/Q example composes unchanged `mag_squared` with this
instrument. Source provenance and semantic deduplication are in `SOURCES.md`.

Current status: **AUTHORED / EXECUTION_PENDING / HW_UNVERIFIED**. No model,
HDL, synthesis, PnR, STA, board or PPA run has occurred for this package.

## Numeric contract

For N=2^c_log2n, choose the earliest maximum in `[c_low,c_high]`. Let its index
be k and let L=P[k-1], C=P[k], R=P[k+1], using actual frame samples even when
the neighboring bin lies outside the search interval. Return these exact
unsigned32 values, k, and signed34 `K=2*C-L-R`. Interpolation is valid iff
`C>0 && C>=c_min_power && C>=L && C>=R && K>0`. Then:

```text
offset_q16 = round_to_nearest_ties_even((R-L)*65536 / (2*K))
bin_q16 = k*65536 + offset_q16
frequency_hz = bin_q16 * sample_rate_hz / (65536*N)  [caller conversion]
```

The signed18 offset is bounded by +/-32768 (half a bin). The unsigned32
position is exact for that rounded offset. A flat top, zero spectrum,
nonlocal maximum at a search boundary or threshold rejection returns
`m_interp_valid=0`, offset zero and the integer bin in Q16. Threshold equality
is accepted. A positive plateau can yield a half-bin vertex when K>0;
three equal samples yield K=0 and no interpolation. Power-scale interpolation
is a model choice: finite windows, nearby tones and noise cause estimator bias;
the exact integer arithmetic does not establish physical frequency accuracy.
Curvature is a shape diagnostic, not a calibrated confidence or noise estimate.

## Parameters and interface

`MAX_LOG2N` is 4..12 (default8), `TAG_W` is 1..32 (default8). Unsupported
elaboration parameters instantiate a named missing-module guard.
All ports use rising-edge clk, synchronous high-active rst, ordinary
ready/valid and no CE/CDC. Reset cancels the whole transaction, iterative
helpers and pending response; payload RAM is not reset and is fully loaded
before reading. Source fields remain stable while valid and not ready.
The entire response remains stable until accepted. One command owns service
until its response retires; no next command or data is accepted in OUT.

| Interface | Meaning |
| --- | --- |
| c_valid/c_ready | Capture all command fields at handshake |
| c_log2n, c_low, c_high, c_min_power | Full unsigned32 checked before narrowing |
| c_tag | Captured opaque TAG_W metadata |
| s_valid/s_ready, s_power | Accept exactly N ordered powers after configuration |
| s_last, s_invalid | LAST required exactly on Nth input; invalid takes precedence |
| m_valid/m_ready, m_status | One response per accepted command |
| m_tag, m_log2n, m_low, m_high, m_min_power | Echo captured command |
| m_received | 13-bit actual accepted sample count |
| m_peak_index, m_left, m_center, m_right | Exact integer peak and actual neighbors |
| m_curvature, m_offset_q16, m_bin_q16, m_interp_valid | Numeric outputs above |

Legal commands have `4<=c_log2n<=MAX_LOG2N`, `1<=c_low<=c_high<=N-2`.
Status0 is a complete measurement (including validly rejected interpolation),
1 invalid command, 2 invalid sample, 3 early LAST, 4 missing LAST on Nth input,
5 defensive divider-flag failure. Invalid commands accept no samples.
Errors2..4 stop on the offending accepted sample; later samples are not
accepted. Status1..4 produce zero measurement fields and the actual received
count. Status5 preserves readback powers/index, clears curvature/position and
does not assert interpolation validity. All errors still echo command metadata.
A short input without LAST remains waiting until more input or reset;
there is no wall-clock timeout or automatic frame resynchronization.

`example/iq_spectral_peak_interpolate.sv` exposes the same contract with
`s_iq={Q[15:0],I[15:0]}` signed16 FFT bins replacing s_power. Power is exactly
I*I+Q*Q at shift0 (maximum2^31), with a matching four-stage LAST/invalid
pipeline. It stops accepting input at the first LAST/invalid or Nth sample,
so malformed packets leave no younger input in flight.

## Offline integration and finite plan

Resolve both source lists from this package directory. The complete closure
is included, with no nested file list, ROM generator, vendor primitive or
network requirement. Shared production sources are unmodified and root
confirmed their presence in BASE d32ea87e268c5957b7203560a5b46864e282a6e1.

`PRECHECK_PLAN.json` lists exact archived-source preparation, syntax, compile
and simulation commands. `SOURCE_SEAL.json` pins source/tool bytes and a
separate root/peer review must authorize the exact plan before this command:

```text
python -B run_checks.py --execute-approved-plan
```

Four isolated whole-frame integer-oracle preparations precede two syntax
children and four compile/simulation pairs: minimum4/TAG1, default8/TAG8,
maximum12/TAG32 and actual I/Q8/TAG8. Each checks32 frames,14 live reset
cancellations/recoveries,46 exact responses and184 deliberately held cycles.
Fixtures cover zeros, ties/plateaux, full unsigned32 power, both signed16
minima, +/-half-bin offsets, rational RNE ties, threshold equality/rejection,
band edges with larger outside neighbors, a directly computed windowed-tone
DFT, invalid full-width configuration and LAST/invalid precedence.
The producer sends consecutive samples with a gap every fifth item; an actual
adjacent-clock accepted-input counter must be positive in every profile.
Both power and I/Q profiles reject any trailing vector token and require EOF.
The TB reaches each active state1..13 and a partial-load cancellation, then
requires a fresh successful recovery. Independent list selection and divmod
RNE define the oracle; its32 frames do not copy the RAM/FSM/helper schedule.
Every started child is limited to20s, termination helper5s, and one shared2s
exit/output observation interval. Failure stops all later launches, evidence
is persisted before parsing, and an existing attempt prevents automatic retry.
No physical implementation claim follows from finite RTL evidence.
