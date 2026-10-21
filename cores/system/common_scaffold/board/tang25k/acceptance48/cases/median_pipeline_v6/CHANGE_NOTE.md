# Optional five-stage median candidate

Candidate only; no production source or JTAG operation changed by this agent.

The original three-comparator-layer segment causes a21.94ns routed path in median_filter_counts_v5. A new LAYERS parameter on img_filter_median_sort3_segment defaults to3, retaining existing use. img_filter_kernel3x3 gains MEDIAN_PIPE_STAGES default3 and preserves the original three-stage path. Its optional5 path partitions the same nine odd-even layers2+2+2+2+1, with four elastic full-vector registers and the existing result register. Public cip_image_window_filter_frame selects5 only for OP2; all other operations retain3.

Consequences: public median latency3->5 enabled unstalled edges counting acceptance, II1 maintained; CE/backpressure and markers remain aligned. Standalone generic median remains3-stage to preserve existing ten-kernel lockstep users. No values or fixtures changed.

Commands:
```
python cores/system/common_scaffold/board/tang25k/acceptance48/verify_median_candidate.py cores/system/common_scaffold/board/tang25k/acceptance48/cases/median_pipeline_v6
python cores/system/common_scaffold/board/tang25k/acceptance48/build_case.py cores/system/common_scaffold/board/tang25k/acceptance48/cases/median_pipeline_v6 --attempt median_pipeline5_20261018 --no-lutram
```

Seven UART simulations including injected ISSUE/NEXT errors and watchdog PASS;18 original public window-filter profiles PASS (846commands4986outputs36resets); default compatibility standalone167vectors PASS with original ready/valid alignment, CE and output stability assertions.

Routed setup60.81MHz at50MHz; placement64.5MHz.1824LUT4,905FF,3BSRAM,0DSP including harness. All setup/resource/route gates PASS. Hold remains unproven with no explicit violation; builder exits1 because of hold gate. Root owns actual SRAM/UART validation and production integration sequencing.
