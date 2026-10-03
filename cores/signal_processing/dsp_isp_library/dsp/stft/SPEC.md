# DSP-14 STFT / Welch power spectrum (`stft_welch`)

Streaming Welch periodogram around the board-proven serialized `fft64`
(`cores/signal_processing/transforms/src/fft64.v`). One instance of the existing DSP-05
`window_mult` (MAX_LOG2N=6) windows the frame, `fft64` transforms it, one
`mag_squared` produces integer bin powers, and an internal averager emits
one power-spectrum record per average update. All reused cores are
instantiated read-only; their own contracts apply inside.

## Data formats and parameters

- Input `s_tdata`: signed16 Q1.15 real samples.
- Frame size **N = 64** fixed (the reused `fft64`; log2n = 6 everywhere).
- Hop `H` = `8 << cfg_hop`, cfg_hop 0..3 -> H in {8, 16, 32, 64}. Overlap
  N-H in {56, 48, 32, 0}. Frame f covers accepted samples
  `f*H + 0 .. f*H + 63` counting from reset or the last accepted config.
- Window `cfg_window` 0..4 identical to `window_mult`: unity/Hann/Hamming/
  Blackman/custom-upload. `cfg_wshift` signed -8..15 is the window
  output shift (amplitude correction by powers of two only).
- `cfg_twosided`: 0 -> one-sided record bins k=0..32 (33 bins),
  1 -> two-sided bins k=0..63 (64 bins).
- `cfg_avgmode`: 0 = block average over `A = 2**cfg_avg` frames
  (cfg_avg 0..8 -> A 1..256); 1 = exponential/leaky average with
  `alpha = cfg_avg` (1..8, 0 illegal): `S[k] += ((P[k]<<8) - S[k]) >>> alpha`,
  8 fractional guard bits, output `sat_u32(RNE(S[k], 256))`.
- `cfg_pshift` 0..15 is the `mag_squared` power shift (block-floating
  headroom for averaging).

## Output record layout

One record per emitted average update: `K` beats of `m_tdata` = unsigned32
bin value in natural bin order k = 0..K-1 (K = 33 or 64).
`m_tuser[0]` = SOF (k==0), `m_tuser[1]` = LAST (k==K-1). Every beat is one
transfer; all fields hold while `m_tvalid && !m_tready`. A new record may
begin while a previous one is still draining; ordering is preserved.

Bin k frequency: `f_k = k*fs/64`. In two-sided mode k>32 represents
negative frequency `(k-64)*fs/64`; bins 33..63 are not emitted in
one-sided mode but still update the averager.

## Integer power and PSD normalization contract (exact)

`fft64` computes `X[k] ~= DFT(xw)[k]/64` in Q1.15 with deterministic
stage rounding/wrap (see its README). `mag_squared` emits integer
`P[k] = RNE(re^2 + im^2, 2**pshift)`. Let `P0[k] = re^2 + im^2`
(pre-shift units, `P ~= P0 / 2**pshift`).

- `|DFT(xw)[k]|^2 = P0[k] / 2**18` in real units
  (`X_real = X_q/32768`, `|X_real|^2 = P0/2^30`, `DFT = 64*X_real`).
- Window energy constant `U = sum(w[n]^2)` with `w` the real-valued
  window, or `U_q = sum(w_q[n]^2)` with `w_q` the internal signed18 Q3.15
  coefficients, `U = U_q / 2**30`. `models/reference.py
  window_power_sum()` returns the exact `U_q` per window type.
- One-sided PSD (Welch): `PSD[k] = |DFT(xw)[k]|^2 / (fs*U)` for k=0 and
  k=32, `2*|DFT(xw)[k]|^2 / (fs*U)` for 0<k<32.
- Two-sided PSD: `PSD[k] = |DFT(xw)[k]|^2 / (fs*U)` for all k.
- In output integer units: `|DFT|^2 = P_out * 2**pshift / 2**18`, so
  `PSD[k] = P_out[k] * 2**pshift * 2**12 / (fs * U_q)` (times 2 for
  interior one-sided bins). The RTL reports integer `P_avg[k]`; the
  fs-dependent final scale is applied by analysis software. The reported
  `U_q` integers and `coherent_gain` are part of this contract.
- Amplitude (not power) calibration of a bin-centered tone additionally
  needs the coherent gain CG = mean(w_q)/32768; `cfg_wshift` approximates
  1/CG only by powers of two (same limitation as DSP-05).

## Averager arithmetic (bit-exact)

`acc[k]` is a signed 42-bit per-bin state, zeroed (logically, via an
init flag) on reset and on every accepted legal config.

- Block mode: `acc_new = acc + P` each frame; on the last frame of the
  block (`frame_in_block == A-1`) emit `sat_u32(RNE(acc_new, A))` and
  write 0; otherwise write `acc_new`. Only bins k < K are emitted.
- Exp mode: `S_new = S + ((P<<8 - S) >>> alpha)` (arithmetic shift,
  floor toward -inf; S stays >= 0), emit `sat_u32(RNE(S_new, 256))`
  every frame for k < K. Startup is biased low and converges with time
  constant ~`1/ln(1/(1-2^-alpha))` frames (documented transient).
- `sat_u32` clamps to 0xFFFFFFFF. In block mode with A=1 the sum is a
  single u32 power and cannot saturate; larger A may.

## Throughput and buffering contract (honest rates)

Per frame the engine performs: 64 buffer reads through `window_mult`
(II=1, 4-cycle latency), 64 FFT loads, 1 start, 768 FFT compute beats,
64 FFT readouts through `mag_squared` (II=1, pipeline 4 edges to valid)
and 64 accumulate/emit steps. Measured `T_frame` = 910 clocks
back-to-back. **Maximum sustained input rate is
H/T_frame samples per clock**: ~1/14 for H=64, ~1/28 for H=32, ~1/57 for
H=16, ~1/114 for H=8. Hop < N therefore does *not* mean one FFT per hop
at arbitrary input rate; the overlap memory only decouples burstiness.

The frame buffer is a 128-entry signed16 ring (`sig_sdp_ram`, parameter
`RAM_REGS`: 1 = proven register array, 0 = proven DPX9B wiring). It
holds the frame in process (64) plus up to 64 newly arrived samples.
`s_tready = rst_n && fill < 128 && !cfg_valid` outside config-commit
states; a presented config also closes the sample input. Full buffer is
pure backpressure — never a drop or wrap. While a frame is processed
the input continues to be accepted up to capacity.

Latency: first output bin of a record leaves about `T_frame` = 910 clocks
after the frame's 64th sample is accepted; subsequent bins emit at II=1
while `m_tready` is high. `busy` output is high while any frame is in
process. `cnt_in`[19:0], `cnt_frames`[15:0], `cnt_recs`[15:0] count
accepted samples, completed frames and emitted records (wrapping).
`clip_sticky` latches window or magnitude saturation until reset or an
accepted legal config.

## Configuration, reset, limits

Single `clk`, synchronous active-low `rst_n`. Config handshake commits
all fields atomically when `cfg_valid && cfg_ready`; `cfg_ready` requires
IDLE state and an empty output slot, so a config never straddles an
in-flight frame or record. Priority in IDLE: config over a ready frame.
A legal commit clears buffer fill/pointers, averager state and validity,
block index, counters and clip flag, then applies window/mag sub-configs
on the two following cycles (`cfg_done` pulses after). Buffered
not-yet-framed samples are discarded — documented, like DSP-01/05.
Illegal fields reject the whole update (`cfg_error`, state preserved):
window>4; block mode cfg_avg>8; exp mode cfg_avg==0 or >8;
cfg_wshift<-8; cfg_pshift>15.

Custom window mode (4) shares `window_mult`'s upload contract through the
passthrough `coe_*` port: coefficients signed18 Q3.15, index order, up to
64 entries; an incomplete table stalls the load phase (backpressure), it
is not an error.

Reset aborts everything: in-flight frame, buffered samples, averager,
counters, pending output, sub-core pipelines. The reused `fft64`,
`sig_sdp_ram` and twiddle ROMs have a `clk_en`/async-reset capable
legacy interface; the wrapper ties `clk_en=1` and requires `rst_n` to be
applied synchronously per this contract. RAM contents are never reset
but cannot become valid output (fill/averager-valid tracking).

## Structural limitations

- N fixed at 64; H limited to {8,16,32,64}; powers of two only.
- No fractional-alpha exponential mode; alpha 1..8 only.
- No automatic fs scaling or non-power-of-two coherent-gain correction.
- Serialized FFT engine: no II=1 claim and no multi-frame concurrency;
  sustained rates above H/T_frame are backpressured, not accelerated.
- `RAM_REGS=0` BSRAM mapping is the board-proven DPX9B path shared with
  `fft64`; plain inferred-RAM alternatives are *not* used (documented
  GW2A-18C inference issue). Isolated synthesis only; no P&R, timing,
  wrapper or board acceptance claimed.
