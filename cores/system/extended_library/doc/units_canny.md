# wave2_ip_20k — Group B units (idx6–9): Canny edge-detector chain

Agent B deliverables. Each stage is a separate stream unit; the chain
composes as `stim → canny_grad → canny_nms → canny_dth → canny_hyst`.
Stimulus in every st_ cell is `w2_img_stim` 32×32, frame 0.

Golden source (independent model, T1): `tools/golden_canny.py`
— replicates the w2_img_stim pixel formula, clamped (edge-replication)
3×3 windows, and each stage's arithmetic. Writes
`sim/golden_canny_{grad,nms,dth,hyst}.txt` (one hex byte/line) and prints
`TAG DIGEST=XXXXXXXX`.

## idx6 CGR — `canny_grad`

Sobel gradient stage. Internally: `win3x3_gen` (imgwin shared cell) +
shift/add Gx,Gy datapath.

- In: `pix[7:0]`, `pix_valid`, `new_line` (input-side convention:
  dedicated new_line beat per row, then IMG_W pixels).
- Out (one `clk_en` beat after each emitted window):
  `mag_out[7:0]` = min(|Gx|+|Gy|, 255);
  `dir_out[1:0]` = gradient orientation class
  (`0`=~0° if `8|Gy|<=3|Gx|`; `2`=~90° if `8|Gx|<=3|Gy|`; else `1`=45°
  when sign(Gx)==sign(Gy), `3`=135°; both axis tests true only at
  Gx=Gy=0 → dir 0 by priority).
  `out_valid`, `nl_out` (flag on first valid pixel of each output row),
  `done` (holds).
- Byte-stream contract for digest/golden: **mag byte then dir byte**
  (zero-extended) per valid pixel → 2048 bytes/frame.
- EXP digest: `32'h9764CD67` — `CGR DIGEST=9764CD67`.

## idx7 NMS — `canny_nms`

Non-maximum suppression along the gradient direction.

- In: `pix[7:0]` = magnitude, `dir[1:0]` = direction (the canny_grad
  output pair), `pix_valid`. `new_line` accepted but ignored — a frame
  is exactly IMG_W·IMG_H valid pixels, so either stream convention works.
- Architecture: **frame buffer**, not a streaming line buffer. Input
  pixels are stored sequentially into two `w2_dpram` banks (mag W=8,
  dir W=2, DEPTH=1024); at 1024 pixels two `w2_win_rd` readers walk the
  frame in lockstep emitting clamped 3×3 windows. Input cadence is
  fully decoupled; any valid-beat pattern works. Readers are held in
  reset during the write phase (`rd_rst_n = rst_n && st!=ST_WR`) because
  `w2_win_rd` is single-shot — the next frame re-arms cleanly.
- Rule: keep centre iff `c >= n1 && c >= n2` (ties keep), else 0.
  Neighbour taps by dir: `0`→(w3,w5); `2`→(w1,w7); `1`→(w0,w8);
  `3`→(w2,w6). i = r·3+c row-major, same layout as win3x3_gen.
- Out: `pix_out[7:0]` thinned mag, `out_valid`, `nl_out`, `done`.
- EXP digest: `32'hE28D6593` — `NMS DIGEST=E28D6593`.

## idx8 DTH — `canny_dth`

Double-threshold classifier, pure per-pixel pipeline (1-beat latency).

- In: `pix[7:0]`, `pix_valid`, `new_line` (passed through).
- Params `TH_LO`, `TH_HI`. Out `cls_out[1:0]`: `pix>=TH_HI`→2 (strong),
  `pix>=TH_LO`→1 (weak), else 0.
- st cell feeds it the **raw** grad mag stream with TH_LO=100/TH_HI=200
  (richer class mix: 21 none / 54 weak / 949 strong; the NMS stream on
  this stimulus only contains {0,232,248,255}). The canonical
  NMS→DTH adjacency is exercised inside `st_canny_hyst` with
  TH_LO=200/TH_HI=255.
- EXP digest: `32'hE2A5329F` — `DTH DIGEST=E2A5329F`.

## idx9 HYS — `canny_hyst`

3×3 hysteresis, same frame-buffer architecture as canny_nms (one
`w2_dpram` W=2 + one `w2_win_rd`).

- In: `cls[1:0]` class stream (dth output), `pix_valid`; `new_line`
  ignored (frame = W·H valids). Frame re-arm supported (see nms).
- Rule (**single-pass local propagation — documented approximation**):
  strong → `8'hFF`; weak → `8'hFF` iff any of the 8 clamped neighbours
  is strong; else `8'h00`. A promoted weak does NOT re-promote other
  weaks in the same frame (no iterative flood-fill as in full Canny
  tracing); weak chains more than one pixel from a strong seed are cut.
- st cell runs two sequential frames into the SAME dut:
  pass A = canonical chain stim→grad→nms→dth(200/255)→hyst;
  pass B = synthetic class frame (`cls = 2` at x%8==0&&y%8==0; `1` at
  x%8<=1&&y%8<=1 or x%8==4&&y%8==4; else 0) — 16 strong, 48 promoted
  weak, 16 **isolated** weak (rejection path; the stim frame has no
  isolated weak pixels — all weak are strong-adjacent).
- EXP digest: `32'h6785454B` — `HYS DIGEST=6785454B` (2048 bytes).

## Verification evidence

Commands run from `cores/system/extended_library` (oss-cad-suite on PATH):

```bash
python tools/golden_canny.py
#   CGR DIGEST=9764CD67  NMS DIGEST=E28D6593
#   DTH DIGEST=E2A5329F  HYS DIGEST=6785454B

iverilog -g2012 -I src -o sim/tb_st_canny_grad.vvp -s tb_st_canny_grad \
    sim/tb_st_canny_grad.v src/canny_grad.v src/st_canny_grad.v \
    src/w2_img_stim.v ../imgwin_20k/src/win3x3_gen.v \
    ../imgwin_20k/src/line_buf_ram.v sim/gowin_bsram_sim.v
vvp sim/tb_st_canny_grad.vvp   # W2TB CGR PASS D=9764cd67 C=1103

# nms/hyst add src/w2_dpram.v src/w2_win_rd.v; dth adds src/canny_dth.v
vvp sim/tb_st_canny_nms.vvp    # W2TB NMS PASS D=e28d6593 C=10324
vvp sim/tb_st_canny_dth.vvp    # W2TB DTH PASS D=e2a5329f C=1103
vvp sim/tb_st_canny_hyst.vvp   # W2TB HYS PASS D=6785454b C=29792
```

`diff sim/golden_canny_<u>.txt sim/dump_canny_<u>.txt` — byte-exact for
all four units (2048/1024/1024/2048 lines).

## synth_gowin stat (per core, LUT-class = LUT1-4+MUX2_LUT5+ALU)

| unit | LUT-class | DFF | BSRAM | DSP | verdict |
|---|---|---|---|---|---|
| canny_grad | 414 | 130 | 2 | 0 | ≤1500 ✓ |
| canny_nms  | 516 | 200 | 2 | 0 | ≤1500 ✓ |
| canny_dth  |  13 |   4 | 0 | 0 | ≤1500 ✓ |
| canny_hyst | 238 |  89 | 1 | 0 | ≤1500 ✓ |

## Known limits

- NMS/HYS are frame-buffered: output starts only after the full frame is
  stored (≈W·H beats write + 9·W·H beats readout). Not a streaming
  real-time pipeline stage; use win3x3_gen cascade if latency matters.
- Input frames must be exactly W·H valid pixels; extra pixels arriving
  during readout are dropped (documented, no error flag).
- HYS single-pass propagation (see above) — weak chains >1 px from a
  strong seed are not traced.
- On this stimulus every weak pixel is strong-adjacent, so the
  isolated-weak rejection path is covered only by the synthetic pass-B
  frame in st_canny_hyst.
- IMG_W must be a power of two and IMG_W·IMG_H ≤ 1024 (w2_win_rd /
  single w2_dpram bank).
