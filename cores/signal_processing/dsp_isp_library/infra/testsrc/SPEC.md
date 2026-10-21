# INFRA-07 stream data-source / data-sink checker cores

Test-instrument cores for the DSP/ISP library: deterministic sequence and
pattern sources, a controlled-backpressure sink, a CRC-32 transport helper and
a per-beat stream checker. **CRC is a transport aid only** — numerical
acceptance of any DUT remains per-result comparison against an independent
model (goal.md §5, requirement INFRA-07).

All cores use a single `clk`, synchronous active-low `rst_n`, and the library
Stream contract: transfer only on a rising edge with `rst_n && tvalid &&
tready`; held `tdata/tvalid/tuser/tlast` stay stable under backpressure;
sources never wait for `ready`. Reset clears valid, flags, counters and
configuration; it never clears large RAM (there is none). All counters are
32-bit saturating at `0xFFFFFFFF` unless noted; they never wrap silently.

## Atomic configuration

Every core has `cfg_valid`/`cfg_ready` plus `cfg_done`/`cfg_error`.
`cfg_ready = rst_n` (always able to accept). An edge with
`cfg_valid && cfg_ready` commits the whole field set atomically:

- Legal fields: all fields latch together, **all** internal state (output
  slot, counters, position, LFSRs, error flags, done/armed) clears, the core
  arms, and `cfg_done` pulses in the following cycle. A held unaccepted
  output beat is discarded — an accepted reconfiguration is a stream
  discontinuity by definition.
- Illegal fields: nothing changes (fields and stream state are preserved),
  `cfg_error` pulses in the following cycle. Legality is evaluated per core
  below; `cfg_done` and `cfg_error` are mutually exclusive.

After reset a core is unarmed: sources emit nothing (`m_tvalid=0`), sinks
drive `s_tready=0`. A first legal configuration arms the core.

`trigger` is a registered one-clock pulse. It is asserted in the same cycle
in which the triggering condition becomes visible (i.e. registered at the
edge that caused it); exact causes are per core below. `trigger` is never
combinational and never asserts during reset or before arming.

## crc32

CRC-32 (IEEE 802.3): reflected polynomial `0xEDB88320` (normal `0x04C11DB7`),
init `0xFFFFFFFF`, xorout `0xFFFFFFFF`, refin/refout true. `DATA_WIDTH>=1`
(default 16). Each accepted beat consumes `s_tdata` **LSB-first**, bit 0 first
in time; a 16-bit word therefore equals two little-endian bytes and matches
`zlib.crc32(word.to_bytes(2,'little'))`, and `DATA_WIDTH=8` equals one byte
per beat.

Ports: `s_tdata/s_tvalid/s_tlast`, `s_tready=rst_n` (always accepts);
`init` (synchronous). `state[31:0]` is the running pre-xorout state.
Semantics per edge:

- `init` reseeds the base to `0xFFFFFFFF`; a beat accepted on the same edge
  is folded into the fresh seed (`state <= step(0xFFFFFFFF, data)`).
- An accepted beat with `s_tlast` latches `result <= step(state,data) ^
  0xFFFFFFFF`, pulses `done` for one cycle, and reseeds `state` — frames
  can be checked back to back without an extra init edge.

## prbs_source

PRBS-16 word source, `tdata` fixed 16 bits unsigned. Fibonacci right-shift
LFSR: serial output bit = `state[0]`; feedback = parity of
`state & 16'h002D` (bits 0,2,3,5), inserted at `state[15]`. Characteristic
polynomial `x^16+x^5+x^3+x^2+1`, the reciprocal of `x^16+x^14+x^13+x^11+1`;
primitive — serial period 2^16-1 = 65535 (verified in the model suite).

Each beat emits 16 consecutive serial bits packed MSB-first: `tdata[15]` is
the first bit in time, `tdata[0]` the 16th. Word k is generated from state
`S_k`; `S_0 = cfg_seed`, `S_{k+1}` = state after 16 steps. Seed 0 is legal
and degenerate (locks at 0, emits `0x0000` words).

Config: `cfg_seed[15:0]`, `cfg_nwords[31:0]` (0 = unlimited), `cfg_trig_mode`,
`cfg_trig_period[31:0]`. Illegal: `trig_mode>1`; `trig_mode==1 &&
trig_period==0`.

Behaviour: on arming, `m_tdata` = word 0 and `m_tvalid=1`; every transfer
edge advances to the next word (II=1 while `m_tready`). After the
`cfg_nwords`-th transfer `m_tvalid` drops and `done` latches until reconfig.
`word_count` saturates. Trigger mode 1: pulse after every
`cfg_trig_period` accepted words (coincident with the `word_count` value
reaching each multiple).

## tone_source

Multi-tone / swept-tone NCO source, `m_tdata` signed16 Q1.15, II=1.
Static parameter `MAX_TONES` (default 4, support 1..4).

Phase accumulators are Q0.32 (phase in cycles * 2^32). Sine via quarter-wave
ROM: 64 entries, midpoint sampled,
`LUT[i] = round(32767*sin(pi/2*(i+0.5)/64))`, `phase[31:30]` = quadrant,
`phase[29:24]` = index; Q0 `+LUT[i]`, Q1 `+LUT[63-i]`, Q2 `-LUT[i]`,
Q3 `-LUT[63-i]`. Effective 256-point resolution; peak ≈ ±32765.
Mix: `acc = sum_i amp_i * sine_i` (signed 34-bit), output
`sat16((acc + 2^14) >>> 15)` — round half up, then saturate once.

Sample k uses phase `init + k*inc`; phases advance after each transfer.

Config: `cfg_mode` (0 multitone, 1 sweep), `cfg_ntone` (1..MAX_TONES;
sweep uses tone 0 only), packed `cfg_inc[32*MAX_TONES-1:0]`,
`cfg_phase[32*MAX_TONES-1:0]`, `cfg_amp[16*MAX_TONES-1:0]` (tone 0 in the low
bits), `cfg_sw_step[31:0]` signed, `cfg_sw_stop[31:0]`,
`cfg_sw_dwell[15:0]`, `cfg_nsamp[31:0]` (0 = unlimited), `cfg_trig_mode`,
`cfg_trig_period`. Illegal: `mode>1`; `mode==0 && (ntone<1 ||
ntone>MAX_TONES)`; `mode==1 && sw_dwell==0`; `trig_mode>2`;
`trig_mode==2 && trig_period==0`.

Sweep (mode 1): `inc_cur` starts at `cfg_inc[31:0]`; after every
`cfg_sw_dwell` emitted samples `inc_cur += cfg_sw_step`; if `step>=0 &&
inc_cur > sw_stop` or `step<0 && inc_cur < sw_stop` then `inc_cur` reloads
`cfg_inc[31:0]` and a sweep-wrap event occurs (sawtooth sweep, also
down-sweep for negative step). `step==0` is a fixed tone. Trigger mode 1:
pulse on each wrap (coincident with the wrap edge). Trigger mode 2: pulse
after every `trig_period` accepted samples, like prbs_source.
`sample_count` saturates; `done` latches after `cfg_nsamp` transfers.

Uses MAX_TONES parallel signed 16x16 mix products — up to 4 Gowin DSP cells
at default; set `MAX_TONES` lower to save DSPs. This is an instrument core,
not a synthesis-lean datapath.

## image_pattern_source

Sequence-numbered test-frame source, `tdata` = `DATA_WIDTH`-bit unsigned
pixel (default 8), `tuser` = SOF at pixel (0,0) of every frame, `tlast` =
EOL at x == W-1 of every line. II=1; pixels stream in raster order
(x fastest, then y, then frame).

Pixel (0,0) of each frame carries the **frame sequence number**
`frame mod 2^DATA_WIDTH` (SOF and sequence co-located); all other pixels
follow `cfg_pattern`:

| pattern | pixel v(x,y), M = 2^DATA_WIDTH-1 |
|---|---|
| 0 HGRAD | `x & M` |
| 1 VGRAD | `y & M` |
| 2 DIAG  | `(x+y) & M` |
| 3 CHECKER1 | `((x+y)&1) ? M : 0` |
| 4 CHECKER8 | `(((x>>3)+(y>>3))&1) ? M : 0` |
| 5 COLORBAR | `floor(8x/W) * (M/7 floor)`; 8 bars 0..7*36 for 8-bit |
| 6 SOLID | `(37*frame) & M` |

Config: `cfg_w[15:0]`, `cfg_h[15:0]` (1..MAX_W/MAX_H, static bounds default
4096), `cfg_pattern[2:0]`, `cfg_nframes[15:0]` (0 = unlimited),
`cfg_trig_mode`, `cfg_trig_frame[15:0]`. Illegal: `w==0 || w>MAX_W`;
`h==0 || h>MAX_H`; `pattern>6`; `pattern==5 && w<8` (COLORBAR needs >=8
columns); `trig_mode>4`.

Trigger modes: 0 off; 1 pulse at each SOF transfer; 2 pulse at each EOL
transfer; 3 pulse at SOF of frame `cfg_trig_frame` (compared to the low 16
bits of the frame index); 4 pulse at the last pixel of each frame (EOF).
`frame_count` (completed frames) and `pixel_count` saturate; `done` latches
after `cfg_nframes` complete frames; the frame index itself counts mod 2^16.

## backpressure_sink

Stream drain with deterministic seedable backpressure, `DATA_WIDTH` param
(default 16). `s_tready = rst_n && armed && pattern`. The pattern is a
free-running function of the clock (advances every cycle while armed,
independent of transfers), so the stall sequence is exactly reproducible
from the seed:

| cfg_mode | ready pattern |
|---|---|
| 0 | always 1 |
| 1 | `(lfsr[7:0] >= cfg_threshold)`; lfsr = PRBS-16 step each clock |
| 2 | cyclic: ready `cfg_run` clocks then stalled `cfg_stall` clocks |

Illegal: `mode>2`; `mode==2 && run+stall==0`; `trig_mode>1`;
`trig_mode==1 && trig_period==0`. `mode==2 && run==0` is a legal
always-stalled sink. Seed 0 is legal (locks LFSR at 0).

Observability tap: registered `beat` pulse plus `beat_data/beat_user/
beat_last` mirror each accepted beat one cycle later — wire `beat` to a
checker's `s_tvalid` to observe exactly the transferred sequence.
`count` saturates; trigger mode 1 pulses after every `trig_period` accepted
beats.

## stream_sink_checker

Passive stream checker, `DATA_WIDTH` param (default 8). `s_tready = rst_n &&
armed` — always accepts once armed; it never stalls a source. Checks are
performed per accepted beat; all error flags are sticky until reconfig or
reset, and `first_error` records the 0-based index of the first flagging
beat (`0xFFFFFFFF` = none).

Config fields: `cfg_expected[31:0]` (>=1, beats to a clean `done`),
`cfg_crc_en`, `cfg_crc[31:0]`, `cfg_seq_en`, `cfg_seq_start`,
`cfg_seq_step` (mod 2^DATA_WIDTH), `cfg_img_en`, `cfg_img_w`, `cfg_img_h`,
`cfg_trig_mode`, `cfg_trig_period`. Illegal: `expected==0`;
`img_en && (w==0 || h==0)`; `trig_mode>3`; `trig_mode==3 && period==0`.
Enables combine freely.

Checks:

- **count**: `done` latches when `count` reaches `cfg_expected`; beats after
  `done` set `err_extra`. Fewer beats than expected is observed as `done`
  never asserting (test-visible timeout), never as a silent pass.
- **crc** (`crc_en`): a `crc32` core tracks every beat; one edge after the
  done beat the post-beat state is XORed with `0xFFFFFFFF` and compared to
  `cfg_crc`; mismatch sets `err_crc` with `first_error` = index of the done
  beat (`expected-1`).
- **seq** (`seq_en`): `tdata` must equal the sequence register, which starts
  at `cfg_seq_start` and adds `cfg_seq_step` (mod 2^DATA_WIDTH) per beat;
  mismatch sets `err_seq`.
- **image markers** (`img_en`): expected `tuser` = (x==0 && y==0),
  `tlast` = (x==W-1) walking raster position (x,y); mismatches set
  `err_sof`/`err_eol`. `frames` counts beats with `tuser=1` wherever seen.

Trigger modes: 0 off; 1 pulse when the first sticky error flag asserts
(coincident with the flag); 2 pulse when `done` asserts; 3 pulse after
every `trig_period` accepted beats.

## Latency / II summary

| core | output latency from arm | steady II | notes |
|---|---|---|---|
| prbs/tone/image sources | first beat valid the cycle after cfg accept | 1 | continuous while ready |
| crc32 | `done` 1 cycle after tlast beat | 1 | always ready |
| backpressure_sink | n/a (sink) | 1 | ready is pattern-limited |
| stream_sink_checker | flags 1 cycle after flagging beat | 1 | always ready when armed |

No core has internal buffering; a stalled source holds its beat forever.
Reset during a held beat or mid-frame discards it; reconfiguration is
required to re-arm after reset.
