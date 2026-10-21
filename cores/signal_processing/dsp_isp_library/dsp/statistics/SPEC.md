# Amplitude, power, RMS and peak statistics

Requirement: goal DSP04. All subitems remain tracked below. This is a bounded
single-real-channel reference configuration; complex magnitude can compose
the separate complex-power/square-root infrastructure when implemented.

| Subitem | Defined implementation |
|---|---|
| amplitude | absolute value of latest scaled signed Q1.15 input, plus window mean absolute value |
| power | window mean square in unsigned 32-bit integer-square units (30 fractional bits) |
| RMS | integer floor square root of rounded mean square; 16-bit unsigned with 15 fraction bits |
| peak | maximum absolute scaled sample; earliest real sample on ties; 32-bit position |
| sliding | N=1,2,4,8,16,32,64; one result per accepted sample, zero prehistory and fixed divisor N |
| block | same N; one result per N accepted samples; incomplete tail retained until more input or reset/config |
| threshold | output flag when rounded mean power >= unsigned 32-bit threshold |
| scaling | atomic signed scale -8..15; positive right shift RNE, negative left shift; saturate to signed16 |

All data fields are derived from the same window after inserting the current
sample. Input -32768 produces unsigned magnitude 32768, never signed overflow.
Scaling sets a window flag if any sample clipped. Default scale=0, N=16,
sliding, threshold=0x10000000 (normalized mean power 0.25).
Means round nearest ties even for positive values; scale uses the same signed
ties-even rule. Power sum needs 37 unsigned bits (64*32768²=2^36), amplitude
sum 22 bits. No intermediate saturation. RMS floor error versus square root of
rounded power is <1 magnitude integer LSB; mean-power rounding contributes at
most 0.5 power LSB. Scaling quantization contributes <=0.5 magnitude LSB prior
to statistics, documented separately from RMS approximation.

## Interface and update contract

`clk`, synchronous active-low `rst_n`. Input signed `s_tdata[15:0]`,
`s_tvalid/s_tready`; output `m_tdata[127:0]`, `m_tuser[1:0]`,
`m_tvalid/m_tready`. Packing MSB to LSB: position[31:0], meanpower[31:0],
meanabs[15:0], RMS[15:0], peak[15:0], latest amplitude[15:0].
tuser bit0=any clipped; bit1=meanpower>=threshold. Fields hold under stall.
Position starts at 0 after reset or accepted legal config and wraps modulo 2^32;
tie ordering is chronological within the window even across position wrap.

Independent config handshake contains block, log2[3:0], signed scale[4:0],
threshold[31:0]. Accept only when the entire output pipeline is empty; config
has input priority. `cfg_done/cfg_error` pulse after acceptance. Invalid
log2>6 or scale<-8 rejects the entire update, preserving active config/state.
Legal update clears algorithm history and drops partial block; all in-flight
pipeline results must drain first. Reset clears config to defaults, valid and
state, discarding pending output/partial block and every pipeline slot.
Only accepted samples change algorithm history. History validity count masks
uninitialized registers; no bulk RAM reset required. Target II=1 for input;
sliding output II=1, block output every N accepted inputs. Results travel a
17-slot elastic pipeline (leaf output register plus 16 registered root
stages): output transfer latency is 17 cycles from the producing input, and
output backpressure propagates stage-by-stage, stalling input only when the
pipeline is full. Buffer capacity 17 results.

## Arithmetic architecture and budget

Small 64-entry magnitude/clip shift register supports concurrent oldest lookup
and balanced/combinational peak selection. It is deliberately register storage,
not advertised as BRAM. Two unsigned square multiplies (new/old) feed the leaf;
sums remain wide until conversion. The integer floor square root runs in a
separate 16-stage elastic pipeline after the leaf: each register performs one
binary restoring iteration on the leaf-emitted 32-bit rounded mean power while
the remaining 128-bit result fields and tuser travel alongside as metadata.
This replaces the earlier single-cycle combinational 16-iteration root, which
was physically diagnosed as not settling within one 27 MHz GW2A cycle and
produced deterministic wrong low RMS bits on silicon (see
`board/dsp_chain_harness/STATUS.md` "RMS physical failure follow-up" and the
fold note in `FIXNOTE.md`). One iteration per register also removes the
transitional-radicand capture failure seen in the shallower radix-4 variant.
The numerical contract is unchanged: RMS is still floor(sqrt(mean_power)).
Core-only synthesis, wrapper synthesis, P&R and board acceptance remain distinct.
No hardware or timing acceptance is implied by the algorithm models.

Compile-time parameter `LOGIC_SQUARE=0` uses the original two multipliers.
`LOGIC_SQUARE=1` computes both squares using explicit unsigned partial products
and a balanced addition tree, freeing both multiplier primitives for a shared
DSP chain. Both implement the full statistics/configuration contract with identical
latency, buffering and II. The latter may increase LUT count and critical-path
delay; a resource win does not prove 27 MHz timing. The verification testbench
instantiates both variants with identical stimuli and compares every cycle's
protocol and output against each other and the independently generated oracle.

Two-variant equivalence PASS is recorded in
`evidence/rtl_20260925_163647_186023/summary.json` (39,000 cycles, 84 configs,
seven executable corrupted fixtures rejected, stats_latency=17). Source SHA-256:
`e468b9f467ea799c6c5f28a4ac313e5b91774575274ab1c1a0b778a01f10a48e`.
The earlier combinational-root RTL PASS at
`evidence/rtl_20260925_023555_464308/` is preserved as history for the
superseded latency-1 implementation.
Reproduce matched-tool synthesis with
`python cores/signal_processing/dsp_isp_library/dsp/statistics/tests/synth_variants.py`;
each variant's command, full Yosys log, JSON netlist and cell-type counts are
saved in a new timestamped evidence directory. This script verifies that the
logic variant uses zero Gowin multiplier primitives.

Matched synthesis PASS in
`evidence/synth_variants_20260925_163749_283445/summary.json`:

| LOGIC_SQUARE | LUT1–4 | FF | MULT18X18 | BRAM | wide muxes (separate) |
|---|---:|---:|---:|---:|---:|
| 0 | 5544 | 3820 | 2 | 0 | 626 |
| 1 | 6606 | 3820 | 0 | 0 | 629 |

Versus the superseded combinational-root core the 16-stage root pipeline adds
+557 LUT1–4 and +2411 FF (variant 0) / +431 LUT1–4 and +2411 FF (variant 1);
DSP counts are unchanged. The logic option still removes both DSP primitives,
costing 1062 extra LUT1–4 over the multiplier variant. Combining the
isolated DC core (three DSPs) with this option leaves an arithmetic subtotal of
three DSPs; actual wrapper/chain counts and routed timing remain to be measured.

## Executed verification

From repository root:

```
python cores/signal_processing/dsp_isp_library/dsp/statistics/tests/test_models.py
python cores/signal_processing/dsp_isp_library/dsp/statistics/tests/test_rtl.py
```

Algorithm PASS: `evidence/model_validation.json`, 588 cases: both window modes,
all seven lengths, six representative scales including legal endpoints, zero,
constant positive/negative full scale, alternating extrema, impulse, sine and
seeded random samples. Signed tie rounding, earliest tie positions, reset/config
and invalid configuration checks included. Against ideal-scaled floating model,
observed maxima: meanabs 1.0 amplitude LSB, RMS 1.447999 amplitude LSB, power
16383.75 power LSB. These include input-scale quantization and are measured
vector bounds, not promised universal errors; with scale=0 only mean/sqrt
quantization remains.

RTL PASS: `evidence/rtl_20260925_163647_186023/summary.json`, 39,000 cycles,
17,512 output transfers, 84 legal mode/length/scale combinations, 91 accepted
configurations and 28 reset edges. Every cycle compares ready, valid, result,
flags, done/error to expectations generated before simulation by an
independent 17-slot elastic-pipeline oracle. Tests include 51-cycle
backpressure intervals, continuous source/sink phases, random gaps,
configuration held during busy output and while the pipe drains (1,899
blocked config cycles observed), 11 resets with in-flight pipeline results,
invalid scale and length, window wrap and block boundaries. Output transfer
latency is 17 cycles from the producing input and continuous sliding II is 1.
The balanced 64-leaf peak network chooses older offset on equality and
subtracts that offset once from the sample index; block mode carries the
earliest maximum separately.

Seven independently corrupted fixture variants are executed against the same
scoreboard and rejected: value, RMS field, order, valid/count, ready, flags
and config status. Each run creates a fresh evidence directory with input/expected fixture,
testbench, compiler/run/negative logs and RTL SHA-256. Existing logs remain.
No sideband on the input; output flags are checked during every stalled cycle.
