# Exact Otsu timing candidate v8

Candidate only. Changes build on v1 CSA multiplier, v2 load/scan product pipeline, v3 byte-serial delta subtraction. V4 additionally narrows only the private solver count input to min(COUNT_WIDTH,clog2(DEPTH+1)); histogram and external done_count remain COUNT_WIDTH and all original validity checks stay intact. A captured histogram bin cannot exceed DEPTH, so no reachable count bit is truncated.

Scores remain exact integer rational comparisons and ties still choose the first threshold. Original UART and independent numeric fixtures are unchanged. Seven UART normal/fault/watchdog simulations and all ten original threshold profiles pass. The original 5x4 constant-zero/constant-255 Otsu fixtures cover a bin count equal to the full capacity20.

New latency: B_W+ceil((A_W+B_W)/8) multiplier enabled clocks, one additional load/scan weight accumulation enabled clock, ceil(DW/8) enabled clocks for delta subtraction. No fixed result latency is promised; ready/valid backpressure is preserved.

Build command:
```
python cores/system/common_scaffold/board/tang25k/acceptance48/build_case.py cores/system/common_scaffold/board/tang25k/acceptance48/cases/threshold_optimized_v8 --attempt threshold_harnesspipe_20261018 --no-lutram
```

V5 replaces delay-only adaptive-mean/Gaussian output pipelines with four real arithmetic stages: partial sums, total/weighted sum and center/offset scaling, signed threshold subtraction, then strict comparison/inversion. All stage data/configuration/markers freeze together when CE is low or the final output is blocked. Maximum initiation interval is one enabled clock; unstalled result latency is four enabled sampling edges counting acceptance instead of the previous three. Numeric fixtures are unchanged. Original direct adaptive tests pass all eight profiles (mean/Gaussian,1/8/12/16bit),6800 comparisons, including accepted-window config capture, CE/backpressure and reset. Independent public threshold tests pass all ten profiles and seven UART tests pass.

V6 splits total/weighted accumulation into two enabled stages, giving five real arithmetic stages: per-row/corner partial sums; pair accumulation and scaled center/offset; final sum; signed threshold subtraction; strict comparison/inversion. Latency is now five enabled edges including acceptance. Eight direct adaptive profiles/6800 comparisons, ten public profiles, and seven UART cases all pass unchanged expectations. V5 seed3/5 setup failures remain preserved, unprogrammed.

V8 keeps V6 DUT sources exactly and replaces the isolated acceptance driver with the board-qualified geo_optimized/downsample_v4 driver (synchronous reset and precomputed final transfer indices). All five test ROM outputs are registered using window_frame_optimized/harness_rom_pipeline.py; the physical DUT CE divider remains4. These ROM registrations rely on stable indices between CE edges and do not represent a single-clock II1 board throughput test. All seven UART fault/normal/watchdog cases, ten public profiles and eight direct adaptive profiles pass. V7 simulation-only candidate is preserved and was not synthesized.
