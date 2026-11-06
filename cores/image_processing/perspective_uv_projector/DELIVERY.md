# B45 finite qualification delivery

The once-only approved run and an independent read-only evidence audit both
passed. Current maturity is **LINT_PASS / UNIT_SIM_PASS /
INTEGRATION_CANDIDATE / HW_UNVERIFIED**. Frozen README/STATUS/manifest files
retain the pre-execution source-review snapshot; this receipt and
`QUALIFICATION.json` record the resulting bounded qualification.

Baseline: `a0602fb2dac20db7c524297371a19f5f580980df`.
The root reviewed the complete source, and worker A independently reviewed the
original source and amendment01. Root issued the unique
`B45_PERSPECTIVE_UV_ONCE_01` gate. Execution evidence is in
`reports/20261106T132303_174489Z/results.json`.

| Binding | SHA256 |
|---|---|
| Source seal | `b4133a088357ab284d7b36a03dd8baa6e0083e873d684f0f1233f61091c85452` |
| Finite plan | `867335d36b67557a041b95241e0bc5d4cf27f06815070a9b612f634f05b4f469` |
| Root gate/review | `aa348bdd873d3ff04bc1b505982f522dc4a7e57b6e322678a3e7c552920e528c` |
| Results receipt | `b76088041c4b1b1b79b2bd96c3f742592917f263e0002893ed48fc6af3a24565` |
| Once-only lock | `02435a88f3bee861719787b953b641dd60e74de613bd70623d5f7236338ea862` |

Exactly4 preparation children and10 HDL children ran:2 syntax,4 compile and4
simulation. All14 returned0 with confirmed exit, complete capture and no timeout;
no cleanup helper was started. Maximum recorded child elapsed time was1.547s,
within the20s child bound. The5s tree/sole2s exit-and-drain branches were not
exercised. No retry or additional preparation/simulation was performed for this
delivery audit. Four oracle definition loads and four numerical preparations
are recorded; the runner imported no oracle.

| Simulation profile | Main configs | Checked outputs | Config faults | Counted resets |
|---|---:|---:|---:|---:|
| Core Q1 / TAG1 | 12 | 144 | 3 | 9 |
| Core Q16 / TAG32 | 12 | 144 | 3 | 9 |
| Actual8x7 / texture5x4 / Q16 / TAG8 | 9 | 84 | 2 | 7 |
| Actual256x256 / texture256x256 / Q16 / TAG32 | 9 | 84 | 2 | 7 |

These counters cover42 main vector configurations,456 exact checked outputs,
10 invalid configurations and32 counted resets. Reset fixtures generate extra
traffic outside the main scored-output counter. TB hold counters total1824
output-hold cycles,72 core configuration-response holds,72 wrapper DONE holds
and96 management-response holds.

The passing core TB asserts response-valid latency15/3/0 for valid/degenerate/
zero-q configuration, and result-valid latency47/10 for covered/outside queries.
Both winding orders, edge/outer queries, signed coordinate extremes, q widths,
maximum q, UV0/255, both tie parities, full tag patterns, configuration priority,
input-bus mutation, output ownership and reset/recovery are in the finite vectors
or source-defined probes. The actual wrapper instantiates the unchanged raster
and sampler; its checks cover ordered RGBA, top-left adjacent triangles, clipped
geometry, transparent and out-of-range texels, runtime loading, fragment drain,
texture lock through held DONE and cancellation/reload after reset.

The metadata audit rehashed25 current and25 archived source bindings, the three
current/archived control pairs,24 tool/runtime entries,16 vector/receipt files,
4 original `.vvp` images,14 per-child JSON records and28 raw stdout/stderr files.
It also matched exact child order/argv/cwd, preparation headers/byte lengths,
raw PASS markers/counters, aggregate/per-child records and image compile/execute
hashes. Hash mismatches:0. All14 recorded PIDs have confirmed terminal status;
there are no recorded active target/helper processes. This was a PowerShell
JSON/text/SHA256 audit, with no project-source imports or numerical/HDL rerun.

All simulation stderr is empty. The six syntax/compile records retain Icarus
warnings about array-wide `@*` sensitivity and explicit/inherited timescales;
qualification is not a warning-free lint claim. Their raw bytes remain intact.

Coverage remains finite. Maximum-dimension simulation uses sparse6x6/3x3
triangles with complete runtime texture loads, not a full-screen workload.
Closed-triangle core coverage and top-left wrapper coverage remain distinct
contracts. Results are exact for the supplied positive quantized reciprocal-W,
with final nearest-even integer UV rounding. No near-plane clipping, filtering,
mipmap or depth-buffer capability was added. No synthesis, PnR, STA, board,
physical resource, clock, power, PPA or frame-rate evidence exists.

The original source-only metadata and runner remain preserved under
`planning/*.initial`; the reviewed amendment changes control/evidence handling
only. Frozen input, plan, gate, raw, image and historical files were not edited
by this delivery step.
