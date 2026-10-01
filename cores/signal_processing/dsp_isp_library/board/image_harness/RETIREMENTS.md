# Withdrawn builds

The following historical build summaries are preserved but withdrawn because synthesis reported a combinational configuration-ready loop:

- `image8_pad1_20260925_034309_654919`, SHA256 `5dd9356e7f74133d336a2e3986a4993e1bc8df4c8c3ff28a836a04cf2f46ea9d`.
- `image10_pad1_20260925_034540_581291`, SHA256 `b4b33a1bbe4347e3cebd068339020b3d4f9d6b27a51a1f747c6e0c788404d242`.

The first image was programmed before withdrawal and failed physical comparison: pixels 16/24/32 were zero instead of 95/84/84. Evidence is `artifacts/dsp_isp_20260925/isp_chain8_board_01/verdict.json` and its retained case_00 input/capture. The loop has been removed with registered configuration-pending tracking, but it is NOT established as the cause of these pixel errors. Inferred window memories still require independent physical qualification. No board acceptance is claimed.

The loop-corrected 8-bit image `image8_pad1_20260925_035358_204245`, SHA256
`f19395e3f1e939aef41046d41793c7de525536dfe40b2fce821dc1b4c7a7f10d`, subsequently
failed the same physical frame at the same three pixels (`isp_chain8_repaired_replay_01`).
It passed build checks but is NOT board-qualified. Stall 7 added seven more pixel
errors (`isp_chain8_stall7_diagnostic_01`). The loop correction is therefore not
a sufficient fix. `diagnostics/repaired_case00_left_edge.json` records the exact
stall-0 left-edge-zero behavioral signature without claiming a root cause.
