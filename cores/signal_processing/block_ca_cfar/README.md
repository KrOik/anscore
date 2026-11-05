# Framed cell-averaging CFAR

`block_ca_cfar` implements local noise-adaptive detection on an unsigned power
frame. Each complete training window contains `TRAINING` samples on each side
of a cell under test, separated by `GUARD` excluded samples on each side.
It returns every input cell, its index, eligibility, reference sum and decision.
Cells without a complete window are ineligible; their decision and sum are zero.
There is no edge zero padding or wraparound.

This adds local detection to the existing spectrum `peak_search` (one block
maximum). It is different from `goertzel_bank` (frequency estimation), histogram
ranking and running global moments. Semantic searches of production RTL and
README files found no existing CFAR detector. Existing assets are unchanged.

Current status: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED** for the finite
configurations below. Icarus syntax checking is the LINT_PASS evidence; no
Verilator lint, synthesis, PnR, STA, board execution or PPA measurement occurred.

## Numeric contract

Input power is an unsigned integer of `DATA_W` bits, with every bit pattern legal.
Users may interpret all samples with one common fixed-point scale; it cancels
from the comparison. No amplitude squaring, logarithm, dB conversion or
probability calibration is performed. Select the rational threshold multiplier
at command time as `alpha_num / alpha_den`, with denominator strictly positive.
For an eligible cell `i`, with `K=2*TRAINING` and training sum `S`:

```text
detect = (sample[i] * alpha_den * K > S * alpha_num)
```

The strict comparison rejects equality. Numerator zero is legal: precisely
positive eligible samples detect. The mean is never rounded or divided.
`m_noise_sum` has `DATA_W + ceil(log2(K))` bits, enough for
`K*(2^DATA_W-1)`. All threshold products are retained exactly; the comparison
width is that sum width plus `ALPHA_W+1`. There is no saturation, sentinel,
tolerance, signed reinterpretation or numerical overflow in the supported domain.
The caller chooses alpha appropriate to its power/noise model; this module makes
no measured or universal false-alarm-rate claim.

## Parameters

| Parameter | Supported range | Default |
| --- | --- | --- |
| MAX_SAMPLES | 1..1024 | 256 |
| DATA_W | 1..32 | 16 |
| TRAINING | 1..16, on each side | 4 |
| GUARD | 0..16, on each side | 2 |
| ALPHA_W | 1..16 | 16 |
| TAG_W | 1..32 | 8 |

Unsupported settings fail elaboration through a named missing-module guard.
`MAX_SAMPLES=1` and configurations too short for an eligible cell are legal:
all cells are returned as ineligible. Window sizes are elaboration parameters.

## Interface and transaction ownership

All ports share rising-edge `clk`. `rst_n` is asynchronous active-low control
reset. It aborts commands, partial loads, calculation and pending output, and
clears all externally valid status. Payload RAM is not reset. After reset the
next accepted command must load all its own samples before any RAM word is read.
There is no CE, generated clock or CDC.

| Ports | Width | Meaning |
| --- | --- | --- |
| c_valid / c_ready | 1 each | Command transfers on both high |
| c_length | 32 | Full-width unsigned frame length, checked before narrowing |
| c_alpha_num / c_alpha_den | ALPHA_W each | Exact unsigned multiplier ratio |
| c_tag | TAG_W | Opaque tag echoed on every result |
| s_valid / s_ready | 1 each | Sample transfers on both high |
| s_data | DATA_W | Unsigned power sample, ascending frame order |
| m_valid / m_ready | 1 each | Result transfers on both high |
| m_index | 32 | Zero-based input cell index |
| m_sample | DATA_W | Original cell value |
| m_noise_sum | DATA_W+clog2(2*TRAINING) | Complete training sum, zero for edges/error |
| m_eligible / m_detect | 1 each | Complete window and strict threshold result |
| m_last | 1 | Final result of this transaction |
| m_error | 1 | Invalid command marker |
| m_tag | TAG_W | Captured command tag |

One accepted command owns the service through retirement of its final output.
All command configuration is sampled only at its handshake. Command fields can
change afterward. `c_ready` is low during loading, calculation and output; there
is no same-edge retirement/command fallthrough. Producers hold every input field
stable while valid is high and ready is low. The complete output bundle and
`m_valid` remain stable under arbitrary backpressure. Sinks may stall indefinitely.

A valid command has `1 <= c_length <= MAX_SAMPLES` and nonzero denominator.
Then exactly `c_length` input handshakes form the frame; there is no input last
signal and there are no samples accepted on the command edge. `s_ready` is high
only while that many samples are being loaded. Input may pause arbitrarily.
Exactly that many indexed results follow, and only the last has `m_last=1`.
Input samples are not accepted during processing or output.

An invalid command produces one `m_error=1, m_last=1` marker with echoed tag.
Its index, sample, sum, eligibility and detection are zero. No input samples are
accepted for it. A 32-bit length with high bits set is rejected rather than
aliased to an internal address. A command is never partially installed on error.
There are no external memory ports or memory errors.

## Architecture and latency

A bounded single-port synchronous RAM stores `MAX_SAMPLES*DATA_W` bits. Each
read has one clock of latency and a separate consume state; loads and reads
never overlap. After fetching a cell, the core serially visits `2*TRAINING`
reference addresses and accumulates one unsigned sum. Two separately registered
products form the threshold comparison; this chooses bounded small-frame work
over parallel training reads and a large adder tree. Two multiplier operators
exist, plus a constant `2*TRAINING` scale; source-level reuse does not imply a
single shared DSP. No vendor primitives, ROM, generator or external dependency
is required.

Loading can accept one sample each clock. The first edge-cell result becomes
valid two clocks after the final sample is accepted. Following a result's
retirement, the next edge-cell result becomes valid two clocks later; an
eligible-cell result takes `4*TRAINING+4` clocks. A result can retire on the
following clock when ready is already high. Computation pauses while a result
is held. Thus arbitrary input/output stalls prevent an unconditional transaction
deadline; the quoted counts concern internal work only.

Qualitative architecture risk is **MEDIUM**. Default payload storage is 4096
bits and the maximum is 32768 bits; the synchronous port avoids multi-read
replication and no payload array reset is needed. RAM inference, exact DSP
mapping and achievable frequency are unmeasured. Two products and a constant
scale may be the critical combinational paths. Fixed bounded linear window
work avoids quadratic hardware growth; maximum runtime is O(length*TRAINING).
No default-device fit, power or throughput measurement is claimed.

## Offline use and finite checks

Resolve both `files.f` and `example/files.f` from this package root. The example
`cfar_power_frame` exposes every default port and can connect to an unsigned
power producer and ordinary ready/valid sink. It does not directly adapt legacy
CE-qualified ANSCORE streams. `rtl/block_ca_cfar.sv` is the complete production
dependency closure. The source is independently authored Apache-2.0; see
`SOURCES.md` for read-only prior-art review.

```text
python run_tests.py
```

The standard-library runner locates the repository OSS CAD Suite by absolute
path and prepends its bin/lib directories, avoiding unrelated PATH shims. Each
child has a 20-second watchdog with process-tree termination on timeout.
It saves exact commands, source/tool hashes, status and raw stdout/stderr in
timestamped `reports/` directories. Executable simulation images are temporary
and are not delivery dependencies. A missing tool or timeout is not a PASS.

Current successful evidence is `reports/20261105T164418_476167Z/results.json`:
two syntax compilations, four TB compilations and four finite simulations.

| MAX_SAMPLES | DATA_W | TRAINING | GUARD | ALPHA_W | Checked cells |
| --- | --- | --- | --- | --- | --- |
| 64 | 8 | 2 | 1 | 8 | 462 |
| 1 | 1 | 1 | 0 | 1 | 8 |
| 17 | 32 | 3 | 0 | 16 | 133 |
| 70 | 16 | 16 | 16 | 16 | 620 |

The TB independently enumerates absolute sample positions and distances instead
of copying the RTL address sequence. It checks 1223 cell records, 3717 deliberately
stalled cycles including error markers, 16 rejected commands and 16 reset
scenarios. Cases include equality, central impulse, zeros, full-width extremes,
zero numerator, nonpower-of-two depth, the smallest legal widths, incomplete
windows, one eligible cell, input gaps, configuration mutation, partial-load
reset, read-phase reset and held-output cancellation.

The first run's N=1/ALPHA_W=1 TB watchdog is retained in
`reports/20261105T164057_080416Z/`, together with failed source copies. Its final
TB denominator literal 2 truncated to zero, so the correct invalid-command
response made the TB wait for input readiness. The TB now chooses denominator
1 at that width. Production RTL did not change. The initial three other
simulations passed. Later simulation evidence applies to the corrected TB;
the original failure is not relabeled. Icarus TB compilation emits only the
time-unit/precision diagnostic for the production module; production syntax
checks are diagnostic-free.
