# Explicit 18-bit RAM diagnostic candidate

Default window RTL is unchanged. These drop-in files are opt-in candidates for
the CSC/morphology image harness, not physically accepted replacements.

The loop-corrected physical image still returned zero at output indices 16, 24
and 32 instead of 95, 84 and 84 for the saved host vector. Stall 7 retained those
errors and introduced seven more. Source simulation passes. This suggests testing
memory mapping and CE/response holding independently; it does not prove a cause.

The retained mapped netlist for `image8_pad1_20260925_035358_204245` has six SPX9
line banks at width 9 and two inferred DPX9B row caches at width 9. Row-cache port
A CE is constant and B CE is issue. Line bank CE is take, with current-bank write
collision bypassed by the RTL pixel register. The candidate uses the explicitly
wired width-18 DPX9B convention previously used in the harness input/output RAM:
write address `{word,2'b00,2'b11}`, read address `{word,4'b0}`, output CE zero,
read CE driven by the corresponding issue. No additional output register is added.

Two controlled substitutions are supported:

- `--padded-source .../explicit18/stream_window_padded.v`: change row caches only;
  preserve inferred SPX9 line banks.
- Also `--window-source .../explicit18/stream_window.v`: change line banks too;
  disable the read port for the current writing bank, whose response is unused.

Each file supports width at most 1024 (10-bit word address), data at most 16 bits.
Both substitutions passed 192-frame chain regressions across 8/10-bit data and
ZERO/REPLICATE borders, including resets, queued configs, backpressure and all
four morphology operations. Evidence: `chains/csc_morphology/evidence/20260925_040740_934570`
(row only) and `20260925_040754_339321` (row plus line).

Run from repository root, changing only the candidate options to select the test:

```sh
python cores/signal_processing/dsp_isp_library/chains/csc_morphology/test_chain.py --padded-source cores/signal_processing/dsp_isp_library/infra/window/candidates/explicit18/stream_window_padded.v
python cores/signal_processing/dsp_isp_library/board/image_harness/run.py --bits 8 --padding 1 --padded-source cores/signal_processing/dsp_isp_library/infra/window/candidates/explicit18/stream_window_padded.v --replay-json artifacts/dsp_isp_20260925/isp_chain8_board_01/case_00/expected.json --replay-plus-default --build
```

The UART run retains the exact failed frame, adds the same frame at stall 7,
then executes all 16 default cases and five negative packets. Expected pixels
remain independently computed; no golden values are changed.

Row-only UART/build evidence: `board/image_harness/evidence/image8_pad1_20260925_040905_089037`.
All 18 frames, five illegal packets and 180 checker mutations pass. Final mapped
netlist retains six SPX9 line banks and uses two width-18 row-cache DPX9B plus
four existing I/O-store DPX9B. Mapped/routed LUT counts are 2277/2337, DSP 0,
minimum reported Fmax 104.30 MHz. Strict warning audit passes. Image SHA256:
`079ad928f895d30e154261e88a28b225a0d63f97fd06852443732bc376d39f50`.
This is a diagnostic build, with physical acceptance pending.

Row-plus-line evidence: `board/image_harness/evidence/image8_pad1_20260925_040917_609180`.
The same 18/5/180 UART checks and warning audit pass. Final mapping contains
12 DPX9B and no SPX9, 2287 mapped/routed LUT, zero DSP, minimum Fmax 84.81 MHz.
Image SHA256: `201e79253920f59634393561720e505415ab1850ac2922a2fa2d91391ee2e69e`.
Try row-only first to retain the controlled distinction between the memory sites.
