# Isolated sliding-window memory board-qualification harness

`window_probe` pinpoints the simulation-vs-silicon divergence that makes the
CSC→morphology chain (`board/image_harness`) emit **0 instead of 95/84/84 at
frame positions x=0, y∈{2,3,4}** (pixels 16/24/32 of the 8×8 frame) on the Tang
Primer 20K while simulation passes 100%. See
`board/image_harness/RETIREMENTS.md` and `diagnostics/repaired_case00_left_edge.json`.

The failing chain reduces to: gray pixels → `stream_window_padded` (win1,
WIDTH=8, HEIGHT=8, K=3, PAD_MODE=1, full 3×3 mask erosion; win2 idle for op=0)
→ `morph_reduce`. The two BSRAM suspects inside the window are:

- `stream_window` K single-port banks: `q<=mem[x]` + `mem[x]<=s_tdata` in the
  same clocked process — read-during-write on one port, mapped to **SPX9
  WRITE_MODE=2** (read-before-write) in the retired/failing builds.
- `stream_window_padded` `row_mem`: capture-write `mem[x]` + replay-read
  `mem[sx]` where `sx` is a *combinational clamped* address — mapped to
  **DPX9B** (port A write / port B read).

## Probe design

Identical envelope to `image_harness`/`dsp_chain_harness` (POR, UART RX/TX
115200, dedicated synchronous store RAMs, stall pattern `cycle%8>=stall`,
echoed tag, counters, watchdog):

```
WPR1 tag cfg count stall pixel_bytes →  input RAM  → stream_window_padded
                                                             │ every m_tdata beat
WPO1 tag cfg count flags inc outc cycles + N window records ← output RAM
```

- Request: `"WPR1"`, tag u32 LE, config u32 LE (**must be 0**), count u16 LE
  (nonzero multiple of WIDTH·HEIGHT, ≤2048; each multiple is one frame), stall
  u8 (0..7), then `count` pixel bytes (one byte/pixel, DATA_WIDTH≤8).
- Response header (23 bytes): `"WPO1"`, tag, config, count u16, flags u8,
  input_count u16, output_count u16, RUN cycles u32.
- Then `count` records of REC_BYTES = ⌈(K·K·DATA_WIDTH+2)/8⌉ (10 bytes at
  K=3/8-bit): `{sof, eol, window_lanes[K²·DW-1:0]}` little-endian — **all 9
  lanes of every output window are exported**, so a divergent board shows
  exactly which position AND which lane (row,col) is wrong, not just a digest.
- flags: bit0 invalid count/stall, bit1 UART framing, bit2 busy RX (sticky to
  next report), bit3 invalid config, bit4 watchdog (65535 cycles, exports the
  partial records), bit5 DUT marker_error (sticky).
- markers: `s_tuser` at each frame's first pixel, `s_tlast` at each row end —
  same generator pattern as `image_harness`.

## Divergence hypotheses and what each variant decides

| # | Hypothesis | Decisive observation |
|---|-----------|----------------------|
| H1 | Inferred-BSRAM behaviour wrong on silicon (bank RDW mode or DPX9B port/address handling) | `bram` FAILS, `reg` PASSES → BSRAM inference implicated |
| H2 | Yosys inference wires a wrong mode/port; the primitive itself is fine | `bram` FAILS, `prim` PASSES → inference implicated (prim uses identical modes: SPX9 WRITE_MODE=2, DPX9B WRITE_MODE=1) |
| H3 | Not the RAMs — control/timing (clamped `sx` comb path, capture-edge races, like the dsp_chain root cause) | ALL variants incl. `reg` FAIL → compare the `cycles` field and lane pattern; if `cycles` diverges the timing/sequencer is implicated |
| H4 | Harness-side store RAMs corrupt data | Same across all variants and would corrupt arbitrary record bytes, not a coherent window-lane pattern |
| H5 | Fault is upstream (CSC/morph_reduce or the composition), not the window | ALL variants PASS the exact failing gray frame + edge stress + multi-frame → suspicion returns to the CSC output timing or the reduce stage; the window is exonerated |

Lane-level interpretation on the board:

- Output x=0 windows draw **two lanes per row from `row_mem[0]` reads** (replay
  rx=0 clamps sx −1→0 and rx=1→0) — a `row_mem[0]` defect shows as zeros in
  window lanes {0,1,3,4,6,7} of left-edge outputs.
- Lanes of one window row wrong ⇒ the corresponding K-bank (row r ← bank
  (pbank+r+1) mod K) misread; new-vs-old data in a lane ⇒ SPX9 WRITE_MODE
  behaving as transparent(1) instead of read-before-write(2) on silicon.
- Repeated/shifted values ⇒ address or CE misbehaviour; random single bits ⇒
  timing; whole-record corruption ⇒ harness RAM (H4).

## Variants (build-time `--variant`, identical contract + expected values)

- `bram` — verbatim `infra/window/stream_window*.v` (ram_style="block").
- `reg` — same logic, `ram_style="registers"` on row_mem and all K banks;
  yosys log confirms `forced mapping to FF`; harness RAMs remain BSRAM.
- `prim` — same logic, explicit `SPX9 #(.BIT_WIDTH(9),.WRITE_MODE(2),
  .READ_MODE(0),.RESET_MODE("ASYNC"))` banks and `DPX9B` row_mem with the same
  parameters baseline inference produced. Physical 9-bit address is
  `{word_index[10:0],3'b000}` (AD[13:3]), decoded from `brams_map.v` and the
  retained mapped netlists. Requires DATA_WIDTH≤9.
  `variants/prim/gowin_prims_sim.v` provides iverilog models only.

## Run

```powershell
python cores\signal_processing\dsp_isp_library\board\window_probe\run.py --variant bram --preset w8 --build
python cores\signal_processing\dsp_isp_library\board\window_probe\run.py --variant reg  --preset w8 --build
python cores\signal_processing\dsp_isp_library\board\window_probe\run.py --variant prim --preset w8 --build
python cores\signal_processing\dsp_isp_library\board\window_probe\run.py --variant bram --preset w32 --build
```

- `--preset w8` = 8×8 K=3 PAD_MODE=1 (the failing chain's window); `--preset
  w32` = 32×24 K=3 PAD_MODE=1. `--width/--height/--k/--pad-mode/--data-width`
  override individually (K∈{3,5}, PAD_MODE∈{0,1}, DATA_WIDTH≤8).
- `--replay-json vectors/failing_gray_8x8.json` replays the exact failing
  frame(s); `--replay-plus-default` appends the standard case matrix.
- Evidence dir `evidence/wp_<variant>_<W>x<H>k<K>p<P>d<DW>_<ts>/` freezes all
  sources, oracle, stim, raw UART bytes, hashes, mapped JSON, resource/timing
  and `window_probe.fs` — the same convention as the other board harnesses.

Simulation gates: real 115200 UART timing for every byte; every record checked
against the independent `infra/window/model.py` raster oracle; the `cycles`
field checked against a faithful FSM cycle model of both modules; tag/config/
count/flag counters; controlled corruptions must be rejected; six invalid
packets; tb_fault covers truncation, bad stop, late-busy-RX and forced
watchdog. Build gates: `synth_gowin -noalu`, ≤15000 LUT-class, ≤4 DSP,
nextpnr at real 27 MHz constraint with min Fmax ≥27, warning/structural audit,
pack to `window_probe.fs`.

## Board-runner notes for the main agent

- Pins identical to the other harnesses (`uart_injection_probe.cst`): H11 clk,
  T13 UART RX, M11 UART TX, A11 mirror for FX2 D0. SRAM program only.
- Response size = `23 + count·REC_BYTES`; REC_BYTES=10 for both qualified
  presets. Host must await the complete response before the next packet.
- Suggested runner shape = `run_image_board.py`/`dsp_chain_harness/run_board.py`
  with `protocol.make_packet/verify`; expected data is always recomputed from
  the frozen oracle — never trust a stored expected blob.
- This harness is strictly a *window* qualification: CSC and `morph_reduce`
  are deliberately absent. If every variant passes the exact failing gray
  frame, the divergence is upstream of win1 (CSC output timing/marker
  generation) or in the reduce/compose stage — see TESTPLAN decision tree.
