# CSC specification and independent models

Status: RTL and real Icarus simulation passed; board acceptance pending. Legacy
`wave2_ip_20k/src/isp_csc.v` and its CE41D92D contract remain unchanged.

Supported configurations: 8/10-bit unsigned samples, BT.601 (Kr=.299, Kb=.114)
or BT.709 (Kr=.2126, Kb=.0722), Full/Limited, RGB to YCbCr, inverse, and
RGB to gray. Gray is encoded luma in the selected range, not linear-light luminance.
RGB is always full code range. Packed channel convention is MSB first R/G/B
or Y/Cb/Cr; gray uses one sample. No chroma subsampling occurs.

Let M=2^B-1 and S=2^(B-8). Full uses Yoffset=0, Yspan=Cspan=M;
Limited uses Yoffset=16S, Yspan=219S, Cspan=224S. Chroma midpoint is
2^(B-1), including Full (128 or 512), not M/2. With RGB normalized by M:
Y=Kr R+(1-Kr-Kb)G+Kb B; Cb=(B-Y)/(2(1-Kb)); Cr=(R-Y)/(2(1-Kr)).
Encode using offsets/spans. Inverse first removes these offsets and spans.
All input codes are accepted, including Limited foot/headroom; final outputs
saturate to [0,M], not nominal studio limits. Full extreme chroma can reach
M+0.5 before rounding and saturates. No wraparound.

`floating` directly evaluates normalized signal equations. `matrix` derives
affine coefficients with exact rational arithmetic independently of those float
calculations; `bit_exact` accumulates integer products then rounds once.
Coefficient format is signed 19-bit with 16 fractional bits (range [-4,4));
coefficients rounded nearest, ties away from zero. Inputs are offset before
multiplication. A signed 32-bit accumulator bounds three absolute
products (<3*4*1023*65536 plus offsets). Final shift also
rounds nearest, ties away from zero, followed by saturation. No intermediate
saturation. Model maximum analytic code error is 0.5+3M/(2*65536) codes.

`csc_stream.v` uses synchronous active-low reset, pixel-bound SOF/EOL and
one elastic output slot under the shared Stream contract. No-stall latency is
one cycle; II=1, including configuration transitions. Ready is combinational
`!m_tvalid || m_tready`; chain through a shared FIFO when ready depth matters.
It does not validate frame dimensions or markers. No frame RAM or tail flush.
Gray occupies the high BITS bits and both lower channels are zero. All data
and marker bits hold under stall. Reset discards output and pending config,
restores BT601 Full forward mode, and clears error synchronously.

Configuration ports: cfg_mode=0 forward, 1 inverse, 2 gray, 3 invalid;
cfg_standard=0 BT601, 1 BT709; cfg_limited=0 Full, 1 Limited. One pending
configuration slot accepts cfg_valid && cfg_ready; source must hold all fields
while blocked. A pending config commits on an accepted SOF, including that
pixel, and all fields switch atomically. Full pending slot blocks new config
except on its commit cycle. Simultaneous commit/new configuration puts the
new configuration in pending for the next SOF. A newly accepted config cannot
affect a simultaneous SOF unless it was pending before that edge. Mode 3 is
consumed with a one-cycle cfg_error pulse, leaving configuration unchanged.
No configuration apply acknowledgment is provided; commit is determined by
the specified SOF transfer. All image codes are legal. BITS outside 8/10 is
unsupported and produces a simulation fatal error.

The nine Q16 products use explicit signed shift-add arithmetic (no multiply
operators); II is not reduced to share DSPs. Resource and physical timing
qualification remains separate from functional simulation.

Run from repository root:
`python cores/signal_processing/dsp_isp_library/isp/test_csc_model.py`.
Tests cover 24 configurations, corners, every neutral level, seeded random
samples, black/white/midpoint anchors, signed rounding ties, illegal inputs and
analytic error envelope. This is sampled color-space coverage, not exhaustive
RGB-cube proof and not protocol verification.

RTL/protocol reproduction: `python cores/signal_processing/dsp_isp_library/isp/test_csc_rtl.py`.
The driver generates coefficient ROM and independent expected cycles before
real iverilog/vvp execution, records input/trace/log/hash in a fresh evidence
directory, checks every ready/valid/error cycle and every valid data/marker,
and verifies rejection of data, order, count, valid, SOF and EOL mutations.
Tests include every configuration, corners, all neutral levels, random colors,
source bubbles, output backpressure, full-rate regions, reset cancellation,
pending configuration backpressure, and simultaneous commit/replacement.
