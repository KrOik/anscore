# Functional DSP adapters on the legacy stream ABI

Currently `cip_fir_stream`, `cip_iir_biquad_stream`, `cip_resampler_stream`
and `cip_cic_decimator`, plus `cip_cordic_stream` and `cip_fft_stream`, are
functional. Their algorithm entries are also available directly via explicit
`cip_dsp_*` modules in `../dsp/`. The 42 image templates remain rejection-only.
This distinction is recorded per module in manifest.json.

## Filter commands

| Opcode | cfg_param0 | cfg_param1 | Response |
|---|---|---|---|
| 0 RUN | 0 | 0 | OK only after the packet's final output is consumed |
| 1 COEFFICIENT | address within the coefficient bank | signed coefficient, sign extended to 32 bits | OK after coefficient write |
| Other | any | any | UNSUPPORTED, no effect |

Response errors are 0 OK, 1 UNSUPPORTED, 2 INVALID_ARGUMENT. An out-of-range
coefficient address, a coefficient that is not representable in COEFF_W bits,
or nonzero RUN parameters returns INVALID_ARGUMENT without starting a run or
changing coefficients. FIR/resampler have TAPS coefficients; biquad has five
coefficients in b0,b1,b2,a1,a2 order with implicit a0=1.
Each command produces exactly one response with its
accepted cmd_tag; reset cancels pending commands. Response tag/error/valid hold
under backpressure and shared CE pause. No command is accepted while active
or while a prior response remains pending; a response-consumption bubble is
intentional. No separate RUN acknowledgement precedes the packet.

After RUN acceptance, the adapter accepts a nonempty signed sample packet up
to the first accepted s_last. It then blocks further input until final output
consumption and command response consumption. It cannot accept an extra sample
on the same edge that retires the last output. For FIR each input yields one output;
last clears filter history after its own result, without emitting convolution
tail samples. Coefficients persist between runs. Without s_last the run waits
for further samples; no timeout or length limit is implicit. Reset aborts all
work and clears coefficients as well as history. Coefficient loading is allowed
only between runs, not while input is in progress.

All transfers require `clk_en && valid && ready`, including coefficient writes.
FIR defaults: DATA_W=16, TAG_W=8, TAPS=16, COEFF_W=16, SHIFT=15. Supported coefficient
width is 2..32. Numeric rounding, signed saturation and serial-MAC latency are
defined by `../dsp/README.md`. The previous all-commands-unsupported behavior of
these functional modules is intentionally retired; historical rejection test evidence
is preserved. These opcode assignments were previously reserved and ignored.

Run `python cores/system/common_scaffold/signal_video/run_tests.py`. It separately
reports 42 remaining template rejection checks and separate functional adapter
checks: 69 modeled output samples over three packets, one zero-coefficient
reset-recovery sample, 11 responses including invalid coefficients/opcodes,
tag retention, CE, backpressure and in-flight reset cancellation. This is
functional simulation, not synthesis or board acceptance.

`generate.py` regenerates only placeholder modules, and checks the existence of
hand-maintained functional adapters. It does not overwrite adapter RTL. The
functional testbench exercises actual behavior; generator presence checks alone
are not treated as functional evidence. Simulation images use a temporary
directory removed on exit; small test sources/logs remain in evidence.

## IIR biquad behavior

IIR uses the same RUN/coefficient commands. SHIFT defaults to 14, coefficient
addresses are 0..4. Each input yields one direct-form-I output with saturated
feedback: `sat((b0*x+b1*x1+b2*x2-a1*y1-a2*y2) >>> SHIFT)`.
The multiplier result, accumulator update, and final quantization now occupy
separate registered phases. Each input requires11 enabled arithmetic cycles
before output valid (plus adapter overhead); this replaces the old five-cycle
core latency without changing any numeric result. CE pauses all phases.
The last sample is computed before input/feedback history clears. Coefficients
persist across RUNs; reset clears coefficients and delay state. There is no
convolution tail. Tests exercise all five coefficients in three 23-sample
packets, 69 modeled outputs plus a reset-recovery sample, and 13 responses.

## Rational resampler behavior

Resampler uses the same commands with defaults DATA_W=16, TAG_W=8, COEFF_W=16,
SHIFT=15, UP=3, DOWN=2, TAPS=24. UP/DOWN are elaboration parameters, not runtime
RUN arguments. In contrast to FIR's packet rule above, the full convolution
tail is emitted before the command completes. s_last closes input only; RUN
remains active through tail computation and final output consumption. Packets
start at phase zero with zero history. Coefficients persist across packets.
The supported domain and output length are in `../dsp/README.md`, including
TAPS >= DOWN. Anti-alias filter coefficients must be supplied by the caller.
The arithmetic pipeline uses two enabled cycles per history tap and one final
quantization cycle, in addition to preparation and output handshake cycles.
The bounded Tang25K fixture passed three SRAM/UART comparisons, digest 72584D68;
hold timing remains unproven. Numerical results and packet tails are unchanged.
Tests use four UP/DOWN/TAPS configurations, 52 packets, 1292 independently
modeled outputs and 104 command responses. Attempted coefficient writes during
RUN stay blocked; invalid addresses/nonrepresentable coefficients do not alter
subsequent numeric results. CE, backpressure and in-flight reset are covered.
No synthesis or board acceptance is claimed.

## CIC decimator behavior

CIC supports opcode 0 RUN only, with both parameters zero. Opcode 1 and all
other opcodes return UNSUPPORTED; nonzero RUN parameters return INVALID_ARGUMENT.
RUN/tag/response/last/CE semantics match the other packet adapters. There are
no runtime coefficients. Defaults: DATA_W=16, TAG_W=8, RATE=8, STAGES=3,
ACC_W=DATA_W+STAGES*ceil(log2(RATE)), SHIFT=STAGES*ceil(log2(RATE)).
RATE/STAGES/ACC_W/SHIFT are elaboration parameters. Valid domain: RATE/STAGES
positive, ACC_W >= DATA_W >= 2, 0 <= SHIFT < ACC_W. Wider internal wrap behavior
is defined by the underlying CIC; legacy output is `sat_signed(core >>> SHIFT)`.
For power-of-two RATE and default SHIFT this removes the full DC gain RATE^STAGES.
For other rates the shift is explicitly a power-of-two scale, not exact division
by RATE^STAGES. Use the explicit wide-output core if full precision is needed.

Each RATE accepted samples yields one result. Last on a partial group causes
one terminal result using an earlier comb checkpoint; it does not pad input
with zeros, and its comb intervals are nonuniform. It is therefore not the
same as sampling a steady-state uniform-rate FIR at that arbitrary index.
Do not apply a full-period gain interpretation to the partial terminal result.
Input histories clear on last, coefficients are absent, and packets restart
the decimation phase. Reset cancels pending results and command responses.

The core has a registered input followed by registered comb stages. A checkpoint
accepted at the source becomes valid after STAGES+1 subsequent enabled pipeline
advances (when the output is empty or ready); this changes latency, not numerical
values or packet boundaries. All stages stall together behind an unaccepted
output. Input initiation interval is one enabled advance. CE-disabled clocks do
not transfer data; data/last/valid remain stable under output stall. Each comb
stage clears its own history when the corresponding terminal checkpoint reaches
it, allowing adjacent packets without mixing their histories. Tests enqueue
independent integer reference checkpoints at actual input handshakes and compare
at actual output handshakes; they do not predict a fixed ready/cycle schedule.


Four adapter configurations (RATE/STAGES/SHIFT = 1/1/0, 8/3/9, 8/3/0, 3/2/1)
cover 28 packets, 442 numeric outputs and 40 responses. The oracle computes
closed-form N-fold prefix integrals using binomial coefficients and then Nth
differences of output checkpoints, independently of the RTL's staged registers.
Tests cover full/partial groups, signed extremes, output saturation, stalls,
CE, tags, invalid commands and in-flight reset. No synthesis/board result is claimed.

## CORDIC serialized word format

CORDIC accepts DATA_W=16 only. Other elaborated word widths return
INVALID_ARGUMENT for recognized commands without accepting sample data.
TAG_W remains parameterized. Opcode 0 selects rotation and opcode 1 selects
vectoring; cfg_param0 is signed Q14 radians, sign-extended from 18 to 32 bits.
cfg_param1 must be zero. Unknown opcodes return UNSUPPORTED; invalid angle
representation or reserved parameters return INVALID_ARGUMENT. Mode and angle
are latched on command acceptance and apply to every vector in that packet.

Input words are alternating signed 16-bit x,y coordinates. s_last is allowed
only on y, terminating a nonempty packet. Each vector emits six 16-bit words:

| Word | Contents |
|---|---|
| 0 | x result bits 15:0 |
| 1 | x result bits 19:16, sign extended to 16 bits |
| 2 | y result bits 15:0 |
| 3 | y result bits 19:16, sign extended to 16 bits |
| 4 | z result bits 15:0 |
| 5 | z result bits 17:16, sign extended to 16 bits |

Interpret each low word as unsigned when reconstructing the signed value from
the pair. No output coordinate precision is silently discarded. m_last is set
only on word 5 of the packet's final vector. The packet response is produced
only after that word transfers. Core results remain held while their words
serialize; no subsequent vector is accepted until the current result drains.
The CORDIC gain, angle normalization, residual angle (rotation), and phase
offset (vectoring) match `../dsp/README.md`; no gain compensation is introduced.

An x word with s_last aborts the packet with INVALID_ARGUMENT and no output
for that incomplete vector. Any earlier complete-vector outputs remain valid
but have no last marker; the error response marks the aborted packet. Reset
cancels a partial pair, in-flight computation, serialization and response.
RUN without a final y/last waits for further words; no timeout is implicit.
Tests cover 14 packets/126 vectors/756 words and 32 command responses, including
14 odd-word abort/recovery cases and four invalid command cases. All six word
positions encounter CE/backpressure stalls; partial-pair and compute reset
cancellation are checked. No synthesis/board acceptance is claimed.

## FFT/IFFT serialized word format

FFT accepts DATA_W=16 only; other word widths reject recognized commands with
INVALID_ARGUMENT. TAG_W remains parameterized; LOG_N=1..8 selects fixed
N=2..256, default LOG_N=6. Opcode 0 is forward, opcode 1 inverse, both parameters
must be zero. Unknown opcodes return UNSUPPORTED. Mode is latched per command.
Frame length is elaborated, not a runtime command argument.

Input is exactly N complex samples in natural order, each encoded as signed
16-bit real then signed 16-bit imaginary. s_last must appear only on the final
imaginary word. Each output bin is serialized into four words:

| Word | Contents |
|---|---|
| 0 | Real result bits 15:0 |
| 1 | Remaining real high bits, sign extended to 16 bits |
| 2 | Imaginary result bits 15:0 |
| 3 | Remaining imaginary high bits, sign extended to 16 bits |

Results use 16+LOG_N+2 bits internally. Decode each low word as unsigned before
combining it with the signed high word; all growth bits are preserved. Bins are
in natural order. m_last is asserted only on word 3 of bin N-1. The OK command
response follows consumption of that word. Forward is unscaled; inverse divides
by N. Q15 twiddle rounding, synchronous RAM and fixed-point error behavior match
the explicit FFT core described in `../dsp/README.md`.

The board-qualified arithmetic pipeline adds 18 enabled clocks per butterfly
relative to the original core. It preserves numerical results, frame ordering,
CE and backpressure; it does not provide streaming initiation interval 1.
The bounded Tang25K fixture passed three SRAM/UART runs (digest 7587C122).
Hold timing remains unproven; this is not full timing signoff.

An odd-word last, early imaginary last, or missing last at the Nth imaginary
word aborts with INVALID_ARGUMENT and no output bins. A local core reset cancels
partial loading; the next accepted command begins a fresh frame. The adapter
does not scan/drain an overlong source packet to find its eventual last marker.
A stopped source before the Nth sample, without a last marker, waits until
more input or reset. Reset cancels partial loading, computation and output.
Unexpected underlying core errors also produce a command error rather than a
fabricated output bin. CE and backpressure apply to every serialized word.

Tests cover all eight lengths, 80 normal forward/inverse packets, 20400
serialized output words, 240 malformed-frame aborts and 24 invalid command
responses (344 responses including normal completion). All four word positions
encounter stalls. Partial-pair/compute reset and recovery after malformed
frames are covered. No synthesis/board acceptance is claimed.
