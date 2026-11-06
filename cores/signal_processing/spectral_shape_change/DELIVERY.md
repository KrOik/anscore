# Spectral shape change delivery

Delivered package: `cores/signal_processing/spectral_shape_change`.

The package contains the original Apache-2.0 streaming total-variation RTL, exact independent reference model, finite testbench, documented interface/architecture, dependency file lists and actual IQ-to-power composition example. `QUALIFICATION.json` and `QUALIFICATION.md` record **FINITE_FUNCTIONAL_SIMULATION_PASS** with **HW_UNVERIFIED**.

## Entry points

- `rtl/spectral_shape_change.sv`: exact adjacent normalized power-spectrum change core.
- `example/iq_spectral_shape_change.sv`: actual composition through the unchanged canonical `mag_squared` block.
- `files.f` and `example/files.f`: dependency lists.
- `README.md`, `ARCHITECTURE.md`, `SOURCES.md` and `TEST_PLAN.md`: sealed authoring-time contracts and source provenance.
- `reference_model.py`: original independent arithmetic and fixture generation model.
- `QUALIFICATION.json` and `QUALIFICATION.md`: additive final qualification and limitations.

## Retained verification evidence

The original failed attempt remains at `reports/20261106T165359661187Z/`. It records four successful preparations, three successful production/example syntax checks and the reserved-keyword testbench compilation failure. It must remain part of the delivered chain.

The independently reviewed `followup01/` contains the exact five-token testbench rename, frozen finite plan/source seal/source review and separate run-once guard. Its attempt at `followup01/reports/20261106T170639328818Z/` passed four compiles and four simulations using the original vectors. It retains complete raw streams, immutable prelaunch records, terminal records, validated records, archived executed inputs and original evidence. Retained compiled images are under `followup01/.work/20261106T170639328818Z/`.

The followup PASS receipt is SHA256 `238450695048830a3395a69ad14e99e24f0adae437fd1d69ab9a49f61b8d1975`. Author and independent peer post-execution audits are `followup01/POST_AUTHOR_AUDIT.json` and `followup01/POST_PEER_AUDIT.json`; both report **PASS_NO_DISCREPANCY**. The complete machine-readable control hashes and observed profile counters are in `QUALIFICATION.json`.

The tested finite corpus covers 164 fixture cases and 276 checked summaries, including 1380 held observations, 36 resets, 32 cancellations and four arithmetic-fault recoveries. No production RTL, model, canonical dependency or expectation was changed for the followup.

## Integration boundary

The unchanged canonical dependencies are `cip_sync_sp_ram.v`, `img_hist_serial_multiply.v`, `integer_divider.v` and, for the example, `mag_squared.sv`; their repository paths and sealed hashes are recorded in the plans and source seals. The IQ wrapper's sideband/in-flight gating is part of the delivered example.

The retained pass covers the finite functional profiles. Hardware, synthesis, placement and routing, static timing, board behavior, PPA and inherited-core regression remain unverified. All execution gates in this chain are consumed; a new execution requires a separately reviewed finite plan and fresh gate rather than alteration or reuse of the retained attempts.
