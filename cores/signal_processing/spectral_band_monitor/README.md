# Power-spectrum band measurements

`spectral_band_monitor` turns one ordered power spectrum into a set of frequency
band measurements: integrated power, the first power-weighted bin moment, peak
power/index and the number of bins meeting a power threshold. Bands can overlap,
so one accepted bin can contribute independently to multiple measurements. This
provides channel energy, center-of-power and spectral occupancy primitives for
an FFT/Welch instrument. The example composes the monitor with the existing
`mag_squared` core and accepts signed16 complex FFT bins directly.

The existing `stft_welch` already supplies overlapping window/FFT/power/averaging;
`peak_search` supplies one global peak. This package adds runtime multi-band
measurement after those power spectra. Semantic/source review is in `SOURCES.md`.

Current status: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**, for the finite
checks recorded in `B34_DELIVERY.json`. LINT_PASS is Icarus syntax checking here.
No synthesis, PnR, STA, board test, device-fit or PPA measurement was performed.

## Numeric meaning and widths

Each accepted `s_power` is an unsigned32 integer in the caller's common power
units. The command specifies n bins and BANDS closed intervals `[low,high]`.
All bands must be nonempty and wholly inside `0..n-1`; invalid or reversed bands
reject the entire command. Overlap and identical intervals are legal. For each
band b, the exact outputs are:

```text
energy   = sum(P[k], k=low[b]..high[b])
moment   = sum(k*P[k], k=low[b]..high[b])
peak     = max(P[k], k=low[b]..high[b])
peak_bin = smallest k attaining peak
above    = number of P[k] >= captured_threshold
```

The threshold comparison is inclusive. Threshold zero counts every band bin,
including zero-power bins. All-zero bands return peak zero at their lowest bin,
with energy/moment zero. The peak tie rule is independent of threshold. Index k
is the absolute input bin index, not an index relative to the band.

Let `I=max(1,ceil(log2(MAX_BINS)))`. The derived widths, which cannot be
overridden independently, are `SUM_W=32+I` and `MOMENT_W=32+2*I`.
Bounds are `energy <= MAX_BINS*(2^32-1)` and
`moment <= (MAX_BINS*(MAX_BINS-1)/2)*(2^32-1)`. The peak/index and count outputs
are extended to32 bits. The internal count width holds MAX_BINS inclusively.
The registered common `k*P[k]` product has `32+I` bits. No addition or product
truncates in the supported domain; there is no numerical saturation, rounding,
overflow flag, fixed-point shift, division or floating point.

At MAX_BINS4096, energy is44 bits and moment56 bits. At the default1024 they
are42 and52 bits. MAX_BINS1 retains the minimum internal index width and has
33/34-bit outputs; its only possible moment is zero.

For nonzero energy, `moment/energy` is the exact rational power-weighted center
in bin units; division/scaling is a caller operation. For a contiguous one-sided
spectrum, frequency center is `fs/Nfft * moment/energy`. Zero energy leaves that
ratio undefined even though the transmitted numerator/denominator are both zero.
If input units are power spectral density, a physical band integral also needs
the caller's bin spacing; the emitted energy is the exact integer sum. This core
does not change one/two-sided scaling, window normalization or FFT-bin ordering.
Natural FFT negative-frequency indices are still their unsigned arrival indices;
the caller must choose/reindex bands appropriate to its frequency convention.

## Parameters, commands and streams

| Parameter | Supported range | Default |
| --- | --- | --- |
| MAX_BINS | 1..4096 | 1024 |
| BANDS | 1..8 | 4 |
| TAG_W | 1..32 | 8 |

Unsupported profiles fail elaboration through a named missing module.
`INDEX_W`, `COUNT_W`, `SUM_W` and `MOMENT_W` are derived localparams.
All ports share rising-edge `clk`. `rst` is synchronous active-high, overrides
transfers, cancels collection/accumulation/pending results and clears public valid
state. There is no CE or CDC. Payload accumulators/configuration arrays are not
reset; every legal command initializes them before reading them.

| Port | Width | Meaning |
| --- | --- | --- |
| c_valid / c_ready | 1 each | Command transfer on both high outside reset |
| c_bins | 32 | Full unsigned n, checked as1..MAX_BINS before narrowing |
| c_threshold | 32 | Common inclusive unsigned power threshold |
| c_low / c_high | 32*BANDS each | Band b occupies bits `[32*b+:32]` |
| c_tag | TAG_W | Captured opaque spectrum tag |
| s_valid / s_ready | 1 each | Bin power transfer on both high outside reset |
| s_power | 32 | Power of the next natural-order bin |
| m_valid / m_ready | 1 each | Band-result transfer on both high outside reset |
| m_status | 2 | 0 OK, 1 BAD_LENGTH, 2 BAD_BAND; 3 never generated |
| m_band | 32 | Band index, ascending0..BANDS-1 on success |
| m_low / m_high | 32 each | Captured inclusive band limits on success |
| m_energy / m_moment | SUM_W / MOMENT_W | Exact sums above |
| m_peak_power / m_peak_bin / m_above | 32 each | Peak/tie winner and inclusive threshold count |
| m_last | 1 | Final result, or sole error marker |
| m_tag | TAG_W | Captured spectrum tag |

All command fields are captured only on acceptance. Producers hold valid and
payload while blocked; fields may change after their handshake. A legal command
owns the module through final-result retirement. There is no command acceptance
on that retirement edge. `s_ready` becomes high after a legal command and accepts
exactly n bins, in order k=0..n-1. There is no input index/last/sof field: the
agreed count defines frame completion. Input may pause arbitrarily. Samples are
not accepted on the command edge or while band outputs are being returned.

After n powers, BANDS results appear in ascending band order. Every result field
and valid stay stable under output backpressure. Invalid length takes precedence
over band validation and returns one last error marker with band0. For valid n
but bad bands, the first invalid band index is returned. All other numerical and
limit fields of an error are zero. No sample is accepted for an invalid command.
Checking full32-bit bounds prevents high-bit aliasing to a narrower internal bin.
There is no timeout/resynchronizer for a truncated input spectrum and no external
memory/error interface.

## Composed I/Q spectrum example

`example/iq_spectral_band_monitor.sv` exposes the default four-band/1024-bin
command and measurement interface. Its `s_iq[15:0]` is signed16 I and `[31:16]`
signed16 Q. It reuses the unchanged existing
`../dsp_isp_library/dsp/spectrum/rtl/mag_squared.sv`, reset synchronously through
`rst_n=!rst`, with shift fixed0 and runtime configuration disabled. Thus every
accepted complex bin produces exact unsigned `I*I+Q*Q`, at most2^31, without
rounding or clipping. For Q1.15 inputs these are raw power units scaled by2^30.

An explicit remaining-input counter admits exactly n I/Q bins even though the
power pipeline has in-flight entries. Input readiness also requires the monitor
to be collecting; invalid commands admit no complex samples. The pipeline drains
all n powers before results are exposed, and no old powers survive into a new
command. This wrapper is an actual composed dataflow implementation, not a
precomputed example; its full chain is exercised in the finite tests. It accepts
complex FFT bins, so the upstream can be an existing FFT. The standalone monitor
can directly consume integer power spectra from the existing Welch core instead.

## Architecture, timing and resource risk

One shared index-by-power multiplier creates a registered weighted term per
accepted bin. On the following clock, each matching band independently updates
its energy, moment, threshold count and peak. The product is shared across bands;
the BANDS energy/moment adders, counters, range comparisons and peak comparators
are real parallel hardware. Array state is bounded by BANDS, not frame length.
There is no spectrum/frame buffer or runtime band-position scan.

Qualitative architecture risk is **MEDIUM**: up to eight wide accumulator paths
and their input fanout, one32-by12 multiply at the maximum profile, and large
parallel command validation can affect area/timing. The I/Q example adds the
existing two square operators and its power pipeline. Physical DSP mapping,
resource counts, achievable clock, power and device fit are unmeasured.

The standalone core can accept one power bin per clock during collection.
It consumes the registered final-bin contribution on the following clock and
presents the first result two clocks after final input acceptance. After a result
retires, the next becomes valid one clock later and can retire on the following
clock. Invalid commands present their error immediately after acceptance.
For the always-ready I/Q example, a final accepted complex bin reaches its first
band result six clocks later: four to its monitor power handshake and two inside
the monitor. Output/command ownership and stalls can extend total transaction
time without changing numerical results. Unbounded stalls prevent an unconditional
deadline. These are RTL schedules, not measured hardware throughput.

## Source closure and finite checks

Resolve both `files.f` and `example/files.f` from this package root. Production
is the single monitor RTL. The example additionally lists the unchanged existing
magnitude source and its new wrapper. No generator, coefficient data, vendor
primitive, external memory or network access is required. The magnitude source is
Git tracked, matches the pinned HEAD bytes and has no global module collision in
the B33 canonical source set. `B34_DELIVERY.json` records its support-source hash.
Legacy magnitude/Welch historical physical evidence is not inherited here.

```text
python -B run_tests.py
```

The standard-library runner snapshots every exact executable input source,
including the reused magnitude source, before preparing vectors. All four vector
sets are saved before the first HDL tool. It uses absolute local OSS executables,
suite bin/lib PATH, a20-second deadline per child, bounded tree cleanup, and stops
launches after missing tools, timeout, failure or missing simulation PASS marker.
Preparation attempts/completion and complete-suite status are separately recorded;
partial preparation or partial successful syntax never becomes an overall PASS.
Raw logs, hashes and input sources remain in the timestamped report. Ignored
`.build/` VVP images await root-owned post-review cleanup. `.gitattributes`
preserves new-source bytes.

Current finite profiles `(MAX_BINS,BANDS,TAG_W,IQ)` are `(1,1,1,0),(17,3,8,0),
(4096,8,32,0),(1024,4,8,1)`. Two syntax checks, four TB compilations and four
simulations passed. The TB verified152held band/error records,20627accepted input
beats including cancellation setups,456stall clocks and16reset scenarios. Fixtures
include full-width maximum power/maximum frame sums and moments, all-zero power,
threshold equality, equal peaks, overlapping and singleton bands, gaps/continuous
input, high-bit/reversed/empty invalid bands, invalid lengths and captured metadata.
Reset tests cancel partial loading, registered arithmetic, pending output and then
verify recovery. The I/Q profile includes negative values, both signed minima,
and exact power/monitor output comparison. The oracle enumerates independent
Python list slices and direct sums, without copying the RTL pipeline schedule.

The first runner invocation failed to parse because two conditional expressions
lacked whitespace after `else`. Script execution never began: zero numerical
preparation and zero HDL children. The failed runner and observed shell error are
retained in `reports/authoring_python_parse_failure/`; only those two tokens were
fixed before the successful archived run. No production RTL or TB failure occurred.
This finite evidence does not prove all profiles, arbitrary stream resynchronization
or physical instrument performance.
