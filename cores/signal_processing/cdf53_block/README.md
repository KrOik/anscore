# CDF 5/3 integer block wavelet

`cdf53_block` implements a single-level reversible one-dimensional integer CDF
5/3 transform and its inverse. It adds adjacent-even prediction and
adjacent-detail update capability beyond the existing pairwise Haar2D core.
It is useful for lossless subband preprocessing and block reconstruction.
It is not a JPEG 2000 encoder, multilevel transform, or video frame engine.

The source is original Apache-2.0 RTL. See `SOURCES.md` for the pre-development
repository search, pinned references, license audit, and semantic comparison.

## Parameters and arithmetic

| Parameter | Legal values | Default |
| --- | --- | --- |
| `SAMPLE_W` | 2..24 | 16 |
| `BLOCK_LEN` | 1..256, odd or even | 16 |
| `INVERSE` | 0 forward, 1 inverse | 0 |

Illegal parameters instantiate a deliberately unresolved parameter-error module
and fail elaboration. The normal legal design has no such instance.

Both stream data ports carry signed two's-complement `SAMPLE_W+2`-bit integers,
with no fractional bits. Forward samples must be sign extensions of
`SAMPLE_W`-bit integers. Coefficients retain two guard bits; no quantization,
normalization, or truncation is applied to valid forward data. The internal
memory is signed `SAMPLE_W+5` bits, sufficient also for arithmetic on arbitrary
port-width inverse coefficients.

Split input into `e[i]=x[2i]` and `o[i]=x[2i+1]`. Forward computes:

```text
d[i] = o[i] - floor((e[i] + e[i+1]) / 2)
s[i] = e[i] + floor((d[i-1] + d[i] + 2) / 4)
output = [s[0], ..., s[ceil(N/2)-1], d[0], ..., d[floor(N/2)-1]]
```

Each missing opposite-parity neighbor repeats its closest available neighbor:
`e[last+1]=e[last]`, `d[-1]=d[0]`, and a missing rightmost detail repeats the
last detail. This is whole-sample symmetric extension for an even-origin
block. A one-sample block is unchanged. Arithmetic right shifts implement
floor for negative sums; they do not truncate toward zero.

Inverse inputs use the same packed `[low..., high...]` order. Inverse first
subtracts the update from low coefficients, then adds the prediction to high
coefficients, and emits natural sample order. Matching forward/inverse
parameters reconstruct every legal original integer sample exactly.

`m_error` is a block-wide sticky range flag, settled before the first output:
it is set for a forward input outside the sign-extended `SAMPLE_W` domain,
or any intermediate lifting result outside the signed port-width range.
Arbitrary inverse coefficients are accepted. A final result outside the port
width saturates to its signed minimum/maximum; the error flag is set. These
error cases do not promise reversibility. The flag clears on the first
accepted input of the next block. It is meaningful only with `m_valid`.

## Interface and scheduling

- All ports use the rising edge of `clk`. `rst` is synchronous active high,
  aborts a partially loaded/computed/draining block, clears control and
  output-valid state, and has priority over transfer. RAM content is not
  reset and is never read before a full subsequent block has loaded.
- There is no clock-enable input. Transfers use ordinary `valid && ready`
  semantics, with both ready/valid gated low during reset. A CE-qualified
  source needs an appropriate interface adapter.
- The producer must hold `s_valid` and `s_data` stable until accepted. Exactly
  `BLOCK_LEN` accepted input words form a block; no input last marker or
  runtime configuration is present. Parameters take effect at elaboration.
- Loading accepts one word per cycle. The core then deasserts `s_ready`
  throughout computation and output. Blocks never overlap within one core.
  Output order is preserved within each block.
- `m_data`, `m_last`, and `m_error` stay stable whenever `m_valid && !m_ready`.
  `m_last` marks the final output word. The next block can start on the edge
  after the last output transfers. Reset can cancel a pending output.
- For `N>=2`, each of the N lifting updates takes five clocks. After the last
  input edge, first output-valid asserts after `5*N+2` clocks, and the first
  output can transfer one edge later. For N=1 those numbers are 2 and 3.
  With ready always high, output transfers are three clocks apart. With no
  input gaps, successive block first-input edges are `9*N` clocks apart for
  N>=2, and four clocks apart for N=1. Backpressure extends completion time.
- There is no external memory interface or address/error protocol. Internal
  memory has one synchronous read and one synchronous write port, each with
  at most one access per cycle. Scheduling makes read and write mutually
  exclusive, so no same-address collision behavior is required. Input/output
  parity permutation only changes internal addresses.

## Offline use and example

From this package directory, compile the complete core with:

```text
iverilog -g2012 -Wall -tnull -s cdf53_block -f files.f
```

`files.f` contains the one production source. No include files, ROMs,
coefficients, generated RTL, external IP, vendor primitives, or downloaded
software are needed. `examples/cdf53_roundtrip.sv` connects matching 16-point
forward/inverse cores using standard ready/valid. Its source supplies valid
signed16 samples, so the forward range flag cannot assert. The example exposes
the inverse flag and signed18 reconstructed sample output. Its upstream and
downstream must honor the contracts above.

## Architecture review and evidence

Risk: **LOW** at defaults; **MEDIUM** for maximum parameters until mapped.
The sequential schedule has no multipliers/dividers and avoids an unrolled
transform network. Memory is `BLOCK_LEN*(SAMPLE_W+5)` logical bits: 336 bits at
defaults, at most 7,424 bits in the supported domain. One synchronous read
port and one write port permit RAM inference; actual mapping, BRAM granularity,
and target fit remain unmeasured. The expected combinational arithmetic path
is neighbor add, fixed shift, and center add/subtract. Storage grows linearly
with block length. There are no CDC structures, external RAM, or vendor hard
cores. These are architectural judgments, not measured PPA.

Run finite checks from the repository root:

```text
python -B cores/signal_processing/cdf53_block/check.py
```

The runner uses Icarus from PATH, preferring the repository's local OSS CAD
Suite when installed. Every tool subprocess has a 15-second timeout. It
uses a task-specific temporary directory and removes its generated memory
files and simulation executables on exit. Only `verification.json` is kept.
Python 3 and Icarus are development tools, not runtime RTL dependencies.

`verification.json` records the actual check results and source hashes.
The numerical reference uses separate low/high Python lists and unbounded
integer arithmetic, rather than the RTL's memory-access/state schedule.
Finite coverage includes 18 forward/inverse configurations over lengths
1/2/3/5/7/16/17/256, widths 2/3/8/16/24, signed extrema, negative-floor cases,
seeded vectors, out-of-range samples/coefficients, saturation, input gaps,
output stalls/stability, last markers, and reset during load/computation and
stalled output. Five illegal parameter settings are rejected. A separate
64-sample RTL forward-to-inverse connection checks reconstruction and stalls.
These are limited unit tests, not exhaustive verification.

Maturity after the recorded checks: **LINT_PASS**, **UNIT_SIM_PASS**;
the connection example remains an **INTEGRATION_CANDIDATE** and all current
RTL is **HW_UNVERIFIED**. Synthesis, PnR, STA, full regression and hardware
tests were not run. No historical hardware evidence is claimed for this core.
