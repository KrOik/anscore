# imgwin_20k Validation Log

Streaming image-processing IP batch for Sipeed Tang Primer 20K
(Gowin GW2A-LV18PG256C8/I7, 27 MHz board clock, UART 115200 on COM24/M11).

## Units under test

| # | unit | function | kernel |
|---|------|----------|--------|
| 0 | WIN  | `win3x3_gen` shared 3x3 window extractor (2 BSRAM line buffers) | edge-replication borders |
| 1 | GAUS | `gaussian3x3` blur | (1/16)*[[1,2,1],[2,4,2],[1,2,1]], shift-add |
| 2 | SOB  | `sobel_edge` | Gx,Gy -> \|Gx\|+\|Gy\| saturate + binary |
| 3 | MED  | `median3x3` | 7x sort3 network, exhaustively verified |
| 4 | MRP  | `morph3x3` | binary erode (AND) / dilate (OR) |
| 5 | THR  | `threshold_bin` | fixed threshold binarization |

## Border policy

Edge replication (clamp): tap(r,c) = I[clamp(y+r-1,0,H-1)][clamp(x+c-1,0,W-1)].
Identical implementation in RTL (`src/win3x3_gen.v`) and the independent
golden model (`tools/golden_model.py`). Documented in every IP README.

## Golden model

`tools/golden_model.py` — pure Python, no RTL reuse. 16x16 deterministic
formula image `I[x][y] = (x*16+y*5+((x*3+y*7)%11)*4)&0xFF`. Emits
`sim/golden_{win,gau,sob,med,mrp,thr}.txt` + `sim/expected_report.mem` and
exhaustively proves the median sort3-network equals a true 9-element sort.

Golden FNV-1a digests (256 result bytes each):

```
WIN  BD71944D
GAUS 1C69D353
SOB  E1762120
MED  A3A98A3C
MRP  3E86450A
THR  9FFADFC0
```

## RTL simulation (iverilog / vvp)

`sim/tb_imgwin_selftest.v` — per-unit FNV-1a digest, `UNIT_EN` mask,
case-equality verdicts, stream dumps byte-compared against golden files.
Self-test `clk_en` = clk/16 strobe for timing margin. All iverilog
compiles include `sim/gowin_bsram_sim.v` (behavioral model of the DPX9B
primitive instantiated by `line_buf_ram`, with the measured
registered-DO behaviour).

| mask | units | result |
|------|-------|--------|
| 3F (full)  | all six    | PASS — all digests match golden |
| 0F (lower) | U0..U3     | PASS — S verdict on masked units |
| 30 (upper) | U4..U5     | PASS — S verdict on masked units |

`sim/tb_top_uart_report.v` — UART byte capture vs `expected_report.mem`,
all three masks: PASS x3.

## Synthesis (OSS CAD Suite)

```
yosys -p "read_verilog -sv src/line_buf_ram.v src/win3x3_gen.v \
  src/gaussian3x3.v src/sobel_edge.v src/median3x3.v src/morph3x3.v \
  src/threshold_bin.v src/img_stim.v src/imgwin_selftest.v src/uart_tx.v \
  src/top.v; synth_gowin -family gw2a -top top -json build_oss/top.json; stat"

nextpnr-himbaechel --json build_oss/top.json --write build_oss/pnr.json \
  --device GW2A-LV18PG256C8/I7 --vopt family=GW2A-18 --vopt cst=src/top.cst

python3 gowin_pack-script.py -d GW2A-18 -o build_oss/imgwin_20k.fs build_oss/pnr.json
```

### Resource utilization (nextpnr, device utilisation)

| resource | used | avail | % | budget check |
|----------|------|-------|---|--------------|
| LUT4     | 7200 | 20736 | 34% | < 15K LUT-class PASS |
| MUX2_LUT5|  172 | 10368 |  1% | — |
| ALU      | 1774 | 15552 | 11% | — |
| DFF      | 1205 | 15552 |  7% | — |
| BSRAM    |   10 |    46 | 21% | <= 46 PASS (10 DPX9B: 5 window gens x 2 line bufs) |
| DSP (all MULT*/PADD*/ALU54D) | 0 | — | 0% | 0-DSP requirement PASS |
| IOB      |    4 |   384 |  1% | clk + uart_tx + 2 status LEDs |

Timing: nextpnr estimated max frequency 37.81 MHz > 27 MHz — PASS.

Bitstream: `build_oss/imgwin_20k.fs` (~7.26 MB).

## Board validation — PASSED (after BSRAM silicon fix)

### Capture method

COM24 (on-board FTDI UART) returns zero bytes on this machine even for
known-good bitstreams, so the UART report was captured with a sigrok
`fx2lafw` logic analyzer on the PMOD header. `src/la_debug_top.v` wraps the
production `top` and mirrors `uart_tx` to pin A11 (LA channel D0), plus
status mirrors on B11/N6/D11. `tools/la_uart_decode.py` decodes 115200 baud
from the 1 MS/s binary dump. The debug wrapper runs the identical
`UNIT_EN=6'h3F` selftest.

### First board run — FAIL (real silicon bug found)

```
IMG6 M=3F P=20
U0 WIN  F D=DCD0334D     U3 MED  F D=34044984
U1 GAUS F D=82869D5D     U4 MRP  F D=730C982E
U2 SOB  F D=FAD56C2C     U5 THR  P D=9FFADFC0
```

The register-only threshold path passed; every line-buffer-backed unit
failed with stable wrong digests. A window-stream dump
(`doc/board_win_dump.bin`) showed the hardware window stream had column
address `c ^ 1` — a physical read-address bit-0 inversion inside the
inferred BSRAM.

### Root cause

`line_buf_ram` was written as an inferred `(* ram_style = "block" *)`
9-bit memory. Yosys `memory_libmap` mapped it to `DPX9B` with a
byte-enable/address encoding that is functionally wrong on this GW2A-18C
silicon: sequential reads return lane-shifted / address-permuted data.
Three further inferred variants (9-bit word, 18-bit word, duplicated-lane
write) all produced scrambled read-back on hardware probes.

Fix (verified by a dedicated UART read-back probe streaming 00..7f
flawlessly): **direct `DPX9B` instantiation** replicating the exact netlist
pattern apycula produces for the board-proven `cnn_systolic_20k` RAMs —
`BIT_WIDTH_0/1=18`, `ADA={waddr[9:0],2'b00,2'b11}`,
`ADB={raddr[9:0],4'b0000}`, `RESET_MODE=ASYNC`, port A write / port B read.

Second silicon behaviour found afterwards: `DOB` is **registered by CLKB
whenever CEB is high** even with `READ_MODE1=0`/`OCEB=0`. A first fix kept
an external output register (two-tick read) and produced digests
`WIN=4771D2AC` etc.; a simulation with a registered-DOB model reproduced
those exact values, confirming the mechanism. `CEB = clk_en & re` now makes
the internal register update under the same condition as the original
`if (clk_en) if (re) q <= mem[raddr]`, preserving one-tick semantics.
`sim/gowin_bsram_sim.v` models the measured behaviour (registered DO).

### Final board run — PASS

`doc/board_uart_full.txt` (sigrok LA decode, ch0=A11):

```
IMG6 M=3F P=3F
U0 WIN  P D=BD71944D     U3 MED  P D=A3A98A3C
U1 GAUS P D=1C69D353     U4 MRP  P D=3E86450A
U2 SOB  P D=E1762120     U5 THR  P D=9FFADFC0
```

All six digests match the independent golden model — **hardware PASS**.

## IP packages

`ip/<name>/` contains `gw2a_img_<name>.v` wrapper + `ip_manifest.json` +
`README.md` + per-IP `synth.log`. All six wrappers pass standalone
`iverilog -g2012` elaboration and `synth_gowin` (see `ip/*/synth.log`).

Index: `ip/MANIFEST.md`.

## Deviations

- Otsu threshold: intentionally omitted (task marks it optional); fixed
  `THRESH` parameter implemented instead.
- `line_buf_ram` instantiates the Gowin `DPX9B` BSRAM primitive directly
  instead of relying on inference — required for correct behaviour on
  GW2A-18C silicon (see "Root cause" above). BSRAM count is unchanged
  (10 cells). For iverilog, `sim/gowin_bsram_sim.v` provides the matching
  behavioral model (registered DO); it is listed as `sim_aux_sources` in
  the IP manifests.
- COM24/FTDI UART capture is dead on this setup; board evidence was taken
  through a sigrok fx2lafw logic analyzer via `src/la_debug_top.v`
  (uart_tx mirrored to A11). `top` still drives uart_tx on M11 unchanged.
- Self-test `clk_en` runs at clk/16 (digest-chain timing margin); the filter
  datapaths themselves are full-rate capable.
- `img_stim` and `imgwin_selftest` are on-chip test infrastructure, counted
  in the utilization above; the six IPs alone are smaller (see per-IP
  `ip/*/synth.log`).
- Diagnostic sources kept for reference: `src/la_debug_top.v`,
  `src/la_debug.cst`, `src/dump_top.v`, `src/dump.cst`,
  `src/ram_probe_top.v`, `src/ram_probe2_top.v`, `src/ram_probe3_top.v`,
  `src/la_probe2_top.v`, `src/la_probe2.cst`, `tools/la_uart_decode.py`,
  `tools/emulate_hw_bug.py`. They are not part of the production `top`
  build; `ram_probe2_top` is the DPX9B wiring proof and `ram_probe3_top`
  is the DOB-latency probe.
