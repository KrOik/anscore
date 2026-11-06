# Buffered burst CFO correction

`burst_cfo_correct` captures an aligned complex burst, qualifies its repeated
32-sample prefix using the actual existing `sync12_phase`, derives a feed-forward
frequency correction, and replays **every sample from index0**, including the
prefix. The new capability is automatic acquisition plus full-burst corrected
replay. Existing trigger capture, raw repetition metrics, configured DDC and
closed-loop Costas services are unchanged.

The source is original Apache-2.0 ANSCORE code. Baseline
`1e9e9130cef71127d2c8d2762affe815b067b9f5`. At source-review stage:
RTL_CANDIDATE / INTEGRATION_CANDIDATE / HW_UNVERIFIED. Numerical preparation
and HDL are NOT_RUN until root's complete source/model/TB/plan review and
explicit first-run authorization.

## Algorithm and principal branch

Packed IQ is `{Q[11:0],I[11:0]}`, signed12 integer components. The caller aligns
the first two unknown length16 repeated halves. Qualification computes exact
P=sum(conj(first[k])*second[k]) and E=sum(abs(prefix[n])^2), includes the energy
floor, and compares `4*abs(P)^2/E^2 >= threshold_q16/65536`. No known training
sequence is required. The prefix may be imperfect; all numerical guarantees
refer to its exact integer P rather than a true physical carrier.

The signed24 binary-turn angle estimates positive omega*16. The negative
correction is `FCW32=-(signextend(phase24)<<4)`, with accumulator phase0 for
sample0. Phase advances after accepted outputs, independent of wall-clock
stalls. The principal frequency branch is[-Fs/32,+Fs/32), moduloFs/16. Codes
within4 of the signed half-turn are explicitly rejected to prevent a circular
phase approximation from silently selecting the opposite frequency branch.
This is not an out-of-branch alias detector, frame finder, absolute phase
recovery, equalizer or full OFDM receiver.

Q2.16 coefficients come from unchanged `stream_sincos` P32/W18/ITER24. One
unchanged A18/B12 unsigned serial multiplier is shared for four exact real
products. Sign restoration, signed32 sum, RNE shift16 and signed12 saturation
complete the complex rotation. `m_clip[0]` is I saturation, bit1 Q saturation.
The complete angle/rotation/rounding budget is in ERROR_BOUND.md: phase error
<=2 circular phase24 codes; coefficient error<=1 Q2.16 LSB; whole-burst IQ
comparison against direct exact-P rotation<=2 integer LSB/lane for N<=4096.

## Interface and ownership

All public ports share one clock, standard valid&&ready, no CE. `rst` is
synchronous high, masks all ready/valid, discards the owned command and flushes
helpers without emitting a marker. The serial helper's asynchronous-low reset
is driven only by a registered, rising-edge-origin bridge. RAM payload is not
reset; complete capture precedes every replay read. No CDC is present.

Parameters: MAX_SAMPLES32..4096, default256; TAG_W1..32, default8. A command
snapshots full32-bit `c_samples` (32..MAX), full32-bit `c_threshold_q16`
(1..65536), full64-bit `c_min_energy` (must fit unsigned29), and tag. Validation
uses these complete fields before narrowing. Length takes precedence over
threshold, then floor. Mutation of command pins during ownership has no effect.

Exactly N accepted input tokens follow. `s_last` must be true only at indexN-1.
The first32 transfers are atomic with the actual estimator; internal LAST is
synthesized at index31 even for longer bursts. After index31, payload capture
can continue while acquisition runs. Prefix failure still consumes the full
declared N. A malformed LAST aborts immediately, flushes helper control and
emits one held marker; any subsequent upstream tokens belong to no command and
must stop until the caller explicitly starts another burst. Reset is the only
external cancellation. No watchdog or input resynchronizer is supplied.

Output waits for full capture and the estimate. Success emits N ordered
records with status0, corrected IQ, zero-based32-bit index, LAST only on N-1,
unchanged tag and constant estimated phase24/correction32. All fields hold
together under backpressure. The core owns the command through final record
acceptance and admits no same-edge command fallthrough. A stalled output adds
wall-clock time; it never changes the phase of a later sample.

Any error emits one LAST record with zero IQ/clip/phase/correction. Marker index
is the accepted offending input index for status4 and0 otherwise. Tag is kept.

| Status | Meaning |
| --- | --- |
| 0 | Corrected IQ record |
| 1 | Invalid full-width sample count |
| 2 | Invalid full-width Q16 threshold |
| 3 | Energy floor does not fit29 bits |
| 4 | Early or missing outer LAST; helper flush before marker |
| 5 | Prefix zero energy or zero P |
| 6 | Prefix below energy floor or repetition threshold |
| 7 | Estimated phase inside signed half-turn guard |
| 8 | Unexpected estimator status / arithmetic helper fault |

## Architecture and service budget

One burst RAM of24*MAX bits is written only during capture and synchronously
read only after capture completes. No collisions, multiple outstanding bursts
or ping-pong banks occur. Storage is6144bits at default256 and98304bits at4096;
the existing prefix rings add1952bits. A nonpower capacity such as97 is legal.
Addresses use clog2(MAX), length clog2(MAX+1), preserving the4096 boundary.

Prefix acquisition has four existing signed13 multiplier operators in the
complex helper. Its wide qualification multiplier and the replay multiplier
are separate physical serial instances; they are not described as one shared
device across both engines. Replay adds no inferred dynamic `*`, DSP or ROM.
Sincos is one iterative shift/add engine. Default resource risk MEDIUM;
maximum storage risk HIGH. RAM/DSP mapping, fit, power and Fmax are unmeasured.

After helper command arming, uninterrupted prefix input II=9; first to32nd
sample acceptance is279 clocks. Input acceptance from index32 onward is II1.
Acquisition overlaps payload capture; neither becomes a streaming receiver.
One replay sample uses synchronous RAM read,26-clock sincos transfer, four
17-clock full-product transfers with separate issue transitions, one sum stage,
one quantization stage and output retirement. Unstalled accepted-output II=103
clocks; a held current output adds its stall to the interval. First output
also waits for complete capture and estimator completion. These are RTL cycle
budgets, not measured hardware rates. Unbounded source/output stalls give no
finite wall-clock deadline.

`example/burst64_cfo.sv` exposes the same real acquisition/rotation service with
MAX64/tag8. `files.f` closes all actual dependencies; invoke from this package
directory. The example list explicitly lists the same dependencies and its top.

## Frozen finite checks

PRECHECK_PLAN specifies10 children: default/example syntax, then four compile/
simulation pairs (MAX32/tag1, nonpower97/tag8, MAX4096/tag32, actual64 example).
The4096 profile includes one full-capacity replay. Tests include both rotation
signs, unknown prefix, axes and small/nonaxis P, zero/qualification failures,
exact energy and threshold boundaries, guard rejects and separated branches,
signed endpoints, saturation, early/missing LAST, complete recovery, parameter
snapshots, held outputs, reset across acquisition/replay/output stages, forced
estimator-fault mapping, prefix/payload II and replay II.

The guarded runner refuses any existing report entry, archives all20 exact
inputs before importing the model, persists INCOMPLETE checkpoints, prepares
four immutable vector files before the first HDL child, then executes only
the finite sequence. Every child has20s execution plus bounded7s cleanup;
failure stops later launches. No repair, retry or successful-profile rerun.
Every simulation's reported profile and accounting must match the independently
prepared counts plus the fixed reset/fault suite, including one-to-one phase,
coefficient and exact-arithmetic checks for every successful IQ record.
Run only after explicit root source/plan approval:
`python run_tests.py --execute-approved-plan`.

No synthesis, PnR, STA, board, old regression or external program execution is
part of this package. Helper historical claims are not inherited. SOURCE
provenance and official fixed read-only references are in SOURCES.md.
