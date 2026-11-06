# B44 finite qualification

Current evidence supports **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE /
HW_UNVERIFIED** for the exact reviewed source seal
`f460fccd57055e531e41ba8cbf2b5c7543af4ca5a9f2019d0c8396fd303255ec`.
The frozen README, STATUS and manifest retain their honest pre-execution state;
this separate record supplements those executed source bytes.

The sole authorized runner attempt used gate `B44_TETRAHEDRAL_ONCE_01` and
completed all four direct archived rational preparations, three Icarus syntax
checks and four compile/simulation pairs. Every child returned zero without
timeout or cleanup. All 30 raw stdout/stderr streams were fully captured.
No model was imported by the runner and no automatic retry occurred.

| Profile | Completed frames | Exact retired outputs | Early outputs | Reset cancellations |
|---|---:|---:|---:|---:|
| 1x1, BITS8, grid3, tag1 core |13|13|0|9|
| 5x3, BITS10, grid5, tag8 core |13|196|183|9|
| 9x4, BITS12, grid17, tag32 core |13|469|456|9|
| 7x3, BITS8, grid9, tag8 actual grayscale composition |14|295|281|10|

Outputs include the one valid prefix before the marker fault for multi-pixel
profiles. Each profile also checked held output/DONE/configuration responses,
two malformed early-last table loads, a malformed frame, unconfigured commands,
background inactive-bank loading, deferred table publication, a held future
command, and recovery after targeted reset phases. The actual composition also
reset an occupied grayscale output slot. These are finite targeted probes.

Default and maximum core syntax, plus maximum actual-wrapper syntax, passed.
The sole compiler warning class concerns the unchanged grayscale dependency's
missing explicit time unit/precision. All simulation stderr streams are empty.

The immutable receipt is
`reports/20261106T111352_539219Z/results.json`, SHA256
`7e69a312b8aa67c67b229f5fcd1448768d70e0f1d761c6d09623f386f28f76a6`.
Postcheck metadata hashing confirmed all 23 current/archived sealed inputs,
10 pinned tools/runtime files, 16 prepared files, 30 raw streams and four
original compiled images. The four images remain at their original ignored
`.build/20261106T111352_539219Z/` paths and are not source-delivery files.

No synthesis, PnR, STA, board or PPA evidence was produced. Illegal-FSM recovery
was source-reviewed; no fault was injected. The runtime pins do not constitute
a hermetic Windows, Python standard-library or complete compiler image.
