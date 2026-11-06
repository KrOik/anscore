# Uniform-occupancy ADC code-density measurement

`adc_code_density` collects a bounded record of unsigned8-bit codes and reports
the occupancy error and cumulative occupancy error for a selected contiguous
code interval. It adds exact signed DNL/INL numerators, their common observed
denominator, signed RNE fixed-point values and zero-count candidates to the
existing histogram infrastructure. The actual example captures a trigger and
255 following codes through the unchanged `sys_trigger_window` before analysis.

The excitation must provide uniform ideal occupancy across the selected bins,
as for a suitable uniform ramp with the intended range/endpoints controlled.
For selected codes `a..b`, `K=b-a+1`, observed count `H[i]`, selected total `T`,
and prefix `P[i]=sum(H[a..i])`, the exact reported definitions are:

```
DNL_num[i] = K*H[i] - T
INL_num[i] = K*P[i] - (i-a+1)*T
DNL[i] = DNL_num[i]/T
INL[i] = INL_num[i]/T
q = RNE(2^FRAC_W * numerator/T)
```

INL is measured at the right boundary of each selected bin relative to the
selected interval's cumulative endpoints. The implicit left endpoint and the
reported final right endpoint are zero. This definition does not perform a
best-fit-line correction. Counts outside `a..b` are excluded from `T`; host
software can exclude overdriven endpoint codes, for example with range1..254.

These are finite-record, empirical occupancy estimates in selected-code LSB
units. Excitation nonuniformity, noise, hysteresis, jitter and finite statistics
can bias them. No sinusoidal probability correction, confidence interval,
offset/gain estimate, physical missing-code proof, calibration accuracy or
production-test certification is supplied. `m_zero_count` identifies an observed
empty bin, which may be entirely expected for a short record. The trigger256
example demonstrates integration and does not establish adequate sample size
for a specified statistical precision. See the official ADC references in
SOURCES.md for the distinction between a known ideal distribution and a measured
histogram.

All channels transfer on a rising edge with `valid && ready`; no CE or CDC is
present. Hold active-low `rst_n` across a rising edge. Reset cancels the record,
any held row and DONE; the next command explicitly clears all256 histogram bins.
`cmd_valid/cmd_ready` snapshots `cmd_first`, `cmd_last` and opaque tag. A valid
range then consumes exactly `SAMPLES` codes, regardless of early/missing `s_last`.
`s_last` must be true only for the last accepted sample. An incorrect marker
causes status2 after that fixed record is consumed. There is no automatic
input resynchronization, record timeout, or inference of an analog ramp period.

Rows are emitted in increasing code order. `m_count` is H, `m_den` is T;
`m_dnl_num/m_inl_num` are exact signed integers. The signed `m_dnl_q/m_inl_q`
are Q(FRAC_W) LSB values. The two inexact flags indicate nonzero remainder
before rounding. `m_last` marks the selected final code; the tag belongs to the
accepted command. All row fields hold while stalled. DONE follows retirement
of the final row and holds status/tag until `done_ready`. A future command
cannot cross acquisition, analysis, a held row or held DONE.

| done_status | Result |
| --- | --- |
|0|Successful selected-range measurement; exactly K rows.|
|1|`first>last`; no samples consumed and no rows.|
|2|Histogram framing/readback/division fault; discard this transaction's rows.|
|3|Selected total T=0; the record was consumed but no rows are defined.|

Valid inputs cannot cause a division fault or count overflow. A defensive
readback/division fault after rows have begun can expose a partial transaction;
rows become committed only after successful DONE. Reset or error discards them.
K=1 with T>0 yields a single exact-zero DNL/INL row.

Static interfaces preserve `SAMPLES=1..65535`, `FRAC_W=0..16`, and `TAG_W=1..32`.
Defaults are4096/12/8. Code range is8 bits including0 and255; K uses9 bits so
all256 codes are supported. No profile narrows this legal interface. Finite
qualification covers the actual maximum65535/16/32 as well as small and
non-power-of-two records; it does not enumerate the input/state space.

`trigger_adc_density256` accepts one arm/tag/range jointly with the measurement
core. For a valid range, pretrigger inputs are accepted and discarded (PRE0);
the accepted trigger code and255 following accepted codes form the record.
Capture accepts at most one code per clock, then replays through the core's
two-clock histogram input service. Inputs must obey `s_ready`; a continuously
running physical ADC needs an appropriate source adapter or sampling policy.
The next arm waits for measurement DONE retirement. Invalid ranges do not arm
the capture. Trigger/control changes during owned work cannot reconfigure it.

`files.f` and `example/files.f` are resolved from this package root. Existing
histogram, multiplier, integer divider and trigger source remain unchanged.
ARCHITECTURE.md documents bounds and a conservative always-ready cycle budget.
No physical resource count, frequency, power or board throughput is claimed.

Current state: `RTL_CANDIDATE`, `INTEGRATION_CANDIDATE`, `HW_UNVERIFIED`.
No planning oracle call, model import, preparation child or HDL child has run.
PRECHECK_PLAN.json freezes four isolated archived preparation children followed
by eleven HDL children: three syntax checks and four compile/simulation pairs.
Complete-source review and explicit root authorization of the SOURCE_SEAL hash
must precede the sole runner invocation:

```
python -I -B run_checks.py --execute-reviewed-seal <reviewed-SOURCE_SEAL-sha256>
```

Every child has a20s execution limit,5s tree-kill limit and one2s exit/raw-drain
observation limit. Raw stdout/stderr are directly redirected to binary files;
no decoding or reader-thread buffering affects the retained bytes. Failures,
timeouts, partial images and cleanup diagnostics are retained. The exclusive
EXECUTION_LOCK prevents retry. No inherited runner/model/checker imports,
inherited regression, synthesis, PnR, STA, board/PPA, cleanup, staging or commit
are part of this package's finite plan.
