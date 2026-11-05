# Discrete occupied spectral bandwidth

`occupied_spectral_bandwidth` finds an equal-tail power interval in an ordered
unsigned spectrum. A runtime retained-power ratio selects the first and last
included bins, their inclusive span, total/retained power, and both discarded
tails. For example, `99/100` requests a discrete 99% occupied-power interval.
This is a frequency-domain instrument after FFT/power or Welch averaging.
It adds inverse cumulative-power boundaries beyond the existing fixed-band
statistics, global peak finder and CA-CFAR detector. Those existing assets are
unchanged; see `SOURCES.md` for the semantic review.

Status: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED** for the finite profiles
below. LINT_PASS means Icarus syntax checking. No synthesis, PnR, STA, device-fit,
board test, hardware frequency, power or PPA measurement was performed.

## Exact discrete definition

For `n` unsigned powers `P[0..n-1]`, let `T=sum(P)` and
`C[k]=sum(P[0..k])`. Capture a ratio `a/b`, with `1 <= a <= b <= 65535`.
For `T>0`, return:

```text
low  = first k with 2*b*C[k] >  (b-a)*T
high = first k with 2*b*C[k] >= (b+a)*T
span = high-low+1
below    = sum(P[0..low-1])
retained = sum(P[low..high])
above    = sum(P[high+1..n-1])
```

The lower comparison is **strict**, and the upper comparison is **inclusive**.
No fraction or average is rounded. Each excluded tail is at most
`(b-a)/(2*b)` of the total; the retained interval therefore contains at least
`a/b` of the power. Whole-bin quantization can retain more than requested.
This is an equal-tail interval, rather than a shortest contiguous interval.

- `[1,1,1,1]` at `1/2` gives `low=1, high=2, span=2`, with each tail equal to 1.
  The first cumulative value equals the lower target and is skipped.
- A zero-tail request is `a=b` (100%). Leading and trailing zero bins are
  excluded: `[0,0,7,0,0]` gives `low=high=2, span=1`.
- Any positive single-bin spectrum gives `low=high=0, span=1`.
- Internal zero plateaus remain in the selected interval. At an upper-target
  equality, the first bin reaching that target wins, excluding later zero bins.
- An all-zero spectrum consumes all `n` inputs and returns `NO_POWER`, with
  zero indices/span/energies. It has no defined occupied-power interval.
- A zero retained-power numerator is invalid, distinct from a valid zero-tail
  request. Bad length takes precedence over bad ratio.

Every input bit pattern is legal unsigned power. A common fixed-point scale or
common equal-width PSD bin factor cancels from these ratios. Inputs must be in
ascending physical-frequency order. Reorder an unshifted FFT's wrapped
negative/positive bins before measurement. The module does not compute an FFT,
calibrate a spectrum, weight unequal bins, remove DC/noise, interpolate bin
edges, convert to dB, or perform trapezoidal PSD integration.

`m_span` counts included bins. If their centers are `f0+k*df`, center-to-center
distance is `(high-low)*df`; an enclosing whole-bin edge convention instead
uses `f0+(low-0.5)*df` through `f0+(high+0.5)*df`, of width `span*df`. The caller
chooses valid origin/spacing/edge conventions. No Hz value is produced here.
This discrete instrument has no regulatory measurement or certification claim.

## Parameters and widths

| Parameter | Supported range | Default |
| --- | --- | --- |
| MAX_BINS | 1..4096 | 1024 |
| DATA_W | 1..32, unsigned power bits | 32 |
| TAG_W | 1..32 | 8 |

An unsupported static parameter invokes a named missing-module elaboration
guard. Internal index width is `max(1,clog2(MAX_BINS))`, and length width is
`clog2(MAX_BINS+1)`. `SUM_W=DATA_W+ceil(log2(MAX_BINS))`, treating the increment
as zero for `MAX_BINS=1`. The sum fits exactly even for every maximum input:
default 42 bits, maximum configuration 44 bits, and 1-bin/1-bit profile 1 bit.

The shared multiplier has `SUM_W` and 17-bit unsigned operands. Its exact product
width is `SUM_W+17` (default 59, maximum 61 bits). Both `b+a` and `2*b` fit 17
bits; all targets and prefix products are retained at this width. No division,
saturation, truncation of arithmetic results, floating point or sentinel power
is used. `total=below+retained+above` exactly for successful responses.

## Interface and ownership

All ports share rising-edge `clk`. `rst` is synchronous active-high, dominates
transfers and cancels any partial frame, calculation or held response. Ready and
valid outputs are gated low while reset is high. Payload RAM is not reset; a
fresh command must capture its full frame before any read. There is no CE, abort
port, asynchronous frontend or CDC. A producer holds its full input bundle while
valid is high and ready is low.

| Ports | Width | Meaning |
| --- | --- | --- |
| c_valid / c_ready | 1 each | Command transfers when both high |
| c_bins | 32 | Unsigned length, validated at full width before narrowing |
| c_occupied_num / c_occupied_den | 16 each | Captured retained-power ratio a/b |
| c_tag | TAG_W | Captured opaque tag |
| s_valid / s_ready | 1 each | Power transfers when both high |
| s_power | DATA_W | Unsigned power, implicit bin order 0..n-1 |
| m_valid / m_ready | 1 each | One response per command; transfer ends ownership |
| m_status | 2 | 0 OK, 1 BAD_LENGTH, 2 BAD_RATIO, 3 NO_POWER |
| m_low / m_high | 32 each | Selected zero-based inclusive bin indices |
| m_span | 32 | Number of included bins |
| m_total / m_retained / m_below / m_above | SUM_W each | Exact power sums |
| m_tag | TAG_W | Captured command tag |

A valid command has `1 <= c_bins <= MAX_BINS` and `1 <= num <= den`.
It accepts exactly that many powers, then returns one response. There is no
input index/last signal. The command edge accepts no sample. Live command
changes afterward have no effect. Invalid commands return one zero-statistics
response and admit no input data. All response fields and valid stay stable
under arbitrary output backpressure. Sinks may stall indefinitely.

Only one command owns the instrument through response retirement. No input or
command is accepted during computation/output, and there is no same-edge
response-retirement/command fallthrough. Response payload has meaning only
while `m_valid` is high.

## Architecture, cycle budget and storage

Capture is one accepted power per clock when available. The input RAM holds
`MAX_BINS*DATA_W` bits: default 4 KiB, maximum 16 KiB. No RAM initialization file
or external memory is required. Reads are synchronous and occur only after all
addresses for the transaction are written; there is no same-edge read/write
collision. An early upper-bound crossing can stop replay before the final bin.

One registered multiplier is shared for two frame targets and then one CDF
comparison per replayed bin. Three target clocks prepare and retain both targets;
each replayed bin uses RAM read, prefix/product and comparison clocks. There is
no comparator sorting network, parallel bin bank or FFT duplicate.

For nonzero power with upper index `h`, the response first becomes visible
`6+3*h` clocks after the final power handshake. A zero-power response is visible
immediately after that handshake edge. Invalid-command responses are visible
immediately after their command edge. The earliest response handshake is the
following edge. These are no-stall RTL cycle counts, not hardware timing results.

With continuous input and an always-ready sink, earliest command-to-next-command
interval is `n+8+3*h`, at worst `4*n+5` clocks; an all-zero frame needs `n+2`.
Arbitrary producer gaps/output stalls extend service. This framed serial service
does not promise uninterrupted adjacent spectrum frames or unbuffered ADC input.

Architecture risk: **MEDIUM**, qualitatively. The widest supported setting needs
16 KiB of inferred RAM and a 44x17-bit multiplier plus 61-bit product/target
registers. RAM/DSP mapping, device fit and critical paths require later physical
work. No vendor primitive, allocation estimate or measured clock rate is claimed.

## Actual composed I/Q example

From this package root, `example/files.f` resolves the canonical existing
`../dsp_isp_library/dsp/spectrum/rtl/mag_squared.sv`, the new core and
`example/iq_occupied_bandwidth.sv`. The example fixes 1024 bins, 32-bit power,
8-bit tags, and preserves the whole command/response interface. `s_iq[15:0]` is
signed16 I and `[31:16]` is signed16 Q, representing ordered **complex spectral
bins** from an upstream transform. Direct time-domain I/Q needs an FFT first.

`mag_squared` is unchanged, configuration disabled, shift zero, reset `!rst`.
Its exact power is `I*I+Q*Q`, at most `2^31`. An explicit remaining-input counter
admits exactly `n` I/Q beats, despite the magnitude pipeline's in-flight entries.
Collection readiness blocks data for invalid commands. Every power entry is
consumed before a response/new command; reset cancels both components together.
The actual composed example is simulated, including both signed minima and
negative 3/4 components, rather than syntax-checked alone.

Without stalls, the last I/Q input reaches the core power handshake four clocks
later. Nonzero response visibility is therefore `10+3*h` clocks after the final
I/Q handshake (zero-power: four); worst command interval is `4*n+9` clocks.

## Finite evidence

`python -B run_tests.py` is optional offline validation from this package root.
It uses only Python standard library and the local OSS Icarus executables. It
archives exact executable-source bytes before numerical preparation, then all
four exact vector files before the first HDL child. Each child has a 20-second
deadline with bounded tree-kill/drain cleanup. Missing tools, failure, timeout or
missing exact completion prefix stops subsequent checks; there are no retries.

The one run in `reports/20261105T183407_933176Z/results.json` contains **10 PASS**:
two syntax checks, four TB compiles and four simulations. No failed/timed-out
attempt occurred. Profiles `(MAX_BINS,DATA_W,TAG_W,IQ)`:

| Profile | Checked responses | Accepted input beats | Commands | Held-output clocks | Resets | Exact latency checks |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,1,1,0 | 21 | 18 | 25 | 84 | 5 | 15 |
| 17,16,8,0 | 21 | 140 | 25 | 84 | 5 | 15 |
| 4096,32,32,0 | 21 | 12391 | 25 | 84 | 5 | 15 |
| 1024,32,8,1 | 21 | 3175 | 25 | 84 | 5 | 15 |

Totals are 84 responses, 15724 accepted inputs and 100 commands (including
cancelled reset setups), 336 held-output clocks, 20 reset scenarios and 60 exact
latency checks. Each profile has 11 valid frames, six invalid commands and four
post-reset recovery responses. Resets cancel partial capture, registered product,
RAM replay and held output. Fixtures cover exact CDF equalities, 100%/near-zero
ratios, leading/trailing/internal zeros, single-bin power, all-zero spectra,
maximum full-frame sums/products, arbitrary powers, continuous input and gaps,
high-bit bad lengths, ratio errors, captured-config mutation and backpressure.

The oracle uses Python `Fraction` CDF searches and independent direct slice sums.
It imports no SciPy or external runtime package. The four compile logs contain
only missing-timescale warnings for delay-free production modules. Raw logs,
source snapshots, exact vectors and SHA256 hashes are retained. `B35_DELIVERY.json`
bridges package files, current executable-source hashes and the canonical support
dependency. Four ignored VVPs are left for root-owned cleanup; they are not assets.
