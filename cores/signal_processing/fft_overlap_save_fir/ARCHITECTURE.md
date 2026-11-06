# Architecture and numerical contract (unexecuted candidate)

The use case is a programmable block FIR for complex baseband streams. The
increment is the complete overlap-save filtering path, including coefficient
transformation, saved input history and automatic finite-stream tail emission.
Existing direct FIR, rational resampler, Farrow delay, correlation and STFT
packages do not implement this path. No throughput or PPA result is inherited.

For N=2**LOG_N and M published taps, B=N-M+1 new samples advance one block.
Each N-sample transform contains M-1 saved samples followed by B new samples.
The first M-1 IFFT outputs are discarded. M=1 therefore has no saved history;
M=N has B=1 and may require N blocks to finish a short finite stream.

## Finite precision, in operation order

1. Sign-preserving DATA_W-bit complex taps are zero padded to N and passed
   through the unchanged stream_fft forward transform with scale_mask=0.
2. Each complete complex time block is passed through the same transform,
   forward and with scale_mask=0.
3. For each bin, four signed DATA_W-by-DATA_W real products produce the full
   complex product in 2*DATA_W+1 bits. A single nearest-even right shift by the
   published coefficient fractional-bit count is followed by DATA_W saturation.
4. Products pass through stream_fft in inverse mode with every scale bit one.
   This supplies 1/N normalization through LOG_N individually rounded stages.

stream_fft uses signed18 Q2.16 roots, a full butterfly product/sum, one RNE
shift by16+scale at each stage and signed DATA_W saturation. Its complete257-entry
quarter-wave ROM is embedded in its single source. There are no external .mem
files, generated tables, Python modules or network services in the RTL closure.

The accepted numerical definition is this staged integer chain. It is not an
exactly rounded ideal DFT or ideal time-domain convolution. A Python oracle will
independently implement recursive butterflies and signed-magnitude RNE. An
ideal convolution comparison is a separately labelled sanity check on selected
unclipped, exactly representable cases only. Coefficient-transform clipping can
alter the effective filter; its sticky overflow/inexact flags accompany every
subsequent output until new coefficients publish.

## Operators, storage and scheduling

One unchanged stream_fft instance is reused for coefficient FFT, data FFT and
IFFT. It contains one DATA_W-by18 multiplier and one N-word complex state RAM.
New RTL adds one shared DATA_W-by-DATA_W multiplier. Four products are scheduled
over separate states, then combined before quantization. The two multipliers
are in separate modules and are budgeted as two operators even though jobs do
not overlap. No multiplier-per-bin or parallel FIR-tap array is introduced.

Three further N-by-2*DATA_W memories hold (a) time/history, (b) published H and
(c) spectral/product data. Every read is synchronous; payload RAM is unreset.
Each memory has at most one read and one write per edge, and the schedule never
uses a same-address read/write collision. Source feed alternates read/request
and held ready/valid send. The product loop reads H and spectrum together.
Ascending history copies move source B+i to destination i; source is always
strictly greater than destination, so overlap when B<M-1 is safe.

Fill, transforms, product, output drain and history copy are sequential. Without
external stalls a data block takes O(N*LOG_N) clocks; each FFT schedules14 clocks
per butterfly. A finite tail may require ceil((L+M-1)/B) blocks. This architecture
accepts input/output bursts under ready/valid and makes no continuous sample-rate
or II=1 claim. Unbounded input pauses/output backpressure remove finite latency.
No synthesis, mapping, PnR, STA, board or power experiment is authorized here.

## Publication, history and termination

Configuration and data commands arbitrate only in IDLE, with configuration
priority. Taps first occupy the spectral scratch RAM. Invalid length/fraction,
invalid tap or malformed LAST preserve the old H and old history. Only a complete
legal tap frame is transformed. While H is replaced, all other commands remain
blocked. A successful held configuration reply publishes captured metadata and
invalidates old history only on its retirement; no command can observe the
speculative H payload. An unexpected FFT protocol fault invalidates coefficient
validity because H may be partially replaced. Reset invalidates all configuration
and history, cancels replies/results and resets the FFT synchronously.

A normal data command requires exactly B actual inputs and returns B outputs.
An end command accepts L=0..B inputs, zero pads the current block, then internally
runs additional zero blocks until L+M-1 outputs have retired. This includes a
zero-input tail command after full blocks. A zero-input end on a fresh/restarted
empty stream returns one successful EMPTY marker; M=1 also has an empty tail.
The final end output carries LAST; unused padded output samples are drained
internally. busy can remain high briefly after LAST while that drain completes.
End completion invalidates history. Restart begins from M-1 actual zero words.

Data input damage is detected before any output and returns one error marker,
invalidating history while preserving the published filter. Invalid command
counts and NO_CONFIG consume no input and preserve history. An unexpected FFT
fault can occur after earlier tail blocks emitted output; its terminal error
marker therefore terminates an incomplete command rather than rolling back
already accepted samples. The FFT receives a full synchronous reset edge before
that marker/reply becomes visible. There is no drain-to-LAST input recovery.

Every ordinary output reports the cumulative command flags, including current
IFFT frame flags, which are final for that frame before its first output. Flags
can become set on a later internal tail block. Payload, flags, tag, index and
LAST remain stable while a particular output is stalled.
