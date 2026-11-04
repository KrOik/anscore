# Exact fixed-point eigenvalues of a symmetric 2x2 matrix

`symmetric_eigen2x2` accepts one signed-integer real symmetric matrix
`[a b; b d]` and returns its two eigenvalues in ascending numerical order,
with exact mathematical floor quantization followed by signed saturation.
It also returns exact positive-semidefinite and repeated-eigenvalue flags.
This supplies a runtime eigenproblem primitive for covariance, geometry and
small control matrices; no host-computed square root or eigenvalue is needed.

## Numerical contract and configuration

All three matrix entries are signed W-bit two's-complement **integers**. The
complete input domain, including minimum negative entries, is legal. Symmetry
is structural: both off-diagonal entries use `s_b`. There is no singular-input
error or positive-definiteness precondition; indefinite matrices are supported.
For each command, with `Q=2^FRAC`, the result before output saturation is:

```text
trace = a+d
D = (a-d)^2 + 4*b^2
lambda_min = (trace-sqrt(D))/2
lambda_max = (trace+sqrt(D))/2
raw_min = floor(Q*lambda_min)
raw_max = floor(Q*lambda_max)
```

`m_min/Q` and `m_max/Q` represent the returned real values. For each in-range
raw coefficient, output error is in `[0,1/Q)`, measured as true eigenvalue
minus reported value. This is **floor**, including for negative numbers, not
toward-zero or nearest rounding. There is no cancellation approximation or
small-negative threshold. A negative eigenvalue smaller in magnitude than one
LSB still yields a negative raw code.

Each raw value outside the signed `RESULT_W` range saturates independently;
`m_saturated[0]` marks the minimum and `[1]` the maximum. A value exactly at
the signed minimum or maximum is representable and does not clip. Saturation
invalidates the sub-LSB error bound but preserves `m_min<=m_max`. Flags are
transaction results, not sticky levels.

| Output | Exact meaning |
| --- | --- |
| `m_trace` | Signed W+1-bit `a+d` |
| `m_discriminant` | Unsigned 2W+1-bit D, without fractional scaling |
| `m_psd` | True iff the original matrix is positive semidefinite, including zero |
| `m_repeated` | True iff the actual eigenvalues coincide (`a=d` and `b=0`) |
| `m_tag` | Captured command tag |

PSD and repetition flags refer to the original matrix even if results clip.
Equal output codes caused by quantization or saturation do not imply repeated
eigenvalues. Exact floor preserves the sign test `lambda_min>=0` iff
`raw_min>=0`, so PSD is determined before clipping without an epsilon.

| Parameter | Default | Legal values |
| --- | ---: | --- |
| `W` | 16 | 2..24 |
| `FRAC` | 12 | 0..24 |
| `RESULT_W` | 32 | 2..64 |
| `TAG_W` | 8 | 1..32 |

`FRAC>RESULT_W-1` is legal and can cause saturation for ordinary eigenvalues.
All parameters are static; there are no runtime configuration registers.
Illegal parameters deliberately fail elaboration using an unresolved
`symmetric_eigen2x2_invalid_parameter__see_README` instance. The inherited
sqrt instance remains within its documented input/fraction/iteration bounds.

## Exact root adaptation and arithmetic ranges

The unchanged repository `fp_sqrt_iter` returns
`r=RNE(sqrt(D)*Q)` and a perfect-square flag. This package squares r with its
shared iterative multiplier and compares the complete square to `D*Q^2`.
Then `s=r-(r*r>D*Q^2)` is exactly the floor root, and `c=s+!exact` is the
ceiling root. For integer `T=trace*Q`, the implemented identities are:

```text
raw_min = (T-c) arithmetic_shift_right 1
raw_max = (T+s) arithmetic_shift_right 1
```

These equal the mathematical floors above: an irrational root lies strictly
between the adjacent integers s and c, and a half-integer numerator cannot
cross another integer boundary within that interval. Perfect squares use
`s=c` and are exact. The root is not rounded and directly substituted into
both eigenvalue formulas; that would misclassify some near-zero eigenvalues.

`abs(a-d)<=2^W-1`, `abs(b)<=2^(W-1)`, hence
`D < 2^(2W+1)`. Let `N=W+FRAC+1`. The scaled radicand has `2N-1` bits, and
the inherited square-root RNE result is safely below `2^N`; its extra output
carry bit is zero for the complete legal matrix domain. Three squares
(`abs(a-d)`, `abs(b)`, rounded root r) share one N-bit shift/add multiplier
with full 2N-bit products. The 2W+1-bit discriminant sum retains its possible
top carry. Minimum-negative b is converted to an unsigned W-bit magnitude.

Trace is sign-extended before scaling. Root floor/ceil are zero-extended into
signed `EW=N+2`-bit operands before trace addition/subtraction. Those operands
and intermediate sums fit EW; saturation comparisons sign-extend further to
`max(EW,RESULT_W)` before slicing. No intermediate overflow, saturation,
floating arithmetic, division or discarded product bits affect the result.

## Clock, transfers, reset and service

- All ports share rising-edge `clk`. `rst` is synchronous high; assert it
  across a rising edge to cancel a command, any arithmetic and a pending result.
  During reset, input-ready and output-valid are suppressed. There is no CE,
  CDC, packet boundary, external memory, bus error or partial-result protocol.
- Ordinary `s_valid && s_ready` captures a,b,d and tag together. The producer
  holds all fields stable until acceptance. One command is in flight; no new
  command is admitted during arithmetic or a pending output.
- `m_valid && m_ready` consumes a result. All output data and flags hold while
  valid and blocked. A new command can transfer on the edge after the result
  transfer. Output fields are unspecified when valid is low.
- Reset clears public results, valid state and the dependency's control.
  Scratch state is initialized by setup/capture states before every use. A
  canceled transaction needs caller replay. The dependency uses synchronous
  low reset through `!rst`, with matching edge and transfer gating semantics.

Each square uses one setup clock and N shift/add clocks. The inherited root
uses N digit clocks plus the controller's capture handoff. From input edge E,
valid appears after **`4*N+6`** periods for every input, including D=0; earliest
output transfer is E+4N+7. Default N=29 gives 122-period valid latency and
124-period no-stall command spacing. Output stalls extend completion, so no
unconditional deadline is promised. These are FSM schedules, not hardware
frequency, power or measured throughput claims.

The fully unrolled alternative would replicate squares/root stages to raise
throughput. The selected architecture shares one multiplier and the existing
iterative root because no per-clock transaction requirement was given. There
is no production hardware `*` or `/` in the new datapath. Only `fp_sqrt_iter`
is instantiated from the dependency file; its unused pipeline module is not
part of this datapath. No RAM arrays, BRAM, ROM, vendor primitives, external
storage or generated coefficient data are needed. Registers and arithmetic
grow linearly with W/FRAC/result/tag widths. The expected longest paths are
the 2N-bit multiplier accumulator add, sqrt compare/subtract and final signed
add/clamp. Qualitative resource risk is **LOW** by default and **MEDIUM** at
maximum widths (N=49, full candidate square 98 bits). Actual resources, mapping,
device fit, timing and power are unmeasured; the old arithmetic library's
historical checks do not qualify this composition.

## Files, example and finite evidence

Both `files.f` and `example/files.f` are interpreted relative to the package
root. They include the unchanged tracked
`../dsp_isp_library/infra/fixedpoint/rtl/sqrt_unit.sv`. The example additionally
instantiates defaults and exposes both coefficients, saturation, PSD/repetition
and tag; only exact trace/discriminant are discarded. No network or external
source generator is needed. Use from this package directory:

```text
iverilog -g2012 -Wall -tnull -s symmetric_eigen2x2 -f files.f
iverilog -g2012 -Wall -tnull -s eigen16_example -f example/files.f
```

From the repository root:

```text
python -B cores/signal_processing/symmetric_eigen2x2/run_tests.py
```

The runner uses Python's standard library and Icarus/vvp, preferring the local
OSS CAD Suite. Each subprocess has a 15-second limit. Temporary deterministic
vectors and executables use a task-specific directory and are removed on exit.
The vector generator and static TB are supplied. Every package source/document
and the sibling dependency are SHA256-bound in `verification.json`; LF source
bytes are required and `.gitattributes` preserves them.

The independent oracle does **not** take a square root or construct either
closed-form eigenvalue. It binary-searches the exact fixed-point floors using
integer 2x2 matrix-inertia predicates: `M-zI` is PSD iff both diagonals and its
determinant are nonnegative; it is negative definite iff its first diagonal
is negative and determinant positive. It verifies the adjacent integer bounds
and derives discriminant via `trace^2-4*det(M)`. Seven parameter profiles
include exhaustive 64 signed2 and 512 signed3 matrices, default parameters,
maximum W/FRAC/result/tag widths, zero fraction, minimum result width and
high-fraction saturation. Other vectors include signed extrema, diagonal and
repeated spectra, positive/negative semidefinite and indefinite matrices,
determinant +/-1 with a near-zero eigenvalue, sign/diagonal symmetries, and
seeded random matrices. Every output field and exact latency is checked.
Output stalls, input capture/tag capture and replay without reset are tested.

Nine reset phase cancellations per profile cover initial setup, both initial
squares, root offer/run/available-result, root-correction square, eigenvalue
commit and pending output. The test asserts reset immediately after observing
the selected state, without crossing an extra active edge. A blocked next
offer is also canceled with pending output. These are finite phase probes,
not an arbitrary-cycle proof. Eight invalid parameter cases are rejected and
the example is syntax compiled. Icarus's known missing-timescale warning for
the unchanged sqrt modules is retained in evidence; other diagnostics fail
the runner. The dependency has no simulation delays in its arithmetic.

After the recorded runner passes, maturity is **LINT_PASS + UNIT_SIM_PASS**,
the example is **INTEGRATION_CANDIDATE**, and all new/composed RTL is
**HW_UNVERIFIED**. No synthesis, PnR, STA, hardware or expanded regression has
run. There is no eigenvector output, nonsymmetric matrix support or general
matrix-size claim. Finite tests are not exhaustive over all supported widths.
