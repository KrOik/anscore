# Integer 2x2 linear-system solver

`linear_solve2x2` solves two simultaneous equations with arbitrary signed
integer coefficients and emits two signed fixed-point answers:

```text
a00*x + a01*y = b0
a10*x + a11*y = b1
```

It supplies a reusable numeric solve primitive for small estimation,
calibration and control datapaths. The existing GF(2) solver operates in a
different field. Existing optical-flow and affine packages contain specialized
internal solves, but do not expose this arbitrary integer matrix command and
fixed-point result contract. No existing module was modified.

## Numerical contract

All six input values are signed W-bit two's-complement integers. The full
signed input domain, including its minimum negative value, is supported.
For each accepted command the core computes, without intermediate rounding:

```text
det = a00*a11 - a01*a10
nx  = b0*a11 - a01*b1
ny  = a00*b1 - b0*a10
raw_x = trunc_toward_zero(nx * 2^FRAC / det)
raw_y = trunc_toward_zero(ny * 2^FRAC / det)
```

The output real values are `m_x/2^FRAC` and `m_y/2^FRAC`. `m_x` and `m_y`
have signed `RESULT_W` bits. Each raw integer result outside that signed range
is saturated to its minimum/maximum, setting `m_saturated[0]` for x and bit 1
for y. An exact minimum negative result is representable and does not set the
flag. In-range output quantization error is strictly below one output LSB;
there is no promise of a small error when saturation occurs. No intermediate
coefficient scaling, floating-point arithmetic or approximation is used.

`m_determinant` carries the exact signed `2*W+1`-bit determinant. If it is
zero, `m_singular=1`, both answers are zero, and both saturation flags are
zero. This reports absence of a unique solution; it does not distinguish
inconsistent and underdetermined systems. A nonzero determinant, however
small, is solved using exact integer arithmetic before final quantization.
There is no near-singular threshold, and division by zero is never started.

| Parameter | Default | Legal range |
| --- | ---: | --- |
| `W` | 16 | 2..24 |
| `FRAC` | 16 | 0..24 |
| `RESULT_W` | 32 | 2..64 |
| `TAG_W` | 8 | 1..32 |

`FRAC` may exceed `RESULT_W-1`; this defines a small representable real range
and can therefore cause saturation for ordinary solutions. It is not an
illegal configuration. Invalid parameters fail elaboration through a
deliberately unresolved parameter-error instance. Legal configurations have
no such instance. Configuration is entirely by elaboration parameters.

## Clock, handshake and transaction behavior

- All ports use one rising-edge `clk`. `rst` is synchronous active high and
  has priority over work. Assert it across a rising edge to cancel an active
  command, arithmetic or pending result. The visible result registers and
  valid state clear; unreset arithmetic scratch registers are initialized
  by their setup states before every subsequent use.
- There is no CE input or CDC. `s_ready` and `m_valid` are suppressed while
  reset is asserted. Input and output transfers use ordinary `valid && ready`
  semantics, without an additional enable qualifier.
- A command transfer captures all six coefficients and `s_tag` together.
  The producer holds every field stable until that transfer. Each command
  is one independent transaction, with no frame/packet boundary markers.
  `m_tag` echoes the captured tag. There is no configuration-update race.
- The core deasserts `s_ready` throughout calculation and pending output.
  It accepts no overlapping command and preserves transaction order.
  `m_x`, `m_y`, `m_determinant`, `m_singular`, `m_saturated` and `m_tag`
  remain stable whenever `m_valid && !m_ready`.
- The result may be held indefinitely under backpressure. A new command can
  transfer on the edge after the old result transfers. Reset can cancel an
  unconsumed result. There is no external memory interface, address protocol,
  bus error response or external storage dependency.

The example `example/solve_calibration2x2.sv` is a minimal complete
instantiation at the defaults. Its coefficient names correspond directly to
the equations above; both command and result ends use ordinary ready/valid.
It exposes singular/saturation status and ties the unused transaction tag to
zero. The core's exact determinant output is available to callers needing it.

## Architecture and finite-cycle service

Six signed products share one iterative shift/add engine: W iterations and
one setup clock each. Products are accumulated as unsigned full-width
magnitudes, with a separate sign. Their signed differences use `PW=2*W+1`
bits, preserving determinants and Cramer's numerators without wraparound.
The most-negative W-bit value is converted to an unsigned magnitude, which
requires no extra multiplier-input bit. No hardware `*` or `/` operator is
present in the production datapath.

Two divisions share one restoring divider. It consumes `DW=PW+FRAC` dividend
bits and retains `PW+1` remainder bits. The full absolute numerator is shifted
into the `DW`-bit dividend before division. Quotients are compared at
`max(DW,RESULT_W)` width against signed-output magnitude limits before sign
restoration and saturation. Thus changing output width cannot silently discard
overflow bits. Fixed storage and one shared engine avoid a combinational
matrix-inverse network or parallel divider bank.

Measured from a command acceptance edge, a nonsingular result becomes valid
after `6*(W+1) + 2*(DW+1)` clock periods; the default is 202. A singular result
becomes valid after `2*(W+1)` periods; the default is 34. Earliest output
transfer is on the following edge. If the sink is always ready, command-start
spacing is respectively two periods longer than those valid latencies. Sink
stalls extend completion time. These are FSM scheduling properties, not
hardware frequency or sustained-throughput measurements.

Qualitative resource risk is **LOW** at default settings and **MEDIUM** at
the maximum width profile. There are no arrays, BRAMs, vendor primitives,
vendor-specific attributes or external RAMs. Storage and arithmetic widths
grow linearly with W, FRAC, RESULT_W and TAG_W. The longest expected arithmetic
paths are a 2W-bit add in the multiply engine and a PW+1-bit compare/subtract
in the divider. Actual LUT/FF mapping, routing, frequency, device fit and
power have not been measured; no zero-DSP or timing-closure claim is made.

## Offline dependency closure and verification

`files.f` lists the sole production source, relative to this directory.
There are no includes, generated code, coefficient tables, ROM initialization
files, third-party IP or download requirements. The original code uses the
repository Apache-2.0 license; see `SOURCES.md` for the predevelopment search
and license record. Package-local `.gitattributes` fixes every text file to LF
so Git blobs and checked source hashes use the same bytes.

Compile from this package directory:

```text
iverilog -g2012 -Wall -tnull -s linear_solve2x2 -f files.f
```

Run the finite checks from the repository root:

```text
python -B cores/signal_processing/linear_solve2x2/run_tests.py
```

The runner requires Python 3 and Icarus Verilog/vvp. It prefers the existing
local OSS CAD Suite and adds its bin/lib directories to subprocess PATH;
otherwise it uses PATH tools. Each subprocess is limited to 15 seconds.
Generated TB text and simulator executables use a task-specific temporary
directory that is removed on exit. The deterministic TB source template is
retained in `run_tests.py`, so no vectors or generated artifacts are needed
for reproduction. Non-LF source files are rejected before checks begin.

The numerical oracle uses exact `Fraction` Gaussian elimination with row
pivoting, followed by output quantization/saturation. It does not implement
the RTL's Cramer's numerators or shift/add schedule. Every oracle solution is
also substituted into the original pair of equations before quantization.
Six profiles cover W/FRAC/RESULT_W/TAG_W values
`2/0/4/1`, `3/4/8/3`, `8/8/16/8`, `16/16/32/8`,
`24/24/32/32` and `8/0/64/8`. They exercise 168 commands including identity,
row swaps, negative determinants, exact det=+/-1, rank-deficient systems,
minimum negative products, signed output limits, saturation, and seeded random
matrices. Tests verify four-cycle sink stalls, source gaps/blocked commands,
captured fields and tags, reset during multiplication/division/pending output,
and replay without reset. Seven invalid parameter settings are rejected.
Compilation includes the minimal example. The 24/24/32/32 profile uses maximum
input/fraction/tag widths; output width 64 is separately simulated. These are
finite tests, not exhaustive verification over all matrices/parameter tuples.

Current evidence is recorded in `verification.json`, including tool version,
commands/outputs and SHA256 hashes. Maturity is **LINT_PASS + UNIT_SIM_PASS**;
the example is an **INTEGRATION_CANDIDATE**, and all new RTL is
**HW_UNVERIFIED**. No synthesis, PnR, STA, hardware testing or full regression
was performed, and no historical board evidence is claimed.
