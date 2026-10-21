# Fusion exact arithmetic/control timing candidate

Production, OSD and AWB sources remain unchanged by this agent. All new arithmetic helpers are fusion-private, keeping the board-proven OSD img_mf_rgb_blend_pipe intact.

Sources to integrate after root board validation:
- cip_image_fusion.v: scalar multiply handshake, exact CSA/byte-carry final sum, precomputed last indices and parallel-byte index/position increments. Last indices are captured on accepted cmd to preserve immediate next-cycle input readiness; no extra PREPARE state.
- img_mf_rgb_blend_partial_pipe.v: four-stage fusion-only RGB pipeline (input/config, nibble partial products, exact reconstructed17-bit products, final CSA/byte-carry round/sum). Helper II1 preserved; RGB helper latency3->4 enabled sampling edges counting acceptance.
- cip_fusion_scalar_multiply.v: private renamed copy of the qualified histogram CSA serial multiplier. Two parallel DATA_Wx9 paths take9 carry-save iterations plus ceil((DATA_W+9)/8) byte-fold iterations. Scalar response waits explicitly; output/data/error contracts stay unchanged.

A premature PREPARE prototype violated the old reset test's immediate post-cmd input assumption; it was removed, no original TB or expectations changed. Its failed log remains preserved. A supplementary full-rate helper test originally had a blocking-assignment stimulus race; the corrected NBA checker passes identical helper RTL on both v6/v7, and the original failed test log is retained separately.

Validation:
- Seven UART normal/fault/watchdog cases PASS, including ISSUE/NEXT fault checks.
- Original independent fusion suite:5 profiles,1777commands26496outputs16resets PASS, unchanged expected values.
- New independent full-product helper oracle:4096 burst records, mixed bypass/errors/weights, tag/frame IDs/markers, CE/output stalls and two reset/replay epochs PASS.
- Routed setup53.08MHz at50MHz, placement76.77MHz;2155LUT4,1199FF,8BSRAM,0DSP including harness. Setup/resource/route gates PASS. Hold timing remains unproven; no explicit hold violation.

Commands:
```
python cores/system/common_scaffold/board/tang25k/acceptance48/verify_fusion_candidate.py cores/system/common_scaffold/board/tang25k/acceptance48/cases/fusion_counts_v7
python cores/system/common_scaffold/board/tang25k/acceptance48/verify_blend_stream.py cores/system/common_scaffold/board/tang25k/acceptance48/cases/fusion_counts_v7
python cores/system/common_scaffold/board/tang25k/acceptance48/build_case.py cores/system/common_scaffold/board/tang25k/acceptance48/cases/fusion_counts_v7 --attempt fusion_counts_20261018 --no-lutram
```

Root owns JTAG and production integration. Generator/source-list/fusion-runner dependencies must include both new helpers; OSD keeps its existing helper/dependencies.
