# DSP-06 correlation / matched-filter stream

Streaming sliding correlation of signed real or complex samples against a
runtime-loaded template of 1..MAX_TAPS signed DW-bit taps (default
DW=16, MAX_TAPS=64, ACCW=48, POSW=16). Input `s_tdata[2*DW-1:0]` packs
`{im, re}`; in real mode only `re` is read and the `im` field is ignored
(content is a don't-care). Template tap k occupies
`cfg_taps[2*DW*k +: 2*DW]` = `{im,re}`; taps at indices >= ntaps are ignored
and may carry arbitrary signed values.

## Function

For every emitted lag position n the core produces

    y[n] = sum_{k=0..M-1} x[n-k] * w[k],   w[k] = conj^?(taps[dir ? k : M-1-k])

with exact integer arithmetic: each complex product step contributes
`x_re*w_re -/+ x_im*w_im` to `re` and `x_re*w_im +/+ x_im*w_re` to `im`
(signs selected by the conj bit; in real mode only `x_re*w_re` accumulates).
No rounding, scaling or saturation is applied anywhere; the signed ACCW
accumulator has the documented bound |re|,|im| <= ntaps*2^(2*DW-1)
(<= 2^37 for DW=16, ntaps<=64), so ACCW=48 cannot overflow. All output
values are unnormalized integer LSB products.

Direction: dir=0 (correlation order) detects the uploaded tap sequence in
stream order and reports the trailing-edge lag n = match_start + M - 1.
dir=1 (convolution order) multiplies hist[k] by tap[k] and therefore detects
the time-reversed tap sequence, also reporting the trailing-edge lag.
conj conjugates the effective taps and is legal only in complex mode.

## Frames, markers and tail handling

Frames are marker-delimited: `s_tuser`=1 on the first sample of a frame,
`s_tlast`=1 on the last; both set gives a legal single-sample frame. History
is cleared at every frame start, so frames never leak into each other.
Marker violations set the sticky `marker_error` flag (cleared only by
reset) and are tolerated: a missing SOF is treated as a frame start, an
unexpected mid-frame SOF aborts the open frame (its already-emitted beats
stay valid, no group end and no peak are produced for it) and starts a new
one. Frame length above 2^POSW-1 samples, or FULL-mode tail positions past
2^POSW-1, also flag `marker_error` as position counters wrap.

Tail modes (cfg_tail): 0=VALID emits only full-overlap positions
n=M-1..N-1 (N-M+1 beats, requires N>=M; a shorter frame emits nothing and
its peak summary carries p_error=1 with p_pos=all-ones). 1=FULL emits
N+M-1 positions n=0..N+M-2, with the first M-1 partial-overlap outputs and
M-1 trailing zero-stuffed outputs computed by shifting zeros into the
history after s_tlast.

## Outputs

`m_tdata[2*ACCW-1:0]` packs `{im, re}` of y[n] (im reads 0 in real mode),
`m_pos` carries the lag n, `m_tuser` marks the first beat of each frame's
output group, `m_tlast` the last. One beat per emitted position, fields held
constant while `m_ready` is low. The per-frame argmax summary channel
`p_pos/p_tdata{im,re}/p_mag/p_error/p_valid` rises after the last data beat
of the frame is accepted and holds until `p_ready`. Argmax uses the L1
magnitude proxy |re|+|im| (p_mag) and strictly-greater comparison, so ties
keep the earliest position; p_tdata carries the winning correlation value,
not the proxy. Error frames report p_pos=all-ones, zero value and p_error=1.

## Configuration

`cfg_valid/cfg_ready` + `cfg_ntaps`, `cfg_mode[3:0]` (bit0=complex,
bit1=dir, bit2=conj, bit3 reserved must-be-0), `cfg_tail[1:0]`,
`cfg_taps[MAX_TAPS*2*DW-1:0]`. `cfg_ready` asserts only at a clean boundary:
state idle, no open frame, no pending output (pending data beats and the
peak beat must drain first). Asserting `cfg_valid` at that boundary blocks
new input; a mid-frame assertion is held and never accepted early, and does
not stall the running frame. Illegal fields (ntaps<1 or >MAX_TAPS, tail>1,
mode bit3 set, conj without complex) reject the whole request atomically:
`cfg_done`+`cfg_error` pulse, previous configuration retained. Legal updates
pulse `cfg_done` with `cfg_error`=0. Synchronous active-low `rst_n` aborts
any frame/output and selects ntaps=1, real, dir=0, conj=0, tail=VALID,
tap0=+32767 (y[n]=32767*x[n], an identity-scaled passthrough).

## Timing (measured by the cycle regression)

Serial two-multiplier MAC; no II1 claim. steps = ntaps (real) or 2*ntaps
(complex). First/only output `m_valid` rises steps+1 cycles after the
accepting edge; consecutive output rises are steps+2 apart when a frame is
continuously fed and drained, steps+1 for zero-stuffed tail positions.
Sample accept pitch is steps+2 cycles. `p_valid` rises one cycle after the
frame's last data beat is accepted. A VALID frame with N<M emits no data
beats. Downstream stalls only delay outputs; order and values are fixed.

Buffer capacity is one emitted result (the registered output); input stalls
while a beat is pending. No BRAM; history and template are fabric registers
updated only on accepted edges, so no read data is held across stalls.
Isolated `synth_gowin` mapping only; no routed timing or board claim.
