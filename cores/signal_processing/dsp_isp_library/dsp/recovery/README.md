# DSP-08: carrier & symbol-timing recovery (DPLL pair)

Second-order recovery loops for a **BPSK** reference configuration
(complex I/Q carrier loop at SPS=4; real-baseband timing loop at
SPS in {4,8}).  See `SPEC.md` for the full contract: signal model,
detector equations, loop filter, pull/lock ranges, limitations.

## Files

- `rtl/carrier_loop.sv` — derotation complex mix + decision-directed
  (Costas sign(I)*Q) phase detector + PI filter + LUT NCO + lock flag +
  `freq_est`.  AXI-Stream-style `s_tdata`/`m_tdata` (packed {Q,I} s16
  lanes), II=1, stall-safe.
- `rtl/timing_loop.sv` — Gardner TED + PI + symbol-phase accumulator with
  `pick`/`pick_data`/`pick_bit` strobe outputs, `lock`, `rate_est`.
- `rtl/nco.sv` — shared 32-bit phase accumulator + quarter-wave sine LUT
  (cos/sin, Q1.11).
- `rtl/pi_loop.sv` — shared PI loop filter (Q31 error, programmable
  right-shift gains, clamped integrator).
- `rtl/lock_det.sv` — shared leaky-|e| lock detector (armed at max on
  reset/clear; nreq consecutive below-threshold updates to assert).
- `models/model.py` — float loop references, bit-exact cycle models,
  BPSK signal generators (carrier offset / timing offset / rate offset).
- `tests/test_recovery.py` — generates both fixtures, compiles/runs the
  iverilog TBs (`iverilog -g2012 -Wall` clean), per-cycle output compare,
  behavioural assertions (acquisition, lock, residual freq error, BER,
  pull-range edge, out-of-range graceful fail, illegal cfg rejection),
  22 field-mutation negatives + pick-ordering mutation.
- `tests/synthesize.py` — isolated `synth_gowin -noalu` counts.

## Run

```powershell
python tests\test_recovery.py     # sims + assertions + mutations
python tests\synthesize.py        # resource counts
```

Evidence lands in `evidence\rtl_<ts>\` and `evidence\synth_<ts>\`.

## Headline verified numbers

- Carrier pull-in |df| <= Fs/32 (cold); fcw-preset hold verified to
  Fs/20; cold Fs/16 never locks (documented graceful fail).
- Timing: SPS=4/8, picks within +-1 sample, 0 BER post-lock, tracks +-4%
  rate offset.
- Resources: carrier 1073 LUT1-4 + 4 DSP; timing 725 LUT1-4 + 0 DSP.

Not claimed: routed timing, board acceptance, other modulations,
interpolated timing recovery, multi-rate or non-integer SPS.
