# B38 sources, provenance and semantic increment

Baseline `816d461b12fd402f6a146ca74c7491c7afbd3091`. New controller, QAM connection, TB, direct integer reference and metadata are original ANSCORE contributions under root Apache-2.0 `LICENSE` / `NOTICE`. New package bytes use `* -text` from their first write. Shared production sources are used unchanged.

| Original active path | Role | SHA-256 | Baseline/export distinction |
| --- | --- | --- | --- |
| `cores/acceleration/vector_l2sq/rtl/vector_l2sq.v` | One reused signed scalar-square multiplier; two components form each exact complex energy | `3610f3442969eb00048b47fb7198e344f479c6e9ce5b75aabc48a4a76d7c71d9` | Pre-existing workspace source, untracked at B38 baseline; B38 first includes only this exact RTL source and scoped `-text` attribute in the export/commit closure. The rest of its legacy package is not imported. |
| `cores/signal_processing/dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv` | Existing signed iterative RNE/saturating division, positive operands by explicit extension | `280d4aa40ca513befb76ef3dae03cf32e88b773c5cefcf526b8c9cfb89e1d3cb` | Tracked and already canonical; unchanged. |
| `cores/acceleration/operator_library/rtl/acc_comm_qam16_llr.v` | Actual 16-QAM nearest-point indices and diagnostics | `cdfb31c6f29f08c175080bd6b4f738784b533fa8064da7471edfba9a47410a49` | Tracked at the baseline, absent from B37 canonical source list; B38 adds its original path to the canonical source closure after baseline byte verification. No new alias or shared-source modification. |

These are original repository contributions under Apache-2.0/NOTICE, with no third-party implementation notice. Their current combination has only the finite evidence explicitly reported by this package. Historical helper simulation, synthesis, routing or board claims are not inherited. Active files use their original paths; executed-input archives are evidence copies and add no active duplicate module definitions. No external RTL, vendor primitive, downloaded ROM or generator is required. An independent post-run `git cat-file blob` read of immutable baseline QAM bytes yielded the same SHA-256 above as the current and archived source.

The first approved finite attempt passed all10 children and four simulations, with no retry or historical HDL failure. Receipt `reports/20261106T051041_639726Z/results.json`, SHA-256 `f6826f45014118b84a027ca32b2db201c480ff8b6c9a160a78856a032e41f284`, binds all12 exact executable inputs, four archived vector sets and twenty raw stdout/stderr streams. Source archiving preceded all four numerical preparations. Independent post-run hashes verified current/archive sources, vectors, raw streams, two tools, four VVP images and the plan sequence. The support sources remained unchanged throughout.

The distance engine supports D+1 signed difference for both signed-D extrema and retains unsigned2D per-scalar squares. With two components, ACC_W=2D+1 covers the full complex error. Its synchronous active-high reset and ordinary handshake connect directly. The divider has synchronous active-low reset, explicitly adapted. The QAM atom has CE-qualified transfers and asynchronous active-low reset: constant CE1 and a registered reset bridge adapt these semantics; original I/Q and LAST remain owned by one metadata slot.

## Semantic comparison

The suggested Gardner direction was rejected after reading the existing actual implementation: `dsp_isp_library/dsp/recovery/rtl/timing_loop.sv` already supplies sign(diff)*mid Gardner TED, PI and symbol-phase feedback, with SPS4/8, BPSK real inputs and strobe outputs. `dsp/farrow`, rational polyphase resamplers and the dual-clock ASRC already provide interpolation/rate-conversion services. Changing to SPS2 or adding backpressure would not justify a new capability package.

Relevant existing computation was reused rather than relabeled:

- `vector_l2sq` returns one scalar-vector sum of paired squared differences; it has no paired complex frame energy normalization, per-symbol peak position or final EVM ratio.
- `dsp/statistics` measures a single real stream's power/RMS/peak, with no aligned complex reference/error measurement.
- `comm_qam16_llr` supplies LLRs, hard decisions, nearest indices and a per-symbol Manhattan-distance diagnostic; it has no exact Euclidean frame error/reference energies or EVM measurement.
- `block_vector_normalize` emits unit-vector components through a staged root/division contract; it does not measure received/reference symbol error.
- `paired_spectral_coherence` measures cross-spectral coherence over independent segments, and `repeated_half_sync` detects adjacent time-domain repetition; neither defines aligned symbol-reference EVM.

The new capability is a bounded, exact paired complex symbol-quality measurement service and a real demapper-to-measurement connection, including frame ownership, normalization, earliest peak and explicit invalid/reference-zero semantics.

## Fixed official upstream read-only references

GNU Radio **v3.10.12.0**, tag object `522b220f24cbf0df9789a2d8eff57ee3d3f58f52`, commit **`ec7a3239645162ffea1925e6f1e6e62bf1349d03`**. Official GitHub tree and raw source text were inspected over HTTPS after the web tool returned HTTP500. No external source was saved, copied, translated into RTL or executed.

| Official file | Read-only purpose | UTF-8 source SHA-256 |
| --- | --- | --- |
| [`gr-digital/lib/meas_evm_cc_impl.cc`](https://github.com/gnuradio/gnuradio/blob/ec7a3239645162ffea1925e6f1e6e62bf1349d03/gr-digital/lib/meas_evm_cc_impl.cc) | Decision-reference complex error, average constellation-power normalization and scope comparison | `fa8375ced299515ed51fe336ffcaeb57261727d1c0073622f2e704f3ef2a52fe` |
| [`gr-digital/include/gnuradio/digital/meas_evm_cc.h`](https://github.com/gnuradio/gnuradio/blob/ec7a3239645162ffea1925e6f1e6e62bf1349d03/gr-digital/include/gnuradio/digital/meas_evm_cc.h) | Public percent/dB EVM API distinction | `e7e38ffc2cc769a74fc6c06658dec86c641974792ec5d843ba4b47c700e5b2b0` |
| [`gr-digital/lib/timing_error_detector.cc`](https://github.com/gnuradio/gnuradio/blob/ec7a3239645162ffea1925e6f1e6e62bf1349d03/gr-digital/lib/timing_error_detector.cc) | Gardner full-product real/complex relation; compared to existing local sign(diff) approximation | `052d90954f7ca2e39a04fccffd95c5d763c355ed89764f6a58235ae6c57c8af9` |
| [`gr-channels/python/channels/iqbal_gen.py`](https://github.com/gnuradio/gnuradio/blob/ec7a3239645162ffea1925e6f1e6e62bf1349d03/gr-channels/python/channels/iqbal_gen.py) | Alternative IQ impairment candidate's model boundaries only | `7f50434c3328cb29890fd02236f9954c743759ca9fe4a9aa3387f6790b09c05b` |
| [`COPYING`](https://github.com/gnuradio/gnuradio/blob/ec7a3239645162ffea1925e6f1e6e62bf1349d03/COPYING) | GNU GPLv3 license text | `8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903` |

EVM implementation/header and timing source identify **GPL-3.0-or-later**. They provide mathematical/context references only. The independent local statistic is `sum(error_energy)/sum(actual_reference_energy)` over one finite frame; GNU Radio's inspected block emits per-symbol percent/dB using average constellation energy. This package makes no claim to implement that GNU Radio block or a radio measurement standard. The alternative IQ candidate is not part of the implementation.

The bounded runner's process-timeout/kill/atomic-receipt pattern is reused from the original Apache-2.0 B37 finite runner. Numerical preparation and HDL run sequence are specific to this package, with no automatic execution at import.
