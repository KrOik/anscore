# Three-field motion-adaptive directional deinterlacing

Original Apache-2.0 grayscale/Y deinterlacer. Three temporally ordered fields
P, C, N produce one progressive raster at C's sampling time. P and N have the
same parity; C has the opposite parity. This adds a same-parity temporal test
and five-direction spatial reconstruction to the existing paired-field
`common_scaffold/image/deinterlace`, which is unchanged. It is a finite,
backpressured triplet transaction, not a continuous field-rate video receiver.

## Frozen numerical contract

WIDTH/HEIGHT describe the progressive raster. HEIGHT is even. Parity 0 contains
rows 0,2,...; parity 1 contains rows 1,3,... . Each field contains WIDTH*HEIGHT/2
unsigned BITS samples, in increasing field row then x. Send complete P, then C,
then N. `cfg_first_parity` describes P and N, so **C's preserved parity is
`~cfg_first_parity`**. There is no field-order detection or implicit top-first
substitution. Both configuration inputs are sampled on the first accepted,
correctly marked P pixel. Later live configuration changes have no effect.

Every C row is preserved bit for bit. For a missing row y, let U/L be the C
rows immediately above/below it. At a vertical boundary replicate the nearest
C row. Every horizontal sample index below is clamped independently to
`[0,WIDTH-1]`, including the temporal neighborhood and directional scores.

```
M = max(abs(P(x+k,y)-N(x+k,y)))                    k = -1,0,1
T = floor((P(x,y)+N(x,y)+1)/2)
cost(d) = sum(abs(U(x+k-d)-L(x+k+d)))              k = -1,0,1
S(d) = floor((U(x-d)+L(x+d)+1)/2)
```

Choose the minimum cost in the exact priority order **0,-1,+1,-2,+2**; a later
candidate replaces the winner only on strictly smaller cost. If
`M <= latched_threshold`, emit T (`m_source=1`, `m_dir=0`). Otherwise emit the
winning S (`m_source=2`, signed `m_dir=d`). Preserved C pixels use `m_source=0`
and `m_dir=0`. Threshold equality therefore takes the temporal path. There is
no extra vertical preference, temporal clamp, hidden score bias or mode.

Samples/differences/M are unsigned BITS integers. An average adds in BITS+1
bits before a one-bit shift (half-up rounding); a three-term score uses BITS+2
bits, with maximum `3*(2^BITS-1)`. No saturation is needed. Direction is a
signed three-bit integer. Static consistent fields P=N recover missing samples
exactly. Repeated motion can alias between P and N; noise, occlusion and scene
cuts can fool the threshold. This is not motion compensation, cadence recovery,
YADIF/BWDIF or a claim of equivalent image quality.

## Interface and transaction ownership

One clock, synchronous active-high `rst`, with reset overriding CE. Every
transfer, including DONE, requires **`!rst && ce && valid && ready`** at the
rising edge. Ready/valid may remain high while CE=0: ordinary ready/valid peers
must use an explicit CE adapter. All supplied examples retain CE-qualified
semantics throughout; no ordinary ready/valid interface is silently connected.

`s_field_sof` is true only on the first pixel of each field; `s_eol` only on the
last pixel of each field line. `s_parity` must equal the expected field parity
on every transfer. Wrong SOF/EOL/parity discards the **entire triplet**, emits
no raster from that triplet, and enters held DONE with `done_error=1`. After
the error DONE handshake, recovery requires a completely new P,C,N triplet;
remaining pixels from the aborted input must be discarded upstream.

Capture accepts one sample per enabled edge and tolerates source gaps. Output
starts only after all three fields pass marker validation. `s_ready=0` during
processing/output and held DONE. Raster order is left-to-right, top-to-bottom;
SOF/EOL/LAST identify the first pixel, line ends and final pixel. Pixel, source,
direction and all markers remain stable while output is held by ready or CE.
All pipeline stages, RAM read enables and coordinates stop together on output
backpressure. `done_valid` is held after the final output handshake with
`done_error=0`, until a CE-qualified DONE handshake. `busy` covers partial
capture through held DONE. Reset aborts any phase without DONE; RAM is not reset
and is fully overwritten by the next good triplet before reads are enabled.

## Architecture and service budget

Parameters: WIDTH 1..512; even HEIGHT 2..512; WIDTH*HEIGHT <=65536; BITS 8..12.
Default 128x64, BITS8. Three field RAMs contain
`3*WIDTH*(HEIGHT/2)*BITS` logical bits (default **98,304 bits**). P/N each need
one synchronous read port; C needs two concurrent synchronous reads. Capture
and read phases never overlap, so there are no same-address read/write hazards.
The C write port is shared with its upper-row read port. No RAM array has a
reset loop. Four seven-sample shift windows provide the ±3 horizontal extent.
Five parallel three-difference scores and candidate averages feed a registered
selection stage. There are no data multipliers/dividers or external memories.

Each raster line issues WIDTH+6 clamped reads, producing a WIDTH-pixel II=1
burst followed by a six-enabled-edge line gap, before external stalls. The
first output becomes valid after the ninth enabled edge following final
capture, and with always-ready output is accepted on edge 10. Final output
acceptance and entry into held DONE occur `HEIGHT*(WIDTH+6)+3` enabled edges
after final capture. Derivation: each read returns synchronously one edge
after issue; the complete seven-sample window feeds a score register, then the
selection/output register, then the receiving handshake. There are exactly
HEIGHT*(WIDTH+6) requests, plus three drain edges. All five finite simulation
profiles checked the first acceptance, every line interval and final drain.
Before final capture, exactly `3*WIDTH*HEIGHT/2` input transfers are required;
the fastest complete triplet takes that many capture edges plus the stated
output budget. Held DONE release adds an interface handshake. Source gaps,
CE pauses and output/DONE stalls extend service time without an upper bound.
No clock frequency or continuous video bandwidth is promised.

Resource risk: default storage MEDIUM; maximum supported BITS12 geometry
**HIGH** (1,179,648 logical RAM bits, before physical block granularity). Logic
and global-stall fanout MEDIUM/UNKNOWN pending synthesis. Supported geometry
does not imply fit on a particular FPGA. Synthesis, PnR, STA and board work are
outside this delivery; hardware status remains HW_UNVERIFIED.

## Files and finite verification

`files.f` and `example/files.f` are package-root-relative source lists. The
complete CE-qualified RGB preview example renders reconstructed spatial pixels
in a diagnostic tint; it can also display ordinary replicated grayscale.
`SOURCES.md` documents the closure and technical reference boundary.

`python -B run_tests.py` is the intended finite runner from any directory.
It archives exact executable inputs **before numerical preparation**, then
generates and hashes all independent reference vectors **before the first HDL
child**. Each HDL child has a 20-second watchdog and bounded process-tree
cleanup. Any failed/timed-out child stops all later launches; no automatic
retry. PASS also requires the exact ordered plan, preparation and suite
completion, actual simulator completion markers and unchanged sources/vectors.
Raw streams/receipts remain immutable; successful VVPs are retained for the
orchestrator's verified post-commit cleanup. No existing helper is executed.

Receipt `reports/20261106T034957790812Z/results.json`: **12/12 first-attempt
checks PASS**, including five completed simulations. Exact sources, their
archives, plan and all 15 vectors remained unchanged. This is LINT_PASS /
UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED.

| Profile | Original cases | Output comparisons | Marker aborts | Reset events |
|---|---:|---:|---:|---:|
| 1x2, BITS8 | 26 | 74 | 5 | 6 |
| 9x6, BITS10 | 26 | 1,998 | 5 | 6 |
| 7x4, BITS12 | 26 | 1,036 | 5 | 6 |
| 128x64, BITS8 | 3 complete frames | 24,576 | 0 | 1 |
| 9x6 Y8-to-RGB24 preview | 10 | 540 | 0 | 1 |

Total: 28,224 checked output records, 136 DONE handshakes, 15 marker-abort
recoveries, 20 reset events (five initial and 15 live), 14,657 held-output
cycles. Small profiles include complete good replay after each marker fault
and each reset phase, reset with CE=0 during partial capture/read pipeline/
held output/held DONE, source gaps, CE/output/DONE stalls and first-pixel
configuration snapshots. Numerical fixtures cover both parity orders, all
five directional winners, strict tie priority, threshold equality, odd-sum
half-up rounding, fullscale means/scores, horizontal and vertical clamping,
static detail, moving diagonals and deterministic random data. RGB tint and
grayscale modes are checked as complete compositions. Maximum geometry and
invalid-parameter elaborations were not run. Icarus emitted only its array
`@*` sensitivity notices for the five score words; raw notices are preserved.

## Primary reference and originality

Read-only technical review: FFmpeg commit
`f8a03cd98daa81d16948308b5b1612aaaa831500`, actual `libavfilter/vf_yadif.c` and
actual `COPYING.LGPLv2.1`, licensed LGPL-2.1-or-later. `references.json` records
their URLs/hashes. No FFmpeg code is imported, translated, linked or executed.
The fixed equations above are the package's independent algorithm contract.
FFmpeg uses additional temporal differences/bounds from previous/current/next
full interlaced frames, truncating means and different directional decisions;
this three-field temporal gate and exhaustive fixed-priority direction search
does not reproduce it. Existing ANSCORE mature deinterlacing RTL is not modified.
