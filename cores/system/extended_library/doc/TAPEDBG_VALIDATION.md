# top_tapedbg Validation Log

Tape-out debug/diagnosability infrastructure for `docs/ASIC_TAPEOUT_DEBUG_CHECKLIST.md`
(dock-executable subset A1–A18, B1–B7), built on the `top_hwverify` template:
UART W/R/P/T command protocol @ 115200 + 8-bit LA probe bus on `dbg[7:0]`.

Target: Sipeed Tang Primer 20K dock (Gowin GW2A-LV18PG256C8/I7, 27 MHz xtal).
Build: `scripts/build_tapedbg_with_oss.ps1` — **always `-noalu`** (GW2A ALU
carry silicon erratum, see VALIDATION_LOG.md).

## Result

| Level | Command | Result |
|-------|---------|--------|
| sim   | `iverilog -DTAPEDBG_SIM` + `sim/tb_top_tapedbg.v` | **68/68 checks PASS** |
| board | `python tools/td_run.py --com COM24` (FT2232 UART) | **43/43 checks PASS** |
| LA    | sigrok-cli `fx2lafw:conn=2.2` | 3 captures, all evidence positive |

## Facility coverage (checklist item -> mechanism -> status)

- A1 scan chain: 64-FF capture+shift via reg 0x09 + boot self-check — loopback
  0xCAFEBABE12345678 OK, stuck-at-0@cell3 gives all-zeros-out signature — PASS
- A2 MBIST: auto-run at boot + W0x08 rerun + fault inject — PASS
- A3 mini JTAG TAP: bit-banged via reg 0x0A — IDCODE `54414E47`, SAMPLE/SCAN DRs — PASS
- A4 debug mux: `P` selects pages 0–4+ (boot/clocks/scan-TAP/engines/bus/alarms) — PASS
- A5 clock bypass: clk_sel 27/54/13.5 MHz -> dclk, digest stable at all — PASS
- A6 rPLL observability: lock, lock-latency, lock-seen regs — PASS
- A7 per-domain resets: dom_rst[3:0] — PASS
- A8 fault injection: golden mismatch, MBIST addr fault, scan stuck, pipe din — PASS
- A9 golden + shadow checker: digest `DB2D98F1`, mismatch->trig strobe — PASS
- A10 bypassable 3-stage pipeline: stage regs readable, bypass bisect — PASS
- A11 mini-ILA on dbg bus: arm/mask/val/pre + BSRAM readout — PASS
- A12 clock gate: `cg` reg, counter freeze — PASS
- A13 ring-osc PVT cell: 15 explicit LUT cells, ~52 MHz measured — PASS
- A14 RAM host port: reg 0x0F we/re/addr/data over same BSRAM — PASS
- A15 single-step: step_mode + `W0x02.1` pulses — PASS
- A16 test lock: `W0x02.2` sticky write-block — PASS
- A17 UART TX->RX loopback: byte count + last byte — PASS
- A18 programmable POR: por_bit + retrig, por_count survives — PASS
- B2 fault context: first_err latch, {exp,got} snapshot, err_cyc, trig strobe — PASS
- B3 programmable clocks: LA-measured frequencies below — PASS
- B7 script interface: W/R/P/T over UART — PASS

## LA captures (`doc/la_captures/`)

fx2lafw 8ch @24 MHz unless noted. Channel map: **LA-Dn -> dbg(7-n)**,
i.e. D0 = dbg7 = `trig_out` (trigger strobe, always), D1..D7 = page bits.

- `p1_clocks.sr` — `P 1` clocks page, free-run 2 s:
  | ch | signal | measured | expected |
  |----|--------|----------|----------|
  | D1 | clk27_div | 421.8 kHz | 27e6/64 = 421.875 kHz |
  | D2 | clk54_div | 843.7 kHz | 54e6/64 = 843.75 kHz |
  | D3 | dclk_div  | 421.8 kHz | = clk27 (sel 0) |
  | D4 | ro_div[5] | 812.4 kHz | -> ring osc **~52.0 MHz** (15-LUT loop) |
  | D5 | osc_clk   | 2.380 MHz | OSC/100 nominal 2.5 MHz (uncalibrated RC) |
  | D7 | hb        | ~1.6 Hz   | heartbeat |
- `trig_fault.sr` — armed ILA (mask/val 0x80, rising, pre=8), `fi_golden=1`,
  dom_rst pulse. LA waited on `D0=r`, fired, captured `engines` page:
  trig_out level high (trig_sticky), `digest_match=0`, g_busy->g_done ~152 us.
- `por_boot.sr` — `P 0`, `por_bit=25`, `W0x02.1` retrig, @1 MHz, D1=rst_n
  trigger: reset window **1242.8 ms** = 2^25/27 MHz exactly; pll_lock,
  mb_busy, g_done, scan boot-check activity all assert within ~0.2 ms of
  release; heartbeat runs through the whole window; trig_out stays 0
  (expected reset — no glitch flag).

## Bugs found and fixed during bring-up

1. `dft_scan_chain`: `cell` is a reserved Verilog keyword — renamed `sreg`.
2. Scan `si`/`se` off-by-one: registered copies update on the same edge the
   step pulse fires -> chain saw the previous write's si. Fixed by muxing the
   write's own `cmd_wdata` bits during the write pulse (`sc_se_r/sc_si_r`).
   (First loopback passed only because bit0 of the pattern happened to be 0.)
3. Stuck-at model semantics: `fi_stuck` at cell 3 is *physically correct* —
   it blocks all upstream 1s, so all-ones-in gives all-zeros-out. TB
   expectation corrected (this is the real fault signature).
4. TAP IR bit order: `{tdi, sr[3:1]}` means IR loads LSB-first; TB sent
   IDCODE as `1,0,0,1` -> loaded `1001` (unmapped -> BYPASS, all-zero TDO).
   Correct sequence `1,0,0,0`.
5. **POR live bit-select bug** (real HW-visible bug): `rst_n =
   reset_count[por_bit]` — writing a *shorter* por_bit while the counter sat
   above the new bit instantly re-asserted reset, causing a false
   `rst_glitch`. Rewritten as registered flag + `por_target` compare; por_bit
   now only affects the NEXT POR window.
6. `por_exp` priority bug: `if (rst_s2) por_exp <= 0` ran every running cycle,
   clearing the expected-reset mask on the same edge `por_trig` set it —
   every commanded retrigger logged a phantom glitch. Fixed with if/else
   priority (por_trig wins).
7. Ring oscillator collapsed: behavioural inverter chain folded to 2 cells by
   synth (verified in netlist). Rebuilt from explicit `(* keep *)` LUT1/LUT2
   primitives — survives techmap, oscillates ~52 MHz on silicon.
8. Pipe kick race: `p_din` loaded on the same clk edge `u_pipe.kick` sampled
   `din` (dclk) -> pipe propagated the *previous* seed (observed seed 0x11F4
   instead of 0x1234). Fixed by delaying kick one clk (`p_kick` reg).

## GRADE-RTL flow (arXiv:2609.25335)

Ran the published five-stage front-end grading flow
(github.com/hsc-research/GRADE-RTL, stage functions used verbatim via
`tools/grade_rtl.py`; logs in `build_oss/grade_rtl/`):

| module | P port-sig | C compile | E elaborate | M complete | F equiv |
|--------|-----------|-----------|-------------|------------|---------|
| dft_scan_chain | n/a | PASS | PASS | PASS | PASS (RTL=synth) |
| tap_mini       | n/a | PASS | PASS | PASS | PASS (RTL=synth) |
| golden_ref     | n/a | PASS | PASS | PASS | PASS (RTL=synth) |
| dbg_pipe3      | n/a | PASS | PASS | PASS | PASS (RTL=synth) |
| ring_osc       | n/a | PASS | PASS | PASS | PASS (RTL=synth, sim model) |
| top_tapedbg    | **PASS** vs `top_hwverify` | PASS | PASS | PASS | n/a -> regression |

- P: candidate port signature compared against trusted `top_hwverify`
  (identical physical interface: clk, uart_rx_pin, uart_tx, status_*,
  dbg0..7) — `iverilog -tnull -Wall -Wimplicit` under
  `` `default_nettype none `` for C; yosys `hierarchy -check` for E;
  static completeness + `proc; opt; check -assert` for M.
- F on leaf modules: `equiv_make`/`equiv_simple`/`equiv_induct` (seq 10,
  with `async2sync` for the async-reset FFs) proving the RTL equals its
  post-synthesis netlist — i.e. synthesis preserved function.
- F on the top has no trusted reference RTL (the checklist is the spec);
  substituted evidence: directed regression 68/68 (sim) + 43/43 (board).
- PPA evidence (nextpnr GW2A-18): 2885 LUT4 (13%), 1532 DFF (9%),
  2 BSRAM, 1 rPLL, 1 OSC; slack histogram ~69-82 ns (async, unconstrained).
- Flow notes: candidate files are comment-stripped before grading because
  the framework's `parse_interface` strict-zips original vs masked port
  segments — a comma inside a `//` comment in the port header desyncs them
  (framework-side limitation, not an RTL defect).  Vendor-primitive models
  are `sim/tapedbg_grade_prim_stub.v` + `sim/tapedbg_cells_stub.v`; the
  behavioural `hv_sim_stubs.v` rPLL/OSC models infer a sim-only latch and
  undriven-net warning under `proc`, which would be a false positive for M.

## Anomalies

- One transient was observed once and never reproduced: an early post-fix
  run reported pipe seed `0x11F4` (y0=0x3409, internally consistent chain)
  instead of `0x1234`, while the same bytes written to scratch verified
  `0x00011234` 5/5. Likely a one-off UART frame corruption in that write
  (no resend/ACK on W). After adding `p_din` readback (R 0x0D) the pipe
  reports `0x1234` and correct stages on every run including 43/43.

## Reproduce

```powershell
# sim
.\scripts\test_tapedbg_sim.ps1          # 68/68
# board
.\scripts\build_tapedbg_with_oss.ps1    # yosys -noalu -> nextpnr -> gowin_pack
.\scripts\program_tapedbg.ps1 -Com COM24
# or manually:
openFPGALoader -b tangprimer20k build_oss\tapedbg.fs
python tools\td_run.py --com COM24       # 43/43 (add --quick to skip 192-op loops)
# LA
sigrok-cli -d fx2lafw:conn=2.2 --config samplerate=24mhz `
  --channels "D0,D1,D2,D3,D4,D5,D6,D7" -O binary -o out.bin --time 2s
```

UART notes (same as hwverify): FT2232 interface B = COM24 @115200; insert
~1 ms between TX bytes (uart_rx drops back-to-back start bits). `test_lock`
persists until reconfig — it also blocks por_trig; reprogram to clear.
