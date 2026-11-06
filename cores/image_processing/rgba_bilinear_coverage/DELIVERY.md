# B46 coverage-correct bilinear filter delivery

Maturity: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
The exact root+worker_b approved plan completed once with **PASS**: five
separate numerical preparations, twelve HDL children and five successful
simulations. No failure, timeout, cleanup helper, surviving PID or retry.

Receipt: `reports/20261106T141011_122837Z/results.json`;
SHA256 `b65108623de3a186525ad72e5d511406708f13dd2ab5922283c82bc441713176`.
All seventeen children exited0 with durable exit/capture records and matched
raw output. Maximum recorded child elapsed time was2.703s, below20s.

The new filter preserves complete straight-alpha × color × bilinear-weight
products until final RNE, producing premultiplied RGBA. The actual wrapper
uses the unchanged resident indexed texture sampler for four clamped-neighbor
reads and the unchanged Porter–Duff composer. Query ownership blocks texture
management until the final composition output retires, including arithmetic
and held output. No resident RAM or composition arithmetic is duplicated.

| Finite profile | Main scored results | Main output-hold cycles | Live reset fixtures |
| --- | ---: | ---: | ---: |
| Core TAG1 | 268 | 1072 | 6 |
| Core TAG32 | 268 | 1072 | 6 |
| Actual1x1 / TAG1 | 1176 | 4704 | 4 |
| Actual5x4 / TAG8 | 1176 | 4704 | 4 |
| Actual256x256 / TAG32 | 1176 | 4704 | 4 |
| Total | **4064** | **16256** | **24** |

There are22 additional scored fixture results: twelve core reset-recovery
outputs and ten future-request outputs across five profiles. The future
fixtures held source valid through calculation and four held-output cycles,
checked that retirement cannot accept another token on the same edge, and
then checked the later handshake/result. Their40 held-output cycles and425
blocked-source cycles are separate from the table. Five initial resets plus
24 live resets give29 resets. Wrapper fixtures include114 pending management
offers,174 management responses and522 held-response cycles in aggregate.

Core results include RNE half ties, hidden RGB in transparent texels, extrema,
constant fields and deterministic random input. Each actual profile checks
two resident-load epochs, all13 legal composition modes, malformed mode and
destination, Q8 fractions, edge clamps, OOB where representable, metadata,
output holds and reset cancellation. Filtered samples never violated the
premultiplied bound. The passing TBs check69-cycle core output visibility,
89-cycle actual in-range visibility and73-cycle OOB visibility without stalls.

The maximum profile loaded all65,536 indices six times, each with256 palette
entries, but issued sparse query vectors. It did not render a complete frame,
measure sustained video throughput or establish physical RAM fit. At256x256
all representable unsigned Q8.8 bases are in range, so OOB is exercised by the
smaller profiles. Storage, DSP mapping, device frequency and power estimates
remain source-derived budgets, not measured hardware results.

Independent read-only audit matched19 current/archive source pairs, three
current/archive control pairs,24 tool/runtime bindings, thirteen vector and
preparation-receipt files, seventeen complete per-child JSON files,34 raw
streams and five original VVP images. Exact command argv/cwd/order, vector
header/row counts, preparation and simulation marker counters, image compile
and execute hashes, and `$finish` were checked. Hash/metadata mismatches:0.
The runner imported no oracle; the five isolated preparation children each
loaded the independent integer oracle definition once.

Core syntax/compilation stderr is empty. The actual wrapper syntax and three
actual compilations each report2172bytes of inherited Icarus notices about
`always_*` constant-select sensitivity in unchanged `rgba_porter_duff`.
Those notices expand sensitivity to full input words. All five simulation
stderr streams are empty; no functional assertion failed.

Baseline: `50b8d36a3ce65cae5c4b3ab4604fa24f3567204b`.
Frozen source seal: `fdd934310aeb4a3c036d47ac30a3d0fae7eb1e772fbb1aed16b76c344e6a5590`.
Frozen plan: `b6b7d127e2455192f3ed51e6bff27e54dd3c57ef7e99130417172da57326bf68`.
Root/peer proof: `26d2dbfb6a4a1b8a3be60a4b45c533675ce18d93d08db4e123efcc9760489f80`.

README, STATUS, manifest, RTL, model, TBs, runner, plan and seal retain their
executed bytes, including their pre-execution status wording. This new
delivery note and `QUALIFICATION.json` record the resulting finite evidence.
No synthesis, PnR, STA, SDF, board, inherited regression, combined repository
compile, physical video-rate test or PPA work was performed. Original images,
archives, process records and raw evidence are retained in place.
