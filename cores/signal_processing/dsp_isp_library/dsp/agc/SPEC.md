# DSP-07 agc_stream: feed-forward automatic gain control

Signed16 streaming AGC with SOF/EOL markers, a leaky mean-|x| energy
estimator, octave-code (log-domain) gain loop with configurable attack /
release / estimator time constants, linear-slew mode, mute, bypass,
gain-range limits and saturating output with a sticky clip flag.

## Level and gain code units

All loop quantities are in *codes*: one code = 1/8 octave ~= 0.7526 dB.
Level code of magnitude e in [0,32768] is `8*msb(e) + frac`, where `frac`
is the top three bits below the most significant bit (zero padded), and 0
for e=0.  Code 120 corresponds to |x|=32768 (0 dBFS).  Level code of a
quiet/silent input is 0.

The gain state `gq` is a signed code with 4 fraction bits.  The applied
integer code is `gc = floor((gq+8)/16)` (round half up).  `gc` decomposes
into `sh = floor(gc/8)` and `f = gc mod 8`; the linear multiplier is
`mant = round(32768 * 2^(f/8))` from an 8-entry LUT
{32768,35734,38968,42495,46341,50535,55109,60097} (max LUT error 0.25 LSB).
The effective gain is `mant/32768 * 2^sh`.

## Exact gain law and loop update

Per accepted sample x:

```
env  += sign(ax8 - env) * max(1, |ax8 - env| >> est)     ax8 = |x|<<8
lvl  = level_code(env >> 8)                              // committed env
gdes = clamp(target - lvl, gmin, gmax)                   // integer code
diff = (gdes << 4) - gq                                  // q4 domain
rate = attack if diff < 0 else release                   // gain down = attack
gq  += sign(diff) * step
   log mode (mode=0):  step = max(1, |diff| >> rate)     // exp + 1-LSB tail
   lin mode (mode=1):  step = min(|diff|, 32768 >> rate) // constant slew
y    = sat16( RNE(RNE(x * mant / 32768) << sh) )         // both signs, ties even
```

`env` is Q23.8 in [0, 2^23]; `gq` is signed13 in [-4096, 4080].  Both
updates use `step <= |diff|`, so they never overshoot and always converge
exactly (no deadband).  Loop updates happen once per accepted sample
(sample-rate loop), independent of markers, resets, or stalls.

Attack applies when gain must decrease (signal above target); release
when it must increase.  In log mode the *rate* field is a binary shift of
the error, so larger values are slower (time constant ~2^rate samples for
large errors).  In linear mode the slew quantum is `32768>>rate` q4 codes
per sample, so rate=15 is instantaneous and rate=0 creeps at 2048
codes/sec at 1 sample/cycle; in both modes a larger configured value is
slower.

## Mute, bypass, clipping, dynamic range

`c_bypass` outputs x unchanged (clip flag never set); `c_mute` outputs 0
while the loop keeps tracking; the clip flag reports saturation of the
gain path even while muted.  `gmin`/`gmax` bound the desired gain code
(dynamic range).  Output saturation is RNE rounding then signed16 clamp;
any saturation sets `clip_sticky`, cleared by reset or any accepted
configuration.

## Interface and update contract

`clk`, synchronous active-low `rst_n`.  Input `s_tdata/s_tvalid/s_tready`
plus `s_tuser` (SOF) / `s_tlast` (EOL) markers; output
`m_tdata/m_tuser/m_tlast/m_tvalid/m_tready`.  Markers are transport
delimiters carried with their sample; they do not alter AGC state.  Four
pipeline slots advance together (`advance = !m_tvalid || m_tready`):
accept -> slot0, env update -> slot1, gain update -> slot2, output ->
slot3 = `m_*` registers.  Latency = 3 edges accept-to-valid; II = 1.
Output valid/data/markers hold under backpressure; a stall freezes every
slot (no recompute, no dropped beat).  One output per accepted input.

Atomic `cfg_valid/cfg_ready` accepts only when all four slots are empty;
`cfg_valid` blocks input while pending.  Fields: `cfg_target[6:0]` 0..120,
signed `cfg_gmin/cfg_gmax[8:0]` in [-256,255] with gmin<=gmax,
`cfg_attack/cfg_release/cfg_est[3:0]`, `cfg_mode`, `cfg_mute`,
`cfg_bypass`, `cfg_clear`.  Any violation rejects the whole request
(`cfg_error` pulse, nothing committed).  `cfg_done` pulses on every
accept, `cfg_error` additionally on reject.  `cfg_clear=1` zeroes env and
gq; `cfg_clear=0` retains both, clamping gq into the new bounds.
`clip_sticky` clears on any accepted config.  Reset defaults:
target=100 (~-15 dBFS), gmin=-96, gmax=+32 (~-72/+24 dB), attack=3,
release=10, est=6, log mode, unmuted, not bypassed.

## Resource / robustness notes

Fabric registers only; no RAM, no clock enable, no gated reads — safe
under stalls on GW2A.  One 16x17 unsigned mantissa multiply (maps to one
MULT18X18); all other arithmetic is shift/add.  Isolated
`synth_gowin -noalu -family gw2a`: 1187 LUT1-4, 177 FF, 1 DSP, 0 BRAM.
No routed timing, board or chain claim.
