# Exact Otsu timing candidate v4

Candidate only. Changes build on v1 CSA multiplier, v2 load/scan product pipeline, v3 byte-serial delta subtraction. V4 additionally narrows only the private solver count input to min(COUNT_WIDTH,clog2(DEPTH+1)); histogram and external done_count remain COUNT_WIDTH and all original validity checks stay intact. A captured histogram bin cannot exceed DEPTH, so no reachable count bit is truncated.

Scores remain exact integer rational comparisons and ties still choose the first threshold. Original UART and independent numeric fixtures are unchanged. Seven UART normal/fault/watchdog simulations and all ten original threshold profiles pass. The original 5x4 constant-zero/constant-255 Otsu fixtures cover a bin count equal to the full capacity20.

New latency: B_W+ceil((A_W+B_W)/8) multiplier enabled clocks, one additional load/scan weight accumulation enabled clock, ceil(DW/8) enabled clocks for delta subtraction. No fixed result latency is promised; ready/valid backpressure is preserved.

Build command:
```
python cores/system/common_scaffold/board/tang25k/acceptance48/build_case.py cores/system/common_scaffold/board/tang25k/acceptance48/cases/threshold_optimized_v4 --attempt threshold_capacity_20261018 --no-lutram
```
