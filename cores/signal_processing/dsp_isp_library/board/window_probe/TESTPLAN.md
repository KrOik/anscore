# window_probe board test plan (for the main agent — sole board owner)

All builds are pre-qualified in simulation+route; each evidence dir contains
`window_probe.fs`, `hashes.json`, `build_summary.json`. Program **SRAM only**.

## Builds under test

| Build | Variant | Preset | Purpose |
|-------|---------|--------|---------|
| wp_bram_8x8k3p1d8_*  | bram | 8×8 K3 pad1 | exact reproduction of failing window config |
| wp_reg_8x8k3p1d8_*   | reg  | 8×8 K3 pad1 | BSRAM refutation: all window RAMs are FFs |
| wp_prim_8x8k3p1d8_*  | prim | 8×8 K3 pad1 | explicit primitives, same modes as inferred |
| wp_bram_32x24k3p1d8_*| bram | 32×24 K3 pad1 | larger geometry / deeper banks |
| wp_reg_32x24k3p1d8_* | reg  | 32×24 | control |
| wp_prim_32x24k3p1d8_*| prim | 32×24 | control |

## Run order and vectors

1. **wp_bram w8** — replay `vectors/failing_gray_8x8.json` (3 packets: stall0,
   stall7, 3-frame). This is the exact gray frame that fed win1 in the failing
   chain runs; expected windows are recomputed by `protocol.verify`.
   Then the full default case matrix (`run.py --variant bram --preset w8`
   stimulus is reproducible: failing frame, edge-contrast, extremes, ramps,
   random ×stalls, multi-frame).
2. **wp_reg w8** — same vectors.
3. **wp_prim w8** — same vectors.
4. **wp_bram / reg / prim w32** — default matrix (no failing frame applies;
   it is 8×8-specific). Use the 32×24 cases from `protocol.cases(32,24,8)`.

Response math: `23 + count·10` bytes per packet (REC_BYTES=10 at K=3/8-bit).
count = total input pixels = total output records (WIDTH·HEIGHT per frame).

## Decision tree

- **bram w8 fails on failing_gray, reg w8 passes** → H1 confirmed: inferred
  BSRAM (SPX9 banks and/or DPX9B row_mem) misbehaves on silicon.
  Then run prim w8:
  - prim fails the same way → H2 refuted; the *primitive behaviour itself*
    (RDW mode / read-port timing / address decode) is the culprit. Lane
    pattern localizes: left-column lanes {0,1,3,4,6,7} zero at x=0 → row_mem[0]
    read path (clamped `sx`); one window row wrong → that K-bank.
  - prim passes → yosys *inference/wiring* (not the hard macro) is at fault;
    diff `top.json` cell wiring between bram and prim builds.
- **All w8 variants fail identically** → H3: not a memory primitive issue —
  inspect the exported `cycles` (a control/sequencer timing divergence shows
  there first) and whether lane errors correlate with position or data.
- **bram w8 passes the failing frame and full matrix** → H5: window exonerated
  for this vector; divergence is upstream — re-examine `csc_stream` output
  timing (the long-combinational-path class already root-caused in the DSP
  chain) or `morph_reduce`/compose. Do NOT retire the window hypothesis until
  stall7 + 3-frame + edge-contrast vectors also pass on bram.
- **w32 divergence but w8 clean** → depth/address-width dependent BSRAM issue
  (e.g., 34-deep banks vs 10-deep); compare lane patterns across geometries.
- **Record corruption not matching any window-lane pattern** (random bytes,
  shifted record stream) → H4 harness store RAMs or capture path; check
  `flags`, `inc`, `outc`, `cycles` fields first (they travel a different path
  than record payload).

## Negative results that still carry information

- If silicon `cycles` != FSM-model value but all payloads are right: timing
  divergence without data corruption — still report; it constrains which
  structures can be blamed.
- If flags bit5 (marker_error) sets on board but not sim: the DUT saw SOF/EOL
  misaligned — points at `in_x/in_y` marker timing, i.e., upstream stream
  contract on silicon, not RAM.

## Constraints

- Do not acquire `.boardlock` from this workspace; the main agent runs all
  programming/capture. This directory must not run openFPGALoader/sigrok/serial.
- Keep raw `.sr` + `decoded.bin` per case under `artifacts/`; the harness
  exports whole records so a failing lane diff is fully diagnosable offline.

## Resolution (2026-09-25)

All three silicon divergences identified and fixed; `fix5` passes the full
16-case suite on hardware (`artifacts/dsp_isp_20260925/window_probe_fix5_02`):

1. Harness input-store lookahead drift (fix1) — `input_count+1` during replay
   gaps; now `count` idle / `+1` only at take.
2. Inner `stream_window` `if(px==0) history[...]<=0` competing write — pad
   column never entered history on silicon; zeroing removed (was redundant).
3. `row_mem` issue-gated BSRAM read with widened shared CEB — under stalls the
   address reg re-sampled advanced `ridx` -> pairwise swaps; `ram_style="registers"`.

Debug tooling kept: `variants/dbg/` exports the raw padded-wrapper replay stream
(rd, row_q, first_pix, rx/ry, ridx, ppad/pzero) per raster position via
`run_board_dbg.py`; was decisive for proving the wrapper's rd correct and
localizing the defect to the inner window.
