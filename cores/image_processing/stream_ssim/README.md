# Streaming block SSIM

`stream_ssim` calculates a signed structural similarity score for one supplied
block of paired grayscale samples. Its new capability is a complete on-FPGA
SSIM score, including exact rational stabilization constants and division.
Repository searches found generic cross moments and spatial moments, but no
SSIM scoring core. Existing CCA, projections, LBP and distance transforms were
excluded as duplicate development directions. No existing RTL was modified.

This block uses uniform weights and **population** covariance on the selected
samples. It does not form sliding windows, Gaussian weights, a full-frame
average of window scores, or multiscale SSIM. A caller can supply an 8x8 block,
any shorter block, or an arbitrary set of paired samples and a mask.

## Numerical contract

Let `N` be selected samples, `L=2^BITS-1`, `ux,uy` their means, and `vx,vy,vxy`
their population variances and covariance. The exact real target is

```text
C1 = L^2 / 10000                  C2 = 9*L^2 / 10000
S = ((2*ux*uy+C1)*(2*vxy+C2)) / ((ux^2+uy^2+C1)*(vx+vy+C2))
m_score = trunc_toward_zero(S * 2^Q_BITS)
```

Pixels are unsigned integers. The score is signed with `Q_BITS` fractional
bits and total width `Q_BITS+2`; Q15 therefore uses **17 bits** so that +1 is
represented exactly as 32768. Negative correlation may yield negative scores.
No intermediate rounding is performed. The final quantization error is below
one output LSB, except exact integer scores have zero error. For nonempty
blocks `-1 <= S <= +1`, and the positive constants prevent zero denominators.
An all-zero pair of blocks scores exactly +1. There is no tolerance-based
acceptance or undocumented clipping.

The implementation clears the common `N^2*10000` denominator algebraically:

```text
A = 20000*Sx*Sy + L^2*N^2
B = 20000*(N*Sxy-Sx*Sy) + 9*L^2*N^2
C = 10000*(Sx^2+Sy^2) + L^2*N^2
D = 10000*(N*(Sxx+Syy)-Sx^2-Sy^2) + 9*L^2*N^2
S = A*B/(C*D)
```

These integer expressions are the same formula, including for a single
sample. The independent test reference forms `Fraction` means and centered
variances directly rather than reusing these cleared-denominator equations.

## Interfaces and parameters

All signals use one rising-edge `clk`. `rst` is synchronous active-high and
overrides all work; assert it across a rising edge. It discards partial blocks,
active arithmetic and pending results. Ready and valid are both suppressed
while reset is asserted. There is no clock-enable port and no CDC.

Input transfer is `s_valid && s_ready`; all pair fields, mask, tag and last
belong to that transfer. The producer must hold them stable until accepted.
`s_last=1` marks the final supplied pair of a block. No coordinate, SOF or EOL
marker is required: the caller defines block membership and sample pairing.
`s_mask=0` excludes the pair from every statistic but does not suppress the
block boundary. `s_tag` is sampled on the first accepted pair, including an
excluded pair; later tag changes are ignored for that block.

The core admits at most `MAX_SAMPLES` selected pairs. Further selected pairs
set `m_overflow=1` and are drained through `s_last`, without changing the
prefix statistics or count. The returned score is explicitly the selected
prefix score, not a whole-block estimate. Excluded pairs do not cause overflow.
If no samples are selected, `m_empty=1`, `m_count=0`, and `m_score=0`.

Output transfer is `m_valid && m_ready`; there is one result per block, with
`m_score`, `m_count`, `m_empty`, `m_overflow`, and `m_tag` held stable under
backpressure. A single result implicitly ends the transaction; there is no
separate output last flag. No new block is accepted until this result is
consumed. A missing input last leaves the current transaction open; use reset
to abort. There is no external memory or register bus and no bus error response.
Configuration consists only of elaboration parameters; no runtime update race
exists.

| Parameter | Default | Legal range / meaning |
|---|---:|---|
| BITS | 8 | 1..12, unsigned grayscale width; full-scale data range |
| MAX_SAMPLES | 64 | 1..4096, selected-pair prefix capacity |
| Q_BITS | 15 | 1..24, score fractional bits |
| TAG_W | 8 | 1..32, uninterpreted block tag width |

Derived localparams are internal and must not be overridden. Simulation-only
parameter guards reject invalid public parameters. There are no ROMs, generated
tables, third-party includes, packages or runtime files.

## Architecture and timing in clock cycles

A selected pair takes its acceptance cycle and three product accumulation
cycles. Consecutive selected pair accepts therefore have an interval of four
clocks. Excluded and excess pairs can be drained every clock. One BITS-by-BITS
multiplier is explicitly shared across x*x, y*y and x*y. Exact sums have widths
`CW=clog2(MAX_SAMPLES+1)`, `SW=BITS+CW` and `PW=2*BITS+CW`, sufficient for the
full legal prefix including the count maximum.

Eight moment/constant products and two final products share a shift/add engine
of input width `MW=2*SW+18`. Every product takes `MW` iterations plus one setup
clock. A restoring divider processes `DW=2*MW+Q_BITS` bits. There is one
additional block-end clock, one formula clock and one divide-setup clock.
After an accepted final **selected** pair, valid rises after
`6 + 10*(MW+1) + DW` clock periods; the default is 607 clocks. After an
excluded/excess final pair with a nonempty prefix it is three periods shorter.
An empty result becomes valid one period after the final pair. Sink stalls
extend completion by their duration. These are RTL scheduling properties, not
measured clock-frequency or hardware-throughput claims.

Structural resource risk is **MEDIUM**, a qualitative review: storage is fixed
register state, with no frame or line RAM and no external storage dependency.
Wide iterative arithmetic trades latency for one shared adder/shift datapath;
the small pixel multiplier may map to DSP or logic. Constant factors 10000,
20000 and 9 create combinational constant arithmetic, whose timing is
unmeasured. Width grows linearly with BITS, log(MAX_SAMPLES) and Q_BITS, rather
than with block area. Vendor primitives and vendor attributes are absent.
Default storage and arithmetic are plausibly moderate for the project target,
but no LUT/FF/DSP count, timing closure or device-fit result is claimed.

## Offline use and verification

`files.f` lists the entire synthesizable dependency closure relative to this
directory. `example/ssim_block_example.sv` shows a minimal paired-stream
connection for blocks of at most 64 pixels. Both upstream pixels must already
be aligned to the same pair acceptance event.

```powershell
python -B cores/image_processing/stream_ssim/run_tests.py
```

The runner uses only Python's standard library and Icarus Verilog/vvp. It
prefers the repository's existing OSS CAD Suite, adds its DLL directories to
the subprocess PATH, and otherwise uses PATH tools. Each compiler or simulator
process has a strict 20-second timeout. Temporary testbench sources and simulator
binaries are isolated in a task-specific temporary directory and removed after
the check. The generated deterministic testbench is retained as the source
template inside `run_tests.py`; no external vectors are needed.

Current state: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**.
`verification.json` binds source SHA256 to the actual commands and outputs.
Three profiles (1-bit/capacity1/Q3, 8-bit/capacity64/Q15,
12-bit/capacity5/Q12) cover 66 blocks in total: identical inputs, zero and
full-scale constants, opposite constants, negative correlation, random pairs,
masks, empty blocks, capacity boundary and prefix overflow. Testbenches also
check output holding under five-cycle stalls, source gaps, blocked input,
transaction tags, reset during capture/arithmetic/pending result, and replay
without reset. The maximum public parameter profile 12/4096/Q24/tag32 is
compiled without simulation. BITS=13, MAX_SAMPLES=4097, Q_BITS=25 and TAG_W=33
are separately rejected by the runtime guard. The full limited suite passed on
2026-11-04. No synthesis,
placement, routing, STA, board testing or full regression was run.

## Source and license

All local RTL, example and test code are independently written under the
repository Apache-2.0 license. No external source was copied or adapted; no
third-party runtime dependency is required. Read-only predevelopment search
and formula comparison examined [scikit-image v0.24.0 structural similarity](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/skimage/metrics/_structural_similarity.py).
The fixed commit is `a160f384523ac70173d069954b7084bee79fb68e`; tag-object SHA
is `8be71b82137046719f8e0f70632745f883d72586`. Its
[LICENSE.txt](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/LICENSE.txt)
declares the default files copyright 2009-2022 the scikit-image team,
BSD-3-Clause, with specific exceptions for other named files. The inspected
metrics file is covered by the default BSD-3-Clause entry. The GitHub license
classifier reports NOASSERTION for this mixed-license file; the actual text,
rather than that classifier, was reviewed. No license-bearing upstream file is
redistributed here.

The compared source confirms K1=0.01, K2=0.03 and optional population covariance;
its default sliding-window average and default sample covariance differ from
this explicitly uniform supplied-block contract. No bit-equivalence to a
default `skimage.metrics.structural_similarity` invocation is claimed. Search
service failures were bypassed with read-only GitHub API retrieval; no remote
scripts, installation commands or upstream build systems were executed.
