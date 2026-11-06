# Three-frequency squared bicoherence

B45 baseline: `a0602fb2dac20db7c524297371a19f5f580980df`.

`spectral_bicoherence` reduces K caller-supplied complex spectral triples into
one exact cross-bispectral sum and a squared bicoherence measurement. This
retains a third-order phase relationship between two frequencies and their
sum. It adds a measurement beyond two-stream coherence and scalar power
kurtosis. Source state: **RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
The prospective finite plan is not an execution receipt. No numerical
preparation, HDL child, synthesis, PnR, STA, board test or inherited checker
has run during source development.

For the K accepted triples, with `P[k]=X[k]*Y[k]`:

```text
B = sum(P[k]*Conj(Z[k]))
U = sum(|P[k]|^2)
V = sum(|Z[k]|^2)
q16 = RNE(65536 * (Re(B)^2 + Im(B)^2) / (U*V))
```

All intermediate products and sums are exact integers. There is only one
rounding, nearest with ties to even. Cauchy's inequality gives `0<=q16<=65536`
when U and V are nonzero; 65536 is unity. B is the unaveraged sum, not B/K.
For `X=Y=1,Z=j`, the imaginary B component is negative. A fixed nonzero
common scale for each of X, Y and Z cancels in the ratio. Per-segment changing
scales, FFT clipping or inconsistent preprocessing change the measurement.

The caller owns segment alignment, common frequency grid, window/scaling
semantics and the relation `f3=f1+f2`. The bare core does not validate frequency
labels, run an FFT or estimate delay. K=1 is legal and every nonzero triple
then has unity bicoherence, so that case carries no evidence of coupling.
This finite-record statistic supplies no significance threshold, confidence
interval, surrogate analysis, causal inference or calibrated detector. DC,
leakage and waveform harmonics can contribute to it.

## Interface

All interfaces use ordinary rising-edge `valid && ready`, one clock and
synchronous active-high `rst`, without CE or CDC. Reset gates all ready/valid
outputs low and cancels the accepted command and any held result. The reused
multiplier's asynchronous reset is driven only by the external synchronous
reset contract or a registered flush state; assert/deassert external reset
away from a rising edge as ordinary synchronous setup/hold requires.

`c_valid/c_ready` accepts full32 `c_averages` and opaque `c_tag`. K must be
1..MAX_AVERAGES and is checked before narrowing. Parameters: DATA_W=2..16,
MAX_AVERAGES=1..256 (including nonpowers of two), TAG_W=1..32. Defaults are
12/64/8. Derived width parameters must retain their formulas.

One command owns the core until its sole result retires. The K input beats
use `s_data` lanes from least significant: Xre,Xim,Yre,Yim,Zre,Zim, all signed
DATA_W. `s_last` is required exactly on input K-1. Producers must hold every
offered record until its handshake or reset. Input pauses extend physical
time without advancing the record. No input timeout or unconditional physical
sample-rate guarantee is supplied.

One result contains status, unsigned17 q16, signed full-width B components,
unsigned U/V, captured tag and last=1. Data and metadata remain stable during
backpressure. A held result blocks samples and commands; a new command cannot
fall through on the final retirement edge.

| Status | Meaning | Raw B/U/V and q16 |
|---|---|---|
| 0 OK | Nonzero normalization | Exact raw sums and final rounded q16 |
| 1 BAD_AVERAGES | K=0 or K>MAX_AVERAGES | One zero marker; no input accepted |
| 2 BAD_LAST | Accepted core LAST differs from expected final input | One zero marker; remaining input cancelled |
| 3 ZERO_ENERGY | U=0 or V=0; ratio undefined | Preserve raw B/U/V, q16=0 |
| 4 ARITH | Accumulator/invariant/divider failure | One zero fatal marker after helper flush |
| 5 BAD_SPECTRUM_LAST | Adapter-only malformed bin-frame LAST | One zero fatal marker after core cancellation |

Legal inputs cannot overflow these widths or require saturation. There is no
clipping path or saturation flag: an impossible range or divider condition
instead gives status4 and zero data. ARITH branches are source-reviewed;
internal corruption/fault injection is outside this finite plan.

## Actual spectrum-frame connection

`example/spectrum_triad_bicoherence.sv` consumes K natural-order complex
spectra, each with BINS bins and LAST on bin BINS-1. It captures static BIN1,
BIN2 and BIN3=BIN1+BIN2 and forwards one actual triple per completed spectrum
to the same core. Defaults: BINS64, BIN1=3, BIN2=7, BIN3=10. Legal BINS1..256
and nonnegative selected indices require BIN3<BINS; frequency addition does
not wrap. Repeated bins, including the BINS1/DC case, are allowed and captured
on the same accepted beat. Every selected register is overwritten before use.

This adapter validates complete frame boundaries and selected bin ownership;
it still expects spectra from the caller. It contains no FFT or time-domain
frontend. It can collect the next frame while the core computes the previous
triple, then holds one pending triple until the core is ready. Malformed LAST
flushes the core and emits status5. Invalid K is forwarded to the core's
status1 path without collecting bins. No command/result bypass is present.

## Resources and checks

One unchanged repository unsigned serial multiplier serves 12 products per
triple plus three products per batch. One unchanged restoring integer divider
serves the final ratio. There is no sample RAM, output ROM, combinational
division, `real` arithmetic or new multiplier operator array in the RTL.
The register storage and latency budget is in ARCHITECTURE.md. No physical
LUT/FF/DSP/RAM, Fmax or power measurement is claimed.

The independent reference expands the cubic polynomial directly and computes
U as `sum(|X|^2*|Y|^2)`, rather than replaying the RTL's serialized products.
Five planned profiles include DATA_W2/MAX1 and nonpower MAX9, full-scale
DATA_W16/MAX256, a 17-bin actual adapter and the one-bin repeated selection.
Directed vectors include zero/undefined energy, signed minima, quadrature,
cancellation, malformed LAST, full32 invalid K, and exact RNE half cases
0.5->0 and 1.5->2. TB checks stable input/output/command holds, a distinct
future command through its real post-retirement handshake, recovery after
four reset phases and the core's final-input first-valid cycle schedule.

The new standalone runner requires a root/peer review of the exact sealed
sources and an exclusive execution lock. It archives the complete offline
source closure before five isolated numerical preparation children, then
runs the fixed twelve HDL checks. Every child is limited to20 seconds, one
tree-kill helper to5 seconds and one sole exit observation to2 seconds.
Failures, logs, vectors and images remain; no retry or cleanup occurs.
