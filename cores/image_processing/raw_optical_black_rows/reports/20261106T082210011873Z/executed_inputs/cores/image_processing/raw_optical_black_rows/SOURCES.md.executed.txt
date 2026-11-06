# Offline source closure and provenance

Baseline is `2e7a6fb51f32e525c1026c28d1f2f45e36545ebc`. All RTL dependencies are resident:

| File | Role | Origin |
| --- | --- | --- |
| rtl/raw_optical_black_rows.sv | Per-row parity estimator and active crop | New independent Apache-2.0 RTL |
| example/raw_ob_black_frontend.sv | Row configuration and drained old-correction ownership | New independent Apache-2.0 RTL |
| ../isp_stream/rtl/raw_black_level_stream.v | Actual subtract/target/clamp instance | Unchanged resident Apache-2.0 package asset |

`files.f` closes the estimator and `example/files.f` closes the actual frontend; both are interpreted from this package root. There are no hidden includes, generated RTL, external RAMs, ROMs, coefficients, firmware or network dependencies. The active row RAM is filled by runtime sensor input. Simulation vectors are produced once by the local reviewed oracle and archived before HDL; they are not hardcoded hardware outputs.

Semantic dedup inspected canonical, common-scaffold and operator-library implementations. `common_scaffold/image/raw_black_level/raw_black_level.sv` buffers a frame and derives one global ROI mean per four Bayer planes; it does not estimate individual row margins or crop active pixels. `../isp_stream/rtl/raw_black_level_stream.v` supplies the retained manual correction primitive without estimation. HDR merge, EWMA/median/MOG3 background modeling and frame difference were rejected as already represented capabilities. No implemented same-row parity-separated OB estimator/crop was found.

External read-only comparison: official repository https://github.com/LibRaw/LibRaw at fixed release0.21.2. The exact `src/decoders/canon_600.cpp`, COPYRIGHT and full LICENSE.CDDL were inspected from the fixed-tag upstream-content mirror `https://cdn.jsdelivr.net/gh/LibRaw/LibRaw@0.21.2/` after official raw/API requests failed. The decoder contains black subtraction/clamp and row/column parity gain handling; it does **not** implement this package's per-row optical-black estimator and no bit-exact decoder equivalence is claimed.

COPYRIGHT states LibRaw LLC2008–2021 and dcraw/Dave Coffin1997–2018, dual LGPL2.1/CDDL1.0. Full CDDL1.0 was read. LGPL file requests failed, so its full text is not claimed inspected. Exact inspected byte lengths and SHA256 values appear in references.json. No external source was copied, translated, saved into the package, imported, compiled or executed. The reference introduces no runtime dependency or license inheritance into independently authored RTL.

New local files use the repository Apache-2.0 license text copied to LICENSE. The existing correction retains its original provenance and is not edited. Frozen reports archive exact checked dependency bytes; any Git clean normalization of this old dependency is recorded separately from raw SHA256 at delivery rather than silently rewriting execution evidence.
