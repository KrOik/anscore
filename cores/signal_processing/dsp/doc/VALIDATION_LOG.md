# dsp_20k VALIDATION LOG

## 2026-09-24 CORDIC shared-add/sub optimization

Modified `src/cordic.v` x/y stage arithmetic to share conditional add/sub
instead of computing both signs and multiplexing the full results. Pipeline
registers and observable results remain unchanged. Clarified latency wording:
17 enabled periods from acceptance edge to output edge, for 16 iterations.
Package angle descriptions corrected to match existing quadrant behavior.

PASS: `scripts/test_dsp_cordic_optimization.ps1` runs four benches covering
4,096 independent model vectors, quadrant/saturation boundaries, streaming
mixed modes, bubbles, clk_en pauses, asynchronous reset, full-rate board
harness, original five-unit selftest and complete UART report. Original
digests `5B8CCF9D / 4A4E2D09 / 0F185BED / 20038C18 / 5C690862` unchanged.
Yosys `equiv_simple` + `equiv_induct` + `equiv_status -assert` proves all
1,057 equivalence cells after async2sync reset normalization. Original
attempt without normalization lacked an async-FF SAT model; that log is
retained and is not counted as a passing proof.

Same-tool `synth_gowin -noalu -family gw2a` isolated comparison:
LUT1-4 3,046 -> 2,197 (-27.9%); FF 1,002 unchanged; DSP/BRAM 0.
Complete DSP board top, same nextpnr seed 1: LUT4 10,585 -> 8,583 (-18.9%),
FF 2,534 -> 2,551, DSP 0, BRAM 1. Post-route estimated Fmax falls
90.87 -> 61.79 MHz, both above the 27 MHz target: accepted as an area
optimization, not a timing improvement or silicon Fmax measurement.

Built with `scripts/build_dsp_cordic_optimization.ps1`, programmed original
and candidate with openFPGALoader. fx2lafw capture at 4 MHz on D0=A11 decodes
two complete DSP reports for each, all five original digests PASS.
Added `cordic_rate_board` sends 32 adjacent alternating-mode samples at
clk_en=1 / 27 MHz and exports all output words. 11 captured frames match
every x/y/z result against Python golden; hardware checks latency=17 and
output interval=1. Full-rate test top: 6,677 LUT4, 3,148 FF, 0 DSP/BRAM;
post-route estimate 104.76 MHz, tested on hardware at 27 MHz only.

Changed/new files: core; `src/cordic_rate_board.v`; two `sim/tb_cordic_*.v`;
`tools/gen_cordic_stress.py`, `tools/verify_cordic_board_capture.py`; build and
test scripts above; package docs/metadata; central optimization ledger.
Host checker rejects corrupt full-frame output and wrong latency. Baseline
source, diff, hashes, logs, images and `.sr` captures are preserved under
repository `artifacts/ip_optimization_20260924/cordic/`. Exact commands and
scope are in `docs/IP_OPTIMIZATION_STATUS.md`. Older evidence follows.

Project: `cores/signal_processing/dsp` — four DSP IP cores + digest selftest + UART report
Board: Sipeed Tang Primer 20K, Gowin GW2A-18C (`GW2A-LV18PG256C8/I7`), 27 MHz
Flow: OSS CAD Suite (yosys `synth_gowin`, nextpnr-himbaechel, gowin_pack),
      iverilog 14.0, sigrok-cli (fx2lafw), openFPGALoader

## Units under test

| unit | name | core | description |
|---|---|---|---|
| U0 | CRDR | `src/cordic.v` | 16-stage pipelined CORDIC, Q2.14, rotation mode |
| U1 | CRDV | `src/cordic.v` | same core, vectoring mode |
| U2 | DDS  | `src/dds_nco.v` | 32-bit phase acc + 256x16 sine LUT (BSRAM) + square |
| U3 | FIR  | `src/fir16.v` | 16-tap symmetric FIR, 8-bit, saturating, shift-add |
| U4 | PID  | `src/pid_core.v` | discrete PID, shift-add gains, anti-windup clamp |

Harness: `src/dsp_selftest.v` — per-unit FNV-1a digest chains on a /16 clk_en
divider, `===`/`!==` pass checks, `UNIT_EN` mask. Top: `src/top.v`,
`src/uart_tx.v`, `src/top.cst` (clk=H11, uart_tx=M11, status T9/P9).

## Golden models (independent of RTL)

`tools/golden_model.py` generates:

- `sim/golden_stream_{crdr,crdv,dds,fir,pid}.mem` — expected output streams
- `sine256.mem` — 256x16 sine LUT (also loaded by `dds_nco`)
- `sim/expected_report*.mem` — UART report golden via `tools/gen_uart_golden.py`

CORDIC golden uses `math.sin/cos/atan2/hypot` with Q2.14 quantization and the
documented ~1.6468 gain factor. DDS golden reproduces the accumulator/LUT
timing exactly (registered read = pre-increment address). FIR golden is a
direct convolution. PID golden is the difference equation with clamping.
No RTL output was used to generate any golden data.

Expected digests (FNV-1a, 32-bit):

```
CRDR 5B8CCF9D   CRDV 4A4E2D09   DDS 0F185BED   FIR 20038C18   PID 5C690862
```

## Simulation results (iverilog -g2012)

Testbenches: `sim/tb_dsp_selftest.v`, `sim/tb_top_uart_report.v`.

Full mask (`UNIT_EN=16'h001F`):

```
UNIT 0 digest=5b8ccf9d done=1 pass=1
UNIT 1 digest=4a4e2d09 done=1 pass=1
UNIT 2 digest=0f185bed done=1 pass=1
UNIT 3 digest=20038c18 done=1 pass=1
UNIT 4 digest=5c690862 done=1 pass=1
done_mask=001f pass_mask=001f all_pass=1 any_fail=0
tb_dsp_selftest PASS
```

Split masks `UNIT_EN=16'h0007` and `16'h0018`: PASS each.
UART report sim vs `expected_report.mem`: `tb_top_uart_report PASS`.

Notable bugs found & fixed during bring-up:

1. `all_done` reduce-AND included disabled units -> check only active units.
2. Testbench reset release raced the ce-OR in reset -> release on negedge.
3. CORDIC `out_valid` tapped `v_sh[STAGES+1]` -> corrected to `v_sh[STAGES]`.
4. PID negative-limit concatenation was unsigned -> signed temp + signed cmp.
5. DDS golden phase/output alignment off by one beat -> golden fixed.
6. UART golden generator used 3-char names vs RTL 4-char -> padded to 4.

## Synthesis / P&R / bitstream (OSS CAD Suite)

Commands (from `cores/signal_processing/dsp/`):

```bash
yosys -p "read_verilog -sv src/cordic.v src/dds_nco.v src/fir16.v \
  src/pid_core.v src/dsp_selftest.v src/top.v src/uart_tx.v; \
  synth_gowin -family gw2a -top top -json build_oss/top.json; stat"

nextpnr-himbaechel --json build_oss/top.json --write build_oss/pnr.json \
  --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18 --vopt cst=src/top.cst

python tools/.../gowin_pack-script.py -d GW2A-18 \
  -o build_oss/dsp_20k.fs build_oss/pnr.json
```

Routed resources (`build_oss/nextpnr.log`):

```
LUT4:    10151/20736 (48%)   MUX2_LUT5: 162/10368
ALU:      4826/15552 (31%)   DFF:       2535/15552 (16%)
BSRAM:       1/46    ( 2%)   DSP classes (ALU54D/MULT*): 0  -- meets 0-DSP target
Max frequency: 64.18 MHz  (target 27 MHz, large positive margin)
```

Bitstream: `build_oss/dsp_20k.fs` (~7.26 MB). LUT total 10151 <= 15K budget.

## Board validation

Procedure: `.boardlock` acquired (owner `dsp_20k_agent`),
`openFPGALoader -b tangprimer20k build_oss/dsp_20k.fs` -> DONE, released after
all attempts.

### Result: PASS via on-board LA decode; COM24 host path broken (deviation)

The production bitstream's UART report could not be captured on COM24:
`serial read` returned **0 bytes** (see `doc/board_uart_com24.txt`, 0 B).
The identical failure occurred with a previously board-validated CNN
bitstream, proving the fault is in the host FTDI channel-B/COM24 path on this
machine, not in the DSP design. Raw FTDI access
(`host/ftdi_raw_uart_read.py --interface 2`) also failed:
`NotImplementedError: ... on this platform` (libusb claim, Windows).

To obtain physical evidence anyway, a debug bitstream
(`src/la_debug_top.v`, identical selftest + report FSM as `top.v`, internal
signals mirrored to the calibrated fx2lafw LA pins: uart_tx->A11/D0,
all_done->B11/D1, status_pass->N6/D2, status_fail->D11/D3, ce->N9/D4,
rst_n->N7/D5, tx_busy->L9/D6, heartbeat->N8/D7) was programmed and captured
with `sigrok-cli -d fx2lafw:conn=2.2 -c samplerate=1MHz --time 2s`.

On-board results (`build_oss/la_cap3.sr`, decoded `doc/board_uart_la.txt`):

- heartbeat toggles (clock alive), rst_n=1, all_done=1, pass=1, fail=0
- UART frames on D0 decode cleanly at 115200 8N1 to the real report,
  repeated 4+ times:

```
DSP5 M=001F P=001F
U0 CRDR P D=5B8CCF9D
U1 CRDV P D=4A4E2D09
U2 DDS  P D=0F185BED
U3 FIR  P D=20038C18
U4 PID  P D=5C690862
```

All five digests match the independent golden values on physical hardware.
The same `uart_tx` net also drives pin M11 (verified in `build_oss/pnr.json`,
IOB at the M11 site), so the production design does emit the report; only the
host-side COM24 capture path is non-functional on this machine.

Deviation: the SOP asks for COM24 UART capture evidence. Substituted with
LA-decoded capture of the identical UART stream produced by the FPGA on a
physical pin. `doc/board_uart_com24.txt` / `doc/board_uart_full.txt` are
intentionally kept (0 bytes) as record of the failed host path.

## IP packaging

`ip/` (per-IP dir: wrapper `gw2a_dsp_<name>.v`, `ip_manifest.json`,
`README.md`; index `ip/MANIFEST.md`; `sine256.mem` copy in `ip/dds_nco/`):

| IP | core | digest(s) | standalone synth (LUT/ALU/DFF/BSRAM/DSP) |
|---|---|---|---|
| gw2a_dsp_cordic | cordic | 5B8CCF9D / 4A4E2D09 | 932 / 1701 / 1002 / 0 / 0 |
| gw2a_dsp_dds_nco | dds_nco | 0F185BED | 2 / 32 / 32 / 1 / 0 |
| gw2a_dsp_fir16 | fir16 | 20038C18 | 132 / 90 / 137 / 0 / 0 |
| gw2a_dsp_pid_core | pid_core | 5C690862 | 172 / 220 / 49 / 0 / 0 |

Each wrapper independently compiled (`iverilog -g2012`) and synthesized
(`synth_gowin -top gw2a_dsp_<name>`) with 0 DSP cells.

## Files

- RTL: `src/cordic.v`, `src/dds_nco.v`, `src/fir16.v`, `src/pid_core.v`,
  `src/dsp_selftest.v`, `src/top.v`, `src/uart_tx.v`, `src/top.cst`,
  `src/la_debug_top.v`, `src/la_debug.cst` (debug-only)
- Tools: `tools/golden_model.py`, `tools/gen_uart_golden.py`
- Sim: `sim/tb_dsp_selftest.v`, `sim/tb_top_uart_report.v`,
  `sim/golden_stream_*.mem`, `sim/expected_report*.mem`
- Build: `build_oss/{top.json,pnr.json,dsp_20k.fs,yosys.log,nextpnr.log}`,
  debug `build_oss/{la.json,la_pnr.json,la_debug.fs,la_cap*.sr}`
- Evidence: `doc/board_uart_la.txt` (decoded board report),
  `doc/board_uart_la_stats.txt`, `doc/board_uart_com24.txt` (0 B),
  `doc/board_uart_full.txt` (0 B)
- IP: `ip/{cordic,dds_nco,fir16,pid_core}/`, `ip/MANIFEST.md`

## Tool versions

yosys 0.64+181 (git 8427bd3a3-dirty), nextpnr-himbaechel (oss-cad-suite),
apycula gowin_pack, iverilog 14.0 (s20251012), openFPGALoader, sigrok-cli.
