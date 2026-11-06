# Single-tau overlapping Allan variance

`phase_allan_variance` measures the stability of a uniformly spaced, signed
phase/time-error sample record. For one runtime averaging factor `m`, it reports
the exact overlapping second-difference energy, its normalization denominator,
and a nearest-even Q16 variance. A constant phase or constant frequency offset
has zero result; changes in frequency contribute to the statistic. This is a
record-processing datapath, with no pin frontend, timestamp clock, CDC or analog
calibration. See `SOURCES.md` for semantic deduplication and external references.

The frozen implementation starts at **RTL_CANDIDATE + HW_UNVERIFIED**.
`PRECHECK_PLAN.json` is a prospective finite plan, not a PASS record. Any later
qualification is recorded separately in `QUALIFICATION.json` and `STATUS.md`;
the frozen inputs remain unchanged. No synthesis, PnR, STA, board, PPA,
inherited regression or combined HDL compilation is requested.

## Numerical contract

For signed integer samples `x[0] ... x[N-1]` and `K=N-2m>0`:

```text
d[i] = x[i+2m] - 2*x[i+m] + x[i]             i=0 ... K-1
S = sum(d[i]^2)
D = 2*m*m*K
variance_q16 = RNE((S*65536)/D)
```

All K overlapping terms are used, including K=1. This computes a variance
estimator; no deviation/square root, confidence interval, multi-tau sweep,
drift removal, gap interpolation or estimator-quality guarantee is supplied.
The output unit is `(phase LSB / nominal sample interval)^2`, encoded with
16 fractional bits. If one phase LSB represents `u` seconds and the nominal
spacing is `tau0` seconds, multiply the decoded variance by `(u/tau0)^2` to
obtain fractional-frequency Allan variance. For phase in angle units, callers
must supply the corresponding nominal-frequency conversion. Ready/valid gaps
are transport stalls: they do not change the logical sample spacing. Callers
must flag missing, irregular or otherwise unusable measurements with `s_invalid`.
The core cannot discover lost physical samples or unwrap modular phase values.

`DATA_W` supports 8..16 (default16), `MAX_SAMPLES` 3..4096 (default256),
`MAX_M` 1..64 (default64), and `TAG_W` 1..32 (default8). Derived parameters
`SUM_W=2*DATA_W+2+ceil(log2(MAX_SAMPLES))` and `VAR_W=2*DATA_W+18`
must retain those values. Unsupported parameters instantiate a named missing
module. Full-width runtime commands require `3<=N<=MAX_SAMPLES`,
`1<=m<=MAX_M`, and `2m<N`. No narrowing precedes validation.

The exact signed second-difference bound is `|d|<=2^(W+1)-2`; W+2 signed
bits suffice, including18 at W16. Both intermediate additions also fit.
The exact record bound is
`S <= (N-2m)*(2^(W+1)-2)^2 < 2^(2W+2+ceil(log2(MAX_SAMPLES)))`.
Thus the accumulator needs at most46 bits. The 18x18 helper retains the full
36-bit square; any omitted bits at smaller supported widths are provably zero.
The signed divider receives an explicit leading zero on both operands. Its
`AW=SUM_W+1, FB=16` recurrence retains all bits of `S<<16` plus a sign bit;
at the largest profile this is63 numerator bits and a64-bit rounding extension.

The largest denominator over the complete legal domain is
`2*64^2*(4096-128)=32505856<2^25`.
`m^2<=4096` fits13 bits; `m^2*K<=16252928<2^24` before the exact left
shift. The maximum Q16 result is bounded by
`(2^(W+1)-2)^2*2^15 < 2^(2W+17)`; the signed helper's `VAR_W` output
has that positive range. No legal result clips, wraps or loses fractional
input precision. RNE uses the full integer quotient and remainder, including
even and odd half-LSB ties. No intermediate floating point is used.

## Interface and ownership

All public transfers occur on rising `clk` when both valid and ready are high
and `rst` is low. `rst` is synchronous active-high, masks all public ready/valid,
discards the record/result, and resets control without clearing RAM. There is
no CE. The original multiplier/capture helpers have asynchronous reset pins;
their local reset assertions originate only at a rising edge of this clock.

| Channel | Fields | Contract |
| --- | --- | --- |
| Command | `c_valid/c_ready`, unsigned32 `c_samples,c_m`, `c_tag` | Accepted only idle; captures N, m and tag. Hold fields until transfer. |
| Samples | `s_valid/s_ready`, signed W-bit `s_phase`, `s_last,s_invalid` | Exactly N accepted samples. LAST is required only on sample N. Invalid is sticky through the record. |
| Result | `m_valid/m_ready` and all fields below | One held response per command; every field is stable under backpressure. |

Result fields are status3, captured tag, original unsigned32 `m_samples,m_m`,
accepted count13 `m_received`, term count13 `m_terms`, exact unsigned SUM_W
`m_sum`, unsigned25 `m_den`, and unsigned VAR_W `m_variance_q16`.
On OK, received=N, terms=N-2m and all arithmetic fields are valid. Every error
sets terms/sum/den/variance to zero, while retaining original command fields,
tag and the actual accepted sample count. There is no sentinel arithmetic value.

| Status | Meaning |
| --- | --- |
| 0 OK | Complete valid record, exact numerator/denominator and RNE variance. |
| 1 BAD_CONFIG | Invalid full-width N or m; consumes no samples. |
| 2 EARLY_LAST | LAST before sample N; ends immediately at that sample. |
| 3 MISSING_LAST | Sample N accepted without LAST; stops after N. |
| 4 SAMPLE_INVALID | At least one accepted sample had invalid=1. |
| 5 ARITHMETIC_FAULT | Shared divider reported div0/clip; defensive invariant diagnostic. |

Precedence is config, early LAST, missing LAST, invalid sample, arithmetic
fault. Changes to command fields after acceptance have no effect. No command
or sample is accepted during calculation or a held response. Output retirement
returns to idle; there is no same-edge command fallthrough. Reset cancellation
produces no response. A caller that sends fewer than N samples without LAST
owns the service until reset or further samples; there is no physical-time timeout.

## Architecture and service budget

The core captures into one `MAX_SAMPLES*DATA_W` memory,512B by default and8KiB
at the maximum profile. It then reads each triplet through a single synchronous
read port in three successive cycles. The memory is not reset. Registered
second-difference and magnitude stages feed one unchanged18x18 serial multiplier;
the same helper performs m*m and m*m*K after accumulation. One unchanged
iterative divider normalizes once per record. No multiplier bank or m-dependent
parallel array is generated. RAM inference, DSP mapping and device fit remain
unmeasured. Qualitative architecture risk is MEDIUM, especially the full-size
RAM, wide accumulator and helper divider control; this is not a PPA measurement.

Collection accepts one sample per clock without input backpressure after a
legal command. With continuous valid inputs and no response stall, a conservative
command-to-earliest-response-transfer budget is `N+40*K+192` clocks. The
18-step CSA plus5 byte-fold multiplier, triplet reads, two denominator products,
and at most63 divider iterations are included. The next command waits until
the old response retires and idle is visible. Source gaps and arbitrary output
stalls add to elapsed time; no unconditional completion or hardware sample-rate
claim follows from these RTL cycle budgets.

## Real triggered-record composition

`example/trigger_phase_allan256.sv` instantiates the unchanged canonical
`sys_trigger_window` with DEPTH256/PRE0/POST255/WIDTH17 and the new core at
W16/N256. An accepted arm captures m/tag and starts one measurement transaction.
The ring discards all pretrigger samples, then retains the accepted trigger sample
and255 subsequent samples. The invalid bit travels in RAM alongside the signed
phase. Capture replay uses ready/valid directly into the core; its LAST is the
core's required final marker. The default m range is1..64. Invalid full-width
m commands produce BAD_CONFIG without arming capture. Held results prevent
rearming. Reset cancels both modules, including partial capture and replay.

This composition captures phase/time-error values already measured and unwrapped
by an upstream producer. A trigger is meaningful only on an accepted sample.
There is no pin/CDC conversion or continuous acquisition during capture replay
and computation. Waiting for a trigger or sample is unbounded. Excluding that
wait, capture adds256 accepted sample cycles and replay adds256 cycles before
the core's computation; backpressure is explicit. Example RAM adds544B to the
core's512B logical memory. No physical clock-stability accuracy is claimed.

## Offline finite plan

Resolve both source lists from this package root. They contain explicit entries,
with no nested `-f`, generated files, ROM, vendor primitive or network dependency.
The helper files remain at canonical repository paths and are not copied into
production. Run only after root independently reviews the frozen inputs:

```text
python -B run_tests.py --execute-approved-plan
```

The runner checks the source seal, archives every exact input before any oracle
execution, and archives `.gitattributes` as `.gitattributes.executed.txt` data.
Four isolated Python preparations each have a20s deadline. All vectors and
preparation summaries exist before either syntax child. The ten HDL children
are two syntax checks plus four compile/simulation pairs; every child is20s,
with tree cleanup5s and final pipe drain2s. A failure, missing tool, timeout,
missing completion marker or counter mismatch stops later launches. Existing
attempt directories prohibit automatic retry. Sources/tools/vector/raw output
and images are hashed. No cleanup, staging or commit is performed by the worker.
