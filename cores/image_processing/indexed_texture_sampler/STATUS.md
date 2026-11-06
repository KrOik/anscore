# B37 qualification status

LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED.

Root and B completed source-only review before root authorized the unique first
attempt. Receipt: `reports/20261106T043049833910Z/results.json`, SHA256
`e23f7f63e00cbf206cfd3e1f518316e2587fdafe6ee59e9c8617bcae573b6bf4`.
One independent preparation; all11 ordered children and4 simulations PASS;
zero failures, timeouts, cleanup actions or retries. Each child's20-second
deadline was respected (maximum0.547seconds). Executable inputs remain frozen.

The core checked48 +576 +72 =696 outputs. Each profile verified always-ready
three-edge acceptance latency and II1; held transactions and management drain
were checked. The9x5 profile canceled five live phases (partial load, index
stage, palette stage, held output and held management response), then fully
reloaded and checked each recovery. Across the four simulations there were
10 resets:4 initial and6 live. Core output holds totaled440cycles.

The actual affine raster → resident palette sampler → RGB/Z store composition
checked384 pixel records from two complete16x12 frames;19 triangle commands
were accepted,18 completed and1 was reset-canceled. Full-frame outputs stalled
for128cycles. Completed-frame counters were seen116/passed91/OOB0 per frame;
the independent scene also exercised15 transparent and16 out-of-range UV
samples per completed frame. Invisible fragments never entered the RGB/Z store.

All11 current/archive inputs,18 vectors,22 raw streams, exact plan arguments
and2 tool binaries passed the post-run hash audit. Four successful VVPs remain
for root-owned post-commit path/hash cleanup. Raw evidence is unchanged.
Inherited/no-explicit timescale and @* array-sensitivity notices came from the
unchanged raster/store dependencies; simulation stderr is empty.

Default logical RAM40,960bits, maximum532,480bits; storage risk MEDIUM/HIGH.
Maximum texture profile is one complete65,536-index/256-palette load and72
selected sparse samples. The renderer profile is16x12; no maximum rendering
scene or broad old-package regression ran. No synthesized memory fit, device
frequency or display-throughput claim is made. Synthesis/PnR/STA/board are NOT_RUN.
