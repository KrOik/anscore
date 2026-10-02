# DC removal and baseline tracker — model specification

Status: independent models and RTL/protocol simulation validated; registered-output v3
source promoted with bounded candidate P&R/board/reprogram evidence. Final
production package acceptance pending; see README/manifest for precise scope.
Reference model has no DUT imports.

## Numeric contract

Input/output signed 16-bit Q1.15 (sign included in integer count), normalized
range [-1,1-2^-15]. Two outputs per accepted sample: residual y and baseline b.
Each independently saturates to this range. Rounding is nearest, ties to even,
including negative half values. Saturation occurs only at output conversion;
feedback keeps wide state. Pole r is unsigned UQ0.16 integer 0..65535.

- blocker: y[n]=x[n]-x[n-1]+r*y[n-1], b=x-y; x[-1]=y[-1]=0.
  Feedback state represents input integer units with 16 fractional guard bits.
  Round r*state/65536 once per recurrence. For |x|≤32768 integer units, impulse
  response absolute sum≤2, hence |y|≤65536: signed 34-bit state is sufficient;
  use 51-bit signed product and a guarded signed add. Baseline may reach 98304
  before saturation. Pole<1 assures mathematical stability but fixed feedback
  leaves up to 0.5/(1-r) state LSB steady residual; at r=65535 this is 0.5 input
  integer LSB. No claim of exact zero or zero limit cycles at every pole.
- baseline: b[n]=r*b[n-1]+(1-r)*x[n], y=x-b[n], zero initial b.
  Combined weighted sum is rounded once into 16 fractional guard bits. Baseline
  is a convex combination: signed 32-bit state sufficient; common guarded
  34-bit allocation is acceptable. Residual uses wide subtraction before RNE.
- mean: window N=2^window_log2, supported log2 0..8. b=sum(last N x)/N;
  prehistory zeros, fixed divisor N during startup; y=x-b. Signed 24-bit sum
  supports N=256 (minimum -8388608); update subtraction/addition uses 26 bits.
  Ring validity/count avoids RAM clear in hardware. No partial-window divisor.

Blocker -3 dB frequency relative to Nyquist gain is
fc=fs*acos(2r/(1+r²))/(2π); default r=65024/65536, fs=48 kHz.
Baseline transfer is (1-r)/(1-r z^-1); mean settles to a constant after N accepted
samples. Blocker constant startup output decays as A*r^n. Sample rate means
accepted transactions, not system clock; transport stalls do not advance time.
No automatic tail output: caller sends zeros explicitly when ring-down is wanted.

## Hardware contract

clk and synchronous active-low rst_n. Input s_tdata[15:0]/s_tvalid/s_tready;
output m_tdata[31:0]={baseline,residual}/m_tvalid/m_tready. Outputs remain stable
during stalls. All algorithm state advances only on accepted input transaction.
RTL `rtl/dc_stream.sv` has two elastic slots, no-stall transfer latency two cycles,
and II=1 (checked cycle-exact in simulation). First slot stores full numerators
and their fractional/integer tag; second performs final rounding and saturation.
Output ready is `!m_tvalid || m_tready`; front ready is `!front_valid || output_ready`.
An empty front may accept while final output stalls; both full and stalled stops
algorithm state. Ready is combinational through two stages; insert shared
synchronous FIFO between long chains to break a long ready path.
Mean ring is a synchronous-read 256x16 memory, with read-ahead to the next pointer
on accepted input. N=1 emits exact {x,0} bypass; unwritten locations are ignored
until count reaches N. No dependence on same-address RAM read/write data occurs.

Configuration atomically bundles mode[1:0], pole[15:0], window_log2[3:0] in one
cfg_valid/cfg_ready transfer. Reserved mode=3 or log2>8 is rejected with error
response and no active/state change. Commit occurs only when both elastic slots are empty;
configuration has priority over new input, and clears algorithm state. Busy config
waits with ready low. This initial version explicitly supports clear-state update;
retain-state update is not claimed. Reset discards pending input/output and state;
first subsequent output uses zero history, regardless of stale RAM contents.

## Model verification

`python cores/signal_processing/dsp_isp_library/dsp/dc/tests/test_models.py`

Float model uses independent full precision recurrences and direct window sums;
bit-exact uses integer ring accumulation/RNE. Test zero/constant/impulse/extrema/
random/two-tone drifting baseline, poles 0/0.5/default/max, mean windows 1/2/16/256,
reset/reconfigure determinism, invalid config, signed ties and output saturation.
Evidence: `evidence/model_validation.json`. Maximum accepted error ≤1.01 output
LSB versus saturated floating result. Hardware tests must add random bubbles,
backpressure, stalls, config collision, synchronous reset interruption, corruption
rejection, measured II/latency and independently generated vectors.

## RTL evidence

`python cores/signal_processing/dsp_isp_library/dsp/dc/tests/test_rtl.py`

The driver configures OSS bin/lib PATH, generates expected values before RTL runs,
and executes iverilog/vvp. Latest initial qualification:
`evidence/rtl_20260925_022245_535434/summary.json`: PASS 24,000 cycles,
15,515 output transfers, 103 configuration transactions, 26 synchronous reset
edges, all 48 cross-product combinations of mode/pole/window. This is historical
latency1 evidence; current v3 evidence is indexed by active manifest. Tests compare every
cycle's ready, output valid/data, config done/error, including held outputs during
50-cycle sink stalls, full-rate sections, random valid/ready, reset interruption
and illegal configurations. Four executable negative fixtures corrupt data,
valid/count, ready and config status; all are rejected by the same testbench.
DSP streams have no image sidebands. No physical throughput/timing claim.

Earlier failed run is retained: adding pole cross-product exposed signed 17-bit
representation of 65536 at pole=0; widening its coefficient to 18 bits fixed the
arithmetic. Golden model/expectations were unchanged. Historical initial PASS
with correlated mode/pole combinations does not count as full coverage.

Registered-output v3 preserves bit-exact recurrence/quantization while changing
transport latency from1 to2 and capacity from1 to2. Width and negative-RNE proof:
`candidates/fixed_width_round_v2/WIDTH_AUDIT.md`; exhaustive fractional-residue
tests cover262198 output values and54 product boundaries. Blocker state bound
including feedback quantization is2^32+2^15 in guard-bit state units, still
within signed34. Final configuration/physical evidence and limits are in manifest.
