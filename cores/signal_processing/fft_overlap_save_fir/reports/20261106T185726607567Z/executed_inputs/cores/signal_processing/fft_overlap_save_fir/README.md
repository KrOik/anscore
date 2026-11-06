# Programmable complex FFT overlap-save FIR

Source status: RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED.
Authoring performs no model, parser, compiler, simulator or hardware execution.
Baseline:05b9614c3962e9d4ae934c4b9c7bd315cc01aed4.

`fft_overlap_save_fir` performs the actual coefficient FFT, data FFT, complex
frequency-domain multiplication, normalized IFFT, overlap discard and history
maintenance. It supports persistent streams and automatic finite-stream tails.
The example accepts real coefficients/samples and exposes the resulting real
output plus the finite-precision imaginary residual.

LOG_N=1..8 gives N=2..256; DATA_W=8..24 and TAG_W=1..32. Components are signed
DATA_W integers. Runtime M=1..N gives a hop B=N-M+1. Coefficients represent an
integer complex value divided by2**g_frac, with g_frac=0..DATA_W-1. The precise
accepted numerical definition is the staged integer chain in ARCHITECTURE.md,
including FFT-stage RNE/saturation and per-bin product RNE/saturation. It is
distinct from ideal real/complex convolution.

All interfaces use synchronous active-high reset and ordinary rising-edge
valid&&ready. Reset gates public handshakes low, cancels work and invalidates
coefficients/history. Payload memories are unreset. No CDC/CE/sample-rate clock
or autonomous input timeout is provided.

| Group | Contract |
|---|---|
| g_valid/g_ready | Begin configuration; capture full32 g_taps/g_frac and g_tag |
| k_valid/k_ready | Exactly M complex taps, LAST only on M; k_invalid aborts |
| r_valid/r_ready | Held configuration reply; successful retirement publishes |
| r_status |0 OK,1 BAD_TAPS,2 BAD_FRAC,3 INVALID_TAP,4 EARLY_LAST,5 MISSING_LAST,6 FFT_FAULT|
| r_taps/r_frac/r_received/r_tag | Captured full command fields and accepted tap count |
| r_overflow/r_inexact | Final coefficient FFT flags on successful reply |
| c_valid/c_ready | Capture c_count, c_end, c_restart and c_tag |
| s_valid/s_ready | Exactly c_count actual complex inputs, LAST only on final |
| s_invalid | Abort accepted input before output; clear stream history |
| m_valid/m_ready | Held output sample or one keep=0 terminal marker |
| m_status |0 OK,1 EMPTY,2 NO_CONFIG,3 BAD_COUNT,4 INVALID_INPUT,5 EARLY_LAST,6 MISSING_LAST,7 FFT_FAULT|
| m_keep/m_last/m_error | Numeric sample; final item of command; terminal error |
| m_index | Zero-based output position within this command, including tail |
| m_count/m_total/m_received | Captured actual-input count, numeric output count, accepted input count |
| m_overflow/m_inexact | Cumulative coefficient/command flags through this IFFT block |
| m_tag/busy | Captured command tag; transaction still owns the core |

Configuration has priority if g_valid and c_valid coincide in idle. There is no
input fallthrough on command or reply/result retirement. Commands are blocked
through the entire tap load/transform/held reply. Rejected configuration input
preserves the old filter/history. Successful publication clears old history;
the next command starts from M-1 zeros. Changes on live command ports after
acceptance have no effect. The support-source admission is explicit in
DEPENDENCY_PROVENANCE.md: the FFT file was absent from the baseline tree and
is admitted unchanged as original workspace source, with no historical results
adopted.

A normal command has c_end=0 and must supply exactly B actual inputs. It returns
B outputs and saves the final M-1 time samples. c_restart discards prior stream
history for this legal command. An end command has c_end=1 and accepts0..B real
inputs, internally zero pads and runs as many blocks as necessary to return
c_count+M-1 outputs, including the finite tail. A separate zero-input end after
full blocks flushes the remaining M-1 outputs. M=N is legal (B=1); M=1 has no
history or tail. A zero-input end on an empty/restarted stream, or with M=1,
returns an EMPTY success marker, zero total/flags/payload and no input transfer.
End completion clears history. busy can remain high briefly after final output
LAST while unused padded IFFT outputs drain; wait for c_ready before reuse.

Invalid counts/NO_CONFIG consume no input and preserve history. Accepted invalid
input or malformed LAST emits one zero error marker and invalidates history.
The next command starts at its first accepted input; there is no drain-to-LAST
resynchronization. Reset cancels every partially completed command/reply/tail.
Unexpected internal FFT protocol faults terminate the command and reset the
helper; earlier outputs from a multi-block tail cannot be rolled back.

New RTL budgets one extra shared real multiplier and three complex N-word RAMs
in addition to the reused FFT's multiplier/RAM. Computation is sequential and
does not accept continuous one-sample-per-clock streams. An upstream FIFO or
paced source must respect ready. All throughput/latency/resource statements are
source-level plans; no synthesis, timing, board or power result is claimed.

The prospective independent oracle uses recursive array FFT mathematics with
high-precision direct roots, separate signed-magnitude RNE, and no project
imports. Selected zero/unit/sign/gain/half-frame-delay/half-frame-sum/constant
time-domain responses constrain the model independently where transforms are
exactly representable. Random integer data, clipping, fractional ties, streaming,
short ends, empty tails, damage, resets and real-adapter behavior are planned.
Only a later additive receipt may claim executed qualification.

The prospective maximum N256 case covers M=N persistent blocks and history,
but deliberately excludes its complete N-block tail within one20-second child.
Full M=N finite-tail closure is planned at N2/N8/N64. This scope distinction
must remain visible in qualification; coverage at smaller sizes is not a proof
of the unexecuted maximum conjunction.
