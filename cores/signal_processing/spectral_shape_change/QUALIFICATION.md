# Spectral shape change qualification

Status: **FINITE_FUNCTIONAL_SIMULATION_PASS**. Hardware status: **HW_UNVERIFIED**.

This additive record qualifies the retained followup01 attempt against baseline `3a58c99bda6f6f62a34d1c20247d3b42d8d89006`. The sealed source, original controls, failed attempt, preparation receipts, raw streams and compiled images remain unchanged. Authoring-time pending fields in sealed README/manifest inputs are historical; this file and `QUALIFICATION.json` record the later result.

## Qualified behavior

The core computes exact adjacent normalized power-spectrum total variation from unsigned 32-bit power bins. With `A=sum(P)`, `B=sum(Q)`, `U=sum(max(P[k]*B-Q[k]*A,0))` and `D=A*B`, it returns the exact raw fraction `U/D` and Q16 `RNE(65536*U/D)`, with one final ties-to-even rounding. It supports 1 to 256 bins and tag widths 1 to 32. The reference frame commits only when the summary actually retires. Valid zero frames commit; a damaged accepted frame invalidates history; invalid configuration preserves history.

The actual IQ example composes the unchanged `mag_squared` dependency with matching sidebands and in-flight admission control. The implementation also reuses the unchanged canonical synchronous RAM, serial multiplier and integer divider.

## Immutable attempt chain

The original attempt at `reports/20261106T165359661187Z/results.json` is **FAIL_STOP**, SHA256 `423cb711114ed50f1a6a8c9997db899e5dd1ca609bfa79381db5abe84528a17c`. Four model preparations and three production/example syntax checks passed. The first testbench compilation failed with exit code 10 because `bins` is a SystemVerilog reserved keyword; no original simulation ran. All original evidence is retained.

The independent followup01 changed exactly five whole-token testbench occurrences from `bins` to `command_bins`. No production RTL, model, canonical dependency, fixture or expectation changed. It reused the four original vectors and preparation receipts, with no model preparation calls.

The followup receipt at `followup01/reports/20261106T170639328818Z/results.json` is **PASS**, SHA256 `238450695048830a3395a69ad14e99e24f0adae437fd1d69ab9a49f61b8d1975`. Its eight sequential children comprise four compiles and four simulations, all exit zero with complete raw capture. The attempt retained all four compiled images and separate immutable initial, terminal and validated child records. Before each simulation launch, the initial record binds the just-rehashed image SHA256 and explicit prechecked flag. There was no retry or cleanup, and no active child or helper remains.

Across both attempts, 16 children started: 15 passed and the one historical testbench compile failed.

## Observed finite results

| Profile | Fixture cases | Summaries checked | Held observations | Resets | Cancellations | Arithmetic-fault recoveries | Continuous observations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| core_min | 25 | 53 | 265 | 9 | 8 | 1 | 0 |
| core_odd | 49 | 77 | 385 | 9 | 8 | 1 | 284 |
| core_max | 49 | 77 | 385 | 9 | 8 | 1 | 9790 |
| iq64 | 41 | 69 | 345 | 9 | 8 | 1 | 2435 |
| Total | 164 | 276 | 1380 | 36 | 32 | 4 | 12509 |

These are observations from the retained finite simulations, including the actual IQ composition. They establish the tested numerical, framing, stall, reset, cancellation and error-recovery behavior within these profiles.

## Frozen controls and independent audits

- Followup plan: `2fb9f343ac91ed66d60f892b8a39382c8c8d76c0c5e902385c842969b0ecc348`.
- Followup source seal: `60f1b3ba640dd96af0bf74f879c7cf9c920342709c0f02b24baff5b9dab6b9e5`.
- Followup source review: `22093e2a9ae8007acedad5cee671f48ea9ba09c1f4b4e2a2b8a016af0320399b`.
- Followup runner: `cc60f63168afef6682e5f426d8e8f6c58e281cdbbb1de1d58c4e855f17ac9024`.
- Author audit: `followup01/POST_AUTHOR_AUDIT.json`, SHA256 `96a4279f2d3a7e90c23e8c606055dbd40367af23406bacd9ed57eee11e72f829`, **PASS_NO_DISCREPANCY**, 256 file checks.
- Independent peer audit: `followup01/POST_PEER_AUDIT.json`, SHA256 `3f4c8c6ecca2f54a363682087c35c29c456e2ea77cb027574ec05eba179657cf`, **PASS_NO_DISCREPANCY**, 365 file checks.

The audits checked the original and followup evidence chain, frozen source and archived copies, tool pins, raw streams, child records, controls and image bindings without a qualification rerun.

## Evidence boundary

No synthesis, placement and routing, static timing analysis, board validation, PPA measurement or inherited-core regression was performed for this qualification. No device timing, area, power or physical implementation claim follows from the functional simulation pass. The gate `B48_SPECTRAL_SHAPE_CHANGE_FOLLOWUP01_ONCE_01` is consumed; retained evidence is the record of that attempt.
