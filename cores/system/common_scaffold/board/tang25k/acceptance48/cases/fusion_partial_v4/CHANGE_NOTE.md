# Fusion-only exact partial-product pipeline candidate

Only candidate source files are changed. OSD and its original three-stage img_mf_rgb_blend_pipe remain untouched. Public cip_image_fusion RGB branch now instantiates the new img_mf_rgb_blend_partial_pipe module.

Four elastic stages: capture pixels/weight/complement/config; multiply low/high pixel nibbles by nine-bit weights; exactly reconstruct each17-bit product; sum/round and original bypass/error selection. Each full product equals low_product+(high_product<<4), no clipping or approximation. All markers/tag/frameid/error advance with their pixel under CE/ready-valid control. RGB helper latency3->4 enabled unstalled edges including acceptance; II1 maintained. Scalar modes unchanged.

Seven UART normal/fault/watchdog cases PASS; all five original independent fusion profiles PASS:1777commands26496outputs16resets, unchanged goldens. Includes modes, signed-independent scalar widths, RGB weights and error paths, CE/backpressure and reset recovery.

Commands:
```
python cores/system/common_scaffold/board/tang25k/acceptance48/verify_fusion_candidate.py cores/system/common_scaffold/board/tang25k/acceptance48/cases/fusion_partial_v4
python cores/system/common_scaffold/board/tang25k/acceptance48/build_case.py cores/system/common_scaffold/board/tang25k/acceptance48/cases/fusion_partial_v4 --attempt fusion_partial_20261018 --no-lutram
```

Integration, if accepted, needs new helper registered in source list/generator and public fusion dependency; OSD should keep the original helper. Root owns actual SRAM/UART validation and serial integration.
