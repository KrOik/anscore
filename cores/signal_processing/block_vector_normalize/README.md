# Framed L2 vector normalization

`block_vector_normalize` accepts a bounded variable-length vector of signed
integers, computes its exact squared energy, and emits normalized fixed-point
components in input order. It composes the existing iterative fixed-point
root and divider with a synchronous component buffer and original controller.
No norm, reciprocal or component result is precomputed by the caller.

## Numerical contract and accuracy

For K selected components x, with `F=FRAC`, the exact staged contract is:

```text
S = sum(x[i]^2)                            // exact unsigned integer
r = RNE(sqrt(S) * 2^(F+2))
q[i] = RNE(x[i] * 2^(2*F+2) / r)
```

RNE means round to nearest integer, with exact ties to even. Outputs are
signed `F+2`-bit integers representing `q[i]/2^F`; their full domain includes
both -1 and +1. The two-step contract is bit-exact and is **not** a claim of
bit identity to `RNE(x[i]*2^F/sqrt(S))`. Normal inputs have no arithmetic
saturation: the derived widths prevent intermediate overflow and every q
is in `[-2^F,+2^F]`. The inherited divider's clip/divzero flags are unreachable
for a legal nonzero vector and are checked in the finite TB.

The complete-domain error bound follows without a floating tolerance. For
S>=1 let `rho=sqrt(S)*2^(F+2)`, so `rho>=2^(F+2)` and `|r-rho|<=1/2`.
The ideal magnitude in output-code units is
`u=abs(x[i])*2^F/sqrt(S)<=2^F`. Before the final RNE, the algorithm has value
`v=u*rho/r`; therefore:

```text
|v-u| <= 2^F * (1/2) / (2^(F+2)-1/2)
       = 2^F / (2^(F+3)-1) <= 1/7    for every F>=0
|q-u| <= 1/7 + 1/2 = 9/14 output LSB
```

Sign restoration gives the same bound for negative x. Thus each reported
real component differs from the ideal unit vector by at most
`9/(14*2^F)`. By the Euclidean triangle inequality, the reported vector's
norm differs from 1 by at most `sqrt(K)*9/(14*2^F)`. Rounded components do
not in general have exactly unit norm. At low precision a nonzero vector
can even round to all zeros while still having normal status. Defaults
K<=16,F=16 give a norm-error bound below 0.000040.

Since the root radicand `S*2^(2*(F+2))` is an integer, an exact half-integer
root tie is impossible: four times the radicand cannot equal an odd square.
Root rounding can go either direction; final component division can have
ties, and both even-down and odd-up cases are covered. Signed minimum input
magnitudes and exact components +/-1 are fully supported.

## Frames, statuses and ports

Each accepted `s_keep=1` beat appends one component. Masked beats carry frame
boundaries and tags but contribute neither components nor energy. A frame
has at least one accepted beat and ends on accepted `s_last=1`. The first
accepted beat supplies the output tag even if masked; later input tags are
ignored. The source must hold all input fields until `s_valid && s_ready`.

| `m_status` | Frame result |
| --- | --- |
| 0 normal | K nonzero-norm components; K output tokens with `m_keep=1` |
| 1 empty | No selected components; one status token with `m_keep=0` |
| 2 zero norm | K>0 selected zero components; K zero tokens with `m_keep=1` |
| 3 overflow | More than MAX_LEN selected components; whole frame rejected, one `m_keep=0` token |

Normal vectors may contain individual zero components. For normal/zero frames,
`m_count=K`, `m_energy=S`, `m_index=0..K-1`, and `m_last=1` only on the final
token. For empty/overflow status-only output, data/count/energy/index are zero
and last is one. Overflow drains through the input tail, emits no prefix and
does not publish prefix energy. Missing last leaves an open frame indefinitely;
there is no timeout, implicit tail or forced truncation. No next frame is
admitted until the final output token transfers.

All transfers are ordinary ready/valid on one rising-edge clock. There is no
CE, CDC, runtime configuration or external memory interface. Every output
field remains stable while `m_valid && !m_ready`. `rst` is synchronous high;
assert across an active edge to cancel collection, arithmetic and pending
output. During reset s_ready/m_valid are low. Both old arithmetic cores use
the matching synchronous-low reset through `!rst`. Buffer payload is not reset:
each retained location is written by the current frame before its first read.
Control, public results and energy/count reset; canceled frames require caller
replay. Invalid output payload has no defined meaning.

| Parameter | Default | Legal values |
| --- | ---: | --- |
| `DATA_W` | 16 | 2..24 |
| `MAX_LEN` | 16 | 1..64, including non-powers of two |
| `FRAC` | 16 | 0..22 |
| `TAG_W` | 8 | 1..32 |

Derived local widths are not user overrides:
`COUNT_W=max(1,clog2(MAX_LEN+1))`, `INDEX_W=max(1,clog2(MAX_LEN))`, and
`ENERGY_W=2*DATA_W+ceil(log2(MAX_LEN))` (the last term is zero for length 1).
Counts include the exact capacity. Illegal parameters fail elaboration via an
unresolved `block_vector_normalize_invalid_parameter__see_README` instance.

## Architecture, widths and finite service

One signed DATA_W-square multiplier computes the captured component's full
2*DATA_W-bit product on the clock after acceptance; exact unsigned energy is
accumulated then. A retained beat accepted at E permits the next beat at E+2;
masked/excess beats permit next-edge acceptance. The buffer uses one synchronous
read address, one capture-write address, and no payload reset. Capture and
processing are disjoint, so no read/write collision behavior is required.

Let `C=ceil(log2(MAX_LEN))`, `RF=F+2`,
`RN=ceil((ENERGY_W+2*RF)/2)` and `DN=DATA_W+2*F+2`.
Full energy satisfies `S<=MAX_LEN*2^(2*DATA_W-2)<=2^(ENERGY_W-2)`, so unsigned
ENERGY_W bits suffice. Negative minimum squares remain positive. The root
uses `IN_W=ENERGY_W`, `FB=RF<=24`; its count RN is at most 51, below 127.
Its RN+1-bit result has a clear sign bit for this bounded energy domain.

The divider uses `AW=DATA_W+RF`, `BW=RN+1`, `FB=F`, `OUT_W=F+2`.
The signed input is x followed by RF zeros; shifting cannot discard its sign
or the minimum-negative magnitude. The positive root is passed in its full
width. DN<=70 is below the inherited 255-iteration limit, and OUT_W<=DN+1.
Division is never started for S=0. Since root-stage error is <=1/7 output
LSB and the ideal magnitude <=2^F, final RNE cannot exceed +/-2^F; no final
clamp can be activated within legal parameters.

From the accepted input tail, first normal output becomes valid after
`RN+DN+7` clocks if the tail was retained, or one clock less if masked.
For zero vectors the corresponding delays are 3/2; empty or overflow takes
one clock. After a nonfinal output transfer, the next normal output becomes
valid DN+3 clocks later; a zero-vector output takes one. Earliest transfer
is one edge after valid. Backpressure extends occupancy without a finite
unconditional deadline. Default RN=36, DN=50 gives 93/92 clocks to first
normal valid and 53 between a transfer and the next normal valid. These
are controller schedules, not measured hardware frequency/throughput.

A fully parallel implementation would replicate division and buffer ports;
the selected design targets moderate-rate vectors by sharing the old iterative
arithmetic. Only their iterative modules are instantiated; unused pipeline
modules in the same files add no instantiated storage. Logical component RAM
is 256 bits by default and 1536 at maximum. No ROM, vendor primitive, external
storage or generated coefficient data is needed. Qualitative resource risk
is **LOW** by default and **MEDIUM** at maximum, from the square multiplier,
wide divider/root paths and serialization. Actual DSP/BRAM mapping, resources,
fit, timing and power are unmeasured. The dependency's history does not qualify
this new composition.

## Offline use and finite evidence

Both manifests use paths relative to this package root. The default example
exposes all component/status/framing signals and discards only energy.
Dependencies are the unchanged tracked `sqrt_unit.sv` and `recip_div.sv` in
the sibling arithmetic library; no downloads or other source files are needed.
Compile from this directory, or run the Python command from the repository root:

```text
iverilog -g2012 -Wall -tnull -s block_vector_normalize -f files.f
iverilog -g2012 -Wall -tnull -s normalize16_example -f example/files.f
python -B cores/signal_processing/block_vector_normalize/run_tests.py
```

Every runner subprocess has a 15-second timeout. It uses Python's standard
library and local Icarus/vvp, with task-specific temporary vectors/executables
removed afterward. Known missing-timescale warnings of the unchanged arithmetic
modules are recorded; all other positive-check diagnostics fail. LF is required;
package `.gitattributes` preserves it. SHA256 evidence binds all local source,
documentation and both unchanged dependency files.

The oracle uses `math.isqrt`, squared midpoint comparison and exact integer
division/remainders for the two RNE stages, independently of their iterative
RTL schedules. For every normal component it separately checks the stated
ideal-vector error using squared rational interval endpoints, with no floating
tolerance. Eight profiles cover minimum and maximum data/length/fraction/tag
widths, non-power-of-two buffers, all signed2 vectors of lengths 1..3, both
root-round directions, component even/odd ties, extrema, exact +/-1, tiny
components, empty/zero/overfull frames, masks and seeded random vectors.
Every output field, exact first/inter-token latency, source capture, source
stall and held-output behavior is checked. Twelve reset phase cancellations
per profile cover every controller state and available root/divider outputs;
reset is asserted immediately after observing the target, without another
active edge. A blocked next-frame offer is canceled in the pending-output probe.
Eight illegal parameter cases and default example syntax are checked.

After the recorded runner passes, maturity is **LINT_PASS + UNIT_SIM_PASS**,
the example is **INTEGRATION_CANDIDATE**, and all new/composed RTL remains
**HW_UNVERIFIED**. No synthesis, PnR, STA, hardware or expanded regression ran.
Finite checks are not exhaustive over all vectors or legal parameter tuples.
