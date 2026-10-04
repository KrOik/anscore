# INFRA-05 shared fixed-point arithmetic cores

Reusable arithmetic primitives for RMS / AGC / NLMS / statistics / geometry
cores. Single `clk`, synchronous active-low `rst_n`. All data ports use the
Stream contract: `s_tdata/s_tvalid/s_tready` in, `m_tdata/m_tuser/m_tvalid/
m_tready` out. A transfer happens only at a rising edge with
`tvalid && tready`; `m_tvalid` never waits for `m_tready`; while
`m_tvalid && !m_tready` data and flag sidebands are held stable. `s_tready`
is gated by `rst_n`. There is no dynamic configuration interface; all
options are static parameters checked by `$fatal` in simulation (illegal
combinations are rejected at elaboration or time 0).

Rounding rule everywhere is **RNE** (round-half-to-even): `y = floor(v/2^s)`
plus one iff the fraction exceeds 1/2 or equals 1/2 with odd quotient. The
rule is symmetric for negative two's-complement inputs. No intentional
modular arithmetic exists anywhere; every narrowing is RNE followed by
signed/unsigned saturation with an explicit clip flag.

Latency below counts rising edges from the input transfer to the earliest
possible output transfer with no stalls.

## sat_round.sv — rounding + saturation

`y = sat_OUT_W(RNE(v / 2**SHIFT))` on each beat.

- Parameters: `IN_W>=2`, `OUT_W` in 2..IN_W+1, `SHIFT` in 0..IN_W,
  `SIGNED_IN` 0/1 (input interpreted unsigned when 0; output is always
  signed OUT_W).
- `m_tuser[0]` = clip (saturation applied), `m_tuser[1]` = inexact (any
  discarded fraction bit nonzero). SHIFT=0 is exact and never clips on
  range when `OUT_W = IN_W+1`.
- II = 1, latency = 1.

## cplx_mac.sv — complex multiply-accumulate run

Per run of >=1 beat: `out = sat_OUT_W(RNE(sum(a*b) / 2**SHIFT))` per
component, where `a = a_re + j*a_im`, `b = b_re + j*b_im`.

- `s_tdata` = {a_im,a_re,b_im,b_re}, each lane signed DATA_W:
  `[15:0]=a_re, [31:16]=a_im, [47:32]=b_re, [63:48]=b_im` for DATA_W=16.
- `s_tlast` marks the last product of a run. The next beat after a last
  beat starts a new run with a cleared accumulator; runs may abut without
  bubbles.
- Accumulator is signed ACC_W with **saturating** update and a sticky
  per-run overflow flag `m_tuser[1]` (never wraps). `m_tuser[0]` = output
  clip (re or im saturated). Choose `ACC_W >= 2*DATA_W+1+ceil(log2(run))`
  to keep a run exact; the flag documents any clamp.
- Parameters: `DATA_W` 2..18, `ACC_W >= 2*DATA_W+1`, `OUT_W` 2..ACC_W+1,
  `SHIFT` 0..ACC_W-1.
- II = 1 for product beats. Latency: last beat -> earliest output
  transfer = 3 cycles (operand register, product register, accumulate).
  A completed run stalls upstream only while a previous output is held.

## recip_div.sv — division and reciprocal

`q = sat_OUT_W(RNE(a * 2**FB / b))` on packed `s_tdata` = {b,a},
`[AW-1:0]=a`, `[AW+BW-1:AW]=b`, both signed.

- Divide by zero: `q = OUT_MIN` when `a < 0` else `OUT_MAX`,
  `m_tuser = {div0=1, clip=1}`. Never X, never wraps.
- `m_tuser[0]` = clip (signed quotient saturated), `m_tuser[1]` = div0.
- Reciprocal: `fp_div` with `a = 2**k` gives `RNE(2**(FB+k)/b)`; e.g.
  `a=1` yields the Q(FB) reciprocal of integer b.
- Parameters: `AW,BW >= 2`, `FB` 0..24, `OUT_W` 2..N+1 with `N = AW+FB`.
- `fp_div_iter`: one quotient bit per clock; latency = N+1 cycles
  (input transfer edge to earliest output transfer edge), 2 cycles for
  div0; initiation interval = latency (one operation in flight).
- `fp_div_pipe`: fully unrolled; II = 1, latency = N+1 cycles.
- Numerical contract: |error| <= 1/2 lsb of the Q(FB) result (exact RNE).

## sqrt_unit.sv — unsigned square root

`r = RNE(sqrt(x) * 2**FB)`; input `x` unsigned IN_W; internally the exact
radix-4 integer square root of `x << 2*FB` over `N = ceil((IN_W+2*FB)/2)`
iterations, then RNE on the remainder (`rem > root` rounds up; `rem ==
root` is provably below the half point). |error| <= 1/2 lsb.

- Output unsigned `N+1` bits (covers the +1 rounding carry).
- `m_tuser[0]` = zero input (result 0), `m_tuser[1]` = exact
  (post-iteration remainder 0, i.e. `x<<2*FB` is a perfect square).
- Parameters: `IN_W >= 2`, `FB` 0..24, `N <= 127`.
- `fp_sqrt_iter`: one digit pair per clock; latency = N+1 cycles; one
  operation in flight.
- `fp_sqrt_pipe`: unrolled; II = 1, latency = N+1 cycles.

## log2exp2.sv — fixed-point log2 and exp2 (iterative only)

Briggs shift-add pseudo-division. Internal precision `P = FB + G`.
`tab30[j] = round(log2(1+2^-j) * 2^30)` baked into the RTL; the entry used
at precision P is `tab30[j] >> (30-P)`, identical in `models/reference.py`.

`fp_log2_iter`:

- Input `x` unsigned IN_W (signed when `SIGNED_IN=1`). Constraint
  `IN_W-1 <= P <= 28`, `FB` 1..20, `G >= 2`.
- Output `y = log2(x)` signed `Q(OUT_W-FB).FB`,
  `OUT_W = FB + clog2(IN_W) + 1` (holds |y| < IN_W exactly).
- Abnormal input (`x == 0`, or `x <= 0` signed) -> `y = OUT_MIN`,
  `m_tuser[0] = 1`. `m_tuser[1]` reserved 0.
- Latency = P+4 cycles (abnormal input finishes in 3); one op in flight.
- Measured max error at FB=12, G=6, IN_W=16, exhaustive over all
  65535 inputs: **0.585 ulp** of the 2^-FB output step
  (0.5 ulp quantization + ~0.09 algorithmic).

`fp_exp2_iter`:

- Input `xn` signed `Q(IW-FB).FB` (`k = xn >>> FB`, `f = xn mod 2^FB`).
- Output `y = sat_uOUT_W(RNE(2**(xn/2**FB) * 2**FRACO))`, unsigned
  `Q(OUT_W-FRACO).FRACO`.
- `m_tuser[1]` = clip (overflow saturated to all-ones),
  `m_tuser[0]` = under (result rounded to zero; the exact-0.5 tie goes
  to even = 0).
- Constraints: `IW >= 4`, `1 <= FB < IW-1`, `G >= 2`, `P <= 28`,
  `4 <= OUT_W`, `0 <= FRACO < OUT_W`, and `2^(IW-FB-1) <= FRACO+2`
  (keeps the right-shift amount inside the datapath).
- Latency = P+4 cycles; one operation in flight.
- Measured at FB=12, G=6, exhaustive over all 65536 inputs: algorithmic
  relative error <= **1.3e-5** (~0.05 ulp at P); total error is that plus
  <= 1/2 lsb output quantization.

Pipelined log2/exp2 variants are intentionally not provided: these are
block-rate primitives for RMS/AGC/NLMS, and the iterative forms are
multiplier-free (shift + add + LUT constants only).

## Reuse notes

- RMS: sum of squares = `cplx_mac` run with `b = a` (or use the re part
  with `a_im = b_im = 0`), then `fp_sqrt_*`, then `fp_div_*` for the
  block mean. `sat_round` scales between stages.
- AGC: `fp_log2_iter`/`fp_exp2_iter` form the log-domain gain path;
  `sat_round` applies gain quantization; `fp_div_*` normalizes.
- NLMS: `cplx_mac` provides the energy accumulator; `fp_div_*` computes
  mu/energy with the div0 flag as the energy-floor guard.
