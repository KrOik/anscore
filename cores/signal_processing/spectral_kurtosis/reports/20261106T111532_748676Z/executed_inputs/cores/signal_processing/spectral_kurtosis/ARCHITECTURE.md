# Architecture review

The desired capability is per-bin variability over a batch of spectra, not
spatial bin aggregation or two-stream relation. A register bank with one square
per bin could raise throughput but multiplies arithmetic and RAM ports. A
general sample-moment primitive would require reorder/state management and
does not calculate the normalized estimator. The chosen bounded single-stream
instrument shares one serial square and one divider, accepting backpressure.
Static FRAMES avoids a wide runtime coefficient multiplier or command setup
microprogram; BINS and batch depth remain elaboration parameters.

## Exact ranges

Set P=POWER_W, M=FRAMES, A=ceil(log2(M)), C=ceil(log2(M+2)), S=P+A.
Each power is in [0,2^P-1]. Therefore S1<=M*(2^P-1)<2^S and
S2<=M*(2^P-1)^2<2^(2P+A). The first and second sums use S and2P+A bits.
Both S1 squared and M*S2 fit2S bits. Cauchy gives D=M*S2-S1 squared>=0;
nonnegative powers also give S2<=S1 squared, hence D<=(M-1)*S1 squared.

The numerator (M+1)*D and denominator (M-1)*S1 squared fit2S+C bits.
For nonzero S1, SK lies in [0,M+1]. Q_W=FRAC_W+C preserves the upper endpoint
and rounding carry. Divider width2S+C+FRAC_W retains the full shifted numerator
and denominator without preliminary cancellation or quantization. Doubling
the remainder uses an extra bit. RNE compares exact twice-remainder with the
denominator and uses quotient parity on equality. No intermediate signed
arithmetic, saturation or wrap is needed; subtraction is performed only after
checking M*S2>=S1 squared.

## Shared schedule and memory ports

One packed RAM stores {S2,S1}. The first frame uses zero prior sums and writes
every commanded bin; later frames trigger one synchronous read on acceptance.
The captured power remains stable while the serial square runs. Its product
is consumed into a write-data register, then written on a separate WRITE edge.
LOAD, READ and WRITE are mutually exclusive, so no RAM read/write collision is
required. A last-bin write precedes the first report read. RAM is never read
for a new command's accumulation before that bin has been overwritten.

For each input: LOAD captures, SQ_REQ issues, SQ_WAIT receives, WRITE commits.
The unchanged square helper uses S carry-save iterations and H=ceil(2S/8)
byte-fold iterations. From accepted input edge0, helper issues at1, produces
valid after S+H+1, is consumed at S+H+2, RAM writes at S+H+3, and the next
input can transfer at S+H+4. Thus II=S+H+4. The first report performs a fresh
synchronous READ/CHECK, S1 square, fixed coefficient scale and one restoring
division. A nonzero report takes at most S+H+DIV_W+12 clocks after the prior
write/retirement; zero-energy bins skip arithmetic. The README's batch bound
also adds4 setup clocks. The actual complex-power example has a small startup
delay and can compute one pending power while the core is occupied; the core
service dominates its sustained interval. No unconditional time bound is
claimed with stalled peers.

At default P24/M16/B64: RAM80*64=5,120 bits, square operands28 bits,
divider73 bits. At supported maximum P32/M64/B256: RAM108*256=27,648 bits,
square operands38 bits, divider99 bits. The helper's carry-save/fold state,
wide divider and bounded coefficient carry chains are the main expected
logic/timing costs. There is no resettable per-bin register bank, input-history
frame RAM, ROM result lookup, external memory or vendor primitive requirement.
Physical BRAM count and DSP mapping are UNKNOWN until a future implementation;
the qualitative structural risk is MEDIUM. No synthesis or placement is run.

## Ownership and independent verification

No commands overlap acquisition or reporting. Output retirement alone advances
the report bin; a held row retains every payload field. Fatal framing errors
stop input immediately, and final-row retirement is a fence before the next
command. Reset cancels partial helper and output work. The example retains one
LAST alongside one in-flight magnitude operation and closes the input side at
the known length or first wrong LAST, preventing orphan magnitude results.

The oracle groups the complete accepted record into columns and uses Python
integer sums, direct powers and Fraction. It models no RAM address state,
incremental register updates, serial square, divider recurrence or RTL FSM.
Preparation occurs only in four archived isolated children after review; no
numerical oracle call is used for planning. The TB consumes literal results,
monitors source/command/output stability and checks distinct future commands
through real handshake and their separate held result. It deliberately does
not infer statistical confidence or use floating-point tolerances.
