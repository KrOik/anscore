# Adaptive LMS/NLMS filter (`lms_stream`)

Requirement: goal DSP-15.  Two implementations behind one top level:
`IMPL=0` serial-MAC (lowest area, one shared multiplier chain) and `IMPL=1`
full-parallel pipeline (II=1 for NTAPS<=8, the default target tap count).

Status: RTL + model + cycle-accurate simulation + isolated synthesis only.
No wrapper, board image, P&R, timing, or hardware qualification is claimed.

## Algorithm

Per accepted input sample `(x[n], d[n])` on `s_tdata={d[31:16], x[15:0]}`:

```
y[n] = sat16( RNE( sum_k c[k] * x[n-k] / 2^20 ) )     k = 0..taps-1
e[n] = sat16( d[n] - y[n] )
t2   = sat18( RNE( mu * e[n] / 2^15 ) )              // mu in UQ0.16

LMS : g = t2
      delta[k] = RNE( g * x[n-k] / 2^11 )
NLMS: E_den = min( sum_k x[n-k]^2 >> 16, 2^20-1 )    // tap-window energy
      floor_eff = max(cfg_floor, 1)
      bypass  = (E_den < floor_eff)                  // energy floor guard
      g = sat20( RNE( t2 * 2^8 / E_den ) )           // fp_div_* shared core
      delta[k] = RNE( g * x[n-k] / 2^5 )

c[k] <- sat24( c[k] + delta[k] )                     // k < taps
```

Output `m_tdata = {e[31:16], y[15:0]}`, `m_tuser = {bypass, clip}`.
`clip` accumulates: y/e saturation, t2 saturation, divider div0/clip flags
(NLMS), and coefficient-write saturation at the commit edge.

## Fixed-point derivation

| signal | format | range justification |
|---|---|---|
| x, d | s16 Q1.15 | input contract |
| coef c[k] | s24 Q4.20 | |c|<8; 20 frac bits keeps delta quantum ~1e-6 |
| acc | s48 (dot) | 8 x (24x20=44b) products +4 guard bits |
| y, e | s16 Q1.15 | output contract, saturated |
| t2 | s18 Q1.16ish | |mu*e|<1 after RNE; sat18 margin for e near +-1 |
| g (LMS) | s18 | same as t2 |
| E_den | u20 | e2/2^16 saturated at 2^20-1; e2 max = NTAPS*2^30 >> 16 |
| g (NLMS) | s20 Q10.10ish | t2*2^8/E_den via fp_div_pipe(18/21, FB=8, OUT_W=20) |
| delta | s24 | coef-domain increment |

RNE is round-half-to-even on the magnitude (negative-safe via floor-division
remainder form), identical to `infra/fixedpoint`.  Every narrowing is
saturating; the 4-bit headroom in s18/s20 gain paths plus coefficient sat24
provably prevents wrap on any legal input (max |delta| = 32767*|g|; worst
NLMS g = sat20 so |delta| <= 2^19*2^15/2^5 = 2^29 -> sat24 clips, flagged).

### NLMS division precision and floor

The gain divide is the shared `fp_div_pipe`/`fp_div_iter` signed core with
exact RNE and explicit div0/clip flags: `g = RNE(t2*256/E_den)`, i.e.
`g_real = mu*e / (E_den/2^24)` where E_den/2^24 = tap energy in Q1.15 units
squared (e2 raw >> 16, so eden_real = e2/2^30).  `E_den==0` is unreachable
through the floor guard (`floor_eff>=1` forces bypass first); the divider's
own div0 guard (returns +-MAX, flags 2'b11) still protects the corner.
The floor therefore guarantees the update is skipped exactly when the
measured window energy is below a configured, absolute threshold —
independent of signal scaling since E_den is a raw-square count >> 16.

## Interface

`clk`, synchronous active-low `rst_n`.  Stream input `s_tdata/s_tvalid/
s_tready`; stream output `m_tdata/m_tuser/m_tvalid/m_tready`.  State advances
only on accepted transfers; output fields hold while stalled; `s_tready`
deasserts during `cfg_valid` (config has input priority).

Configuration handshake `cfg_valid/cfg_ready` carries
`{taps,mu,nlms,update_en,floor,coef_clr}`.  `cfg_ready` only when the engine
is fully drained (serial: FSM idle and no pending output; parallel: every
pipeline stage and the divider-mirror empty) so a config can never corrupt an
in-flight sample.  Accepted legal config applies atomically, clears sample
history and the energy accumulator, and clears coefficients iff
`cfg_coef_clr`; `cfg_done` pulses on every accepted
transaction; `cfg_error` pulses as well when the config was rejected
(`cfg_taps<1` or `>NTAPS`), in which case the active config and all state
are preserved.

Coefficient sideband: `cw_en/cw_addr/cw_data` writes a tap (overrides a
commit hit on the same tap in the same edge); `rb_en/rb_addr` -> registered
`rb_valid/rb_data` one cycle later, returning the pre-edge coefficient value
(read-during-commit ordering is deterministic: the read sees the value
before that edge's commit).  `rb_addr >= NTAPS` returns 0.

## Implementations and latency

### IMPL=0 — serial MAC

One shared `lms_mul2420` chain (DSP-inferred with `MULT_DSP=1`, LUT-only with
`MULT_DSP=0`).  FSM: accept -> taps dot-product MAC -> (NLMS: taps energy MAC)
-> y/e -> t2 -> (NLMS: `fp_div_iter` divide, ~27 cycle service) -> taps update
MAC -> emit.  Per-sample II ~= 2*NTAPS + 4 (LMS) or 3*NTAPS + 32 (NLMS);
latency equals II (one sample in flight at a time).

### IMPL=1 — parallel pipeline (II=1, NTAPS<=8)

Rigid global-enable pipeline: `adv = !m_tvalid || m_tready`.  Accept edge E:

```
E        sample latched; xsh shift; incremental E_sum (2 mults)
E+1      prod[k] = coef[k]*xv[k]                       NTAPS mults
E+2..E+1+NL   adder tree -> acc                        NL levels
E+2+NL   y/e/eden/clip regs
E+3+NL   t2 = RNE(mu*e/2^15)                           1 mult
E+4+NL   divider feed (NLMS only); meta enters dm[0]
E+NL+31  commit edge: coef[k] += RNE(g*xv[k]/2^sh)     NTAPS mults
         output register written
```

Latency = NL+31 accept-to-output-register edges; output transfers on the
next ready edge.  II=1: the dense-run oracle check shows back-to-back accepts
sustain one result per cycle once filled (fixture stats: ~11237 accepts /
18000 cycles under 25%-stall random backpressure; II=1 in dense phases).

### Divider/mirror alignment (important)

`fp_div_pipe` internally advances whenever its output slot is free — it
cannot be back-pressured mid-pipe.  During an output stall it can therefore
emit a quotient one or more samples *ahead* of the matching `dm[]` metadata.
Commits draw quotients through an ordered 32-deep hold queue (the divider
output slot + FIFO), which is guaranteed non-blocking because at most
DMLEN+2 in-flight samples exist and every fed sample commits exactly once.
Only samples that will actually commit (`nlms && uen && !bypass`) are fed to
the divider, so quotient emission order == commit order.

`m_tuser[1]` (bypass) reports the energy-floor skip; `m_tuser[0]` is the
accumulated clip flag including the commit edge.

### Delayed-update visibility (delayed LMS)

The commit lands at edge E+NL+31, so a sample's own update becomes visible to
products of sample n+NL+31 = n+34 for NTAPS=8 (`VIS = NL+31`).  Serial core
has VIS=1.  This is *delayed LMS*: convergence holds but the stable-step
bound tightens roughly to mu_eff < 2*sin(pi/(2*(2*VIS+1))).  Practically, the
parallel NLMS path converged cleanly at mu <= 0.125 (see tests); larger steps
can oscillate — choose mu accordingly for the parallel variant.

## Resource picture (isolated `synth_gowin -top lms_stream`, core only)

| variant | LUT1-4 | ALU | FF | MULT DSP | dist RAM |
|---|---|---|---|---|---|
| serial_dsp   | 1641 | 843  | 761  | 3  | 0  |
| serial_logic | 2599 | 997  | 761  | 0  | 0  |
| parallel_dsp | 2696 | 2859 | 8880 | 35 | 12 |
| parallel_logic | 18317 | 7409 | 8928 | 0 | 12 |
| parallel4_dsp | 1863 | 1894 | 6105 | 19 | 12 |

See `evidence/synth_*/summary.json` for the authoritative run.

Budget notes: the <=4-DSP board-image guidance is met by `IMPL=0` (3 DSP);
the `IMPL=1` parallel core is explicitly a throughput option whose
35-DSP/8.9k-FF profile cannot fit the default board budget — it is provided
for applications with larger targets and documented as such.  `MULT_DSP=0`
variants prove the logic-multiplier path synthesizes to zero DSP cells.

## Limitations

- Simulation + isolated synthesis only; no routed board image, no timing,
  no hardware qualification.
- Parallel NLMS delayed-update visibility (VIS=34) shrinks the stable step
  range; mu <= 1/8 demonstrated.  Use `IMPL=0` or smaller `mu` if tighter
  tracking is required.
- `eden` uses an incremental window sum of squares; after a legal config
  change history is cleared so the window is exact — mid-stream window
  count assumes contiguous history.
- No BRAM inference (all coefficient/history state is registers) — correct
  for NTAPS<=8; larger NTAPS linearly grows FF/LUT.
