# Source and capability audit — 2026-11-04

Development baseline: e711afc. Local searches covered RTL and package
README/SPEC files plus the IP index, using iir_lattice/lattice_iir/allpole/
all-pole/lattice-filter/lattice-synthesis terms. The preceding Levinson-Durbin
package mentioned lattice filters as a consumer but did not implement one.
Existing direct FIR, adaptive LMS and biquad/SOS cores were considered; their
architectures do not supply this descending reflection-stage synthesis model
and runtime bank/retained-history contract. The LPC analysis/synthesis example
combines the preceding estimator with this new arithmetic core. No old RTL
or historical validation evidence was changed.

Predevelopment read-only reference:

- Repository: [ARM-software/CMSIS-DSP](https://github.com/ARM-software/CMSIS-DSP)
- Fixed commit: `dce4b4f1db66fc794d91b8a703bcbd3b35ea8e30`
- Inspected implementation: [Source/FilteringFunctions/arm_iir_lattice_q31.c](https://github.com/ARM-software/CMSIS-DSP/blob/dce4b4f1db66fc794d91b8a703bcbd3b35ea8e30/Source/FilteringFunctions/arm_iir_lattice_q31.c)
- Actual inspected license: [LICENSE](https://github.com/ARM-software/CMSIS-DSP/blob/dce4b4f1db66fc794d91b8a703bcbd3b35ea8e30/LICENSE), Apache License 2.0.
- The inspected source identifies copyright 2010-2021 ARM Limited or its
  affiliates and SPDX Apache-2.0.

The source and actual license text were retrieved via GitHub contents API
before RTL drafting. It was used for comparison of the general all-pole
lattice interpretation. Its Q31 software filter includes a ladder/output
accumulation and different rounding/overflow behavior. This RTL independently
defines its state saturation, toward-zero products, coefficient order,
serialized arithmetic, ready/valid behavior and model transactions. There is
no bit-equivalence claim against the CMSIS function and no software text
copied, translated or executed. An initial terminal print of a UTF-8 BOM
failed under GBK; a UTF-8-sig read then exposed the source successfully.

All delivered RTL, examples, deterministic reference/test code and documentation
are original under the repository Apache License 2.0. No upstream source file,
license-bearing implementation, generated data, primitive or transitive
third-party dependency is redistributed. API/source text was treated as
untrusted reference data. No remote build/install scripts were run.

The optional composition explicitly depends on the repository's original
`../levinson_durbin/rtl/levinson_durbin.sv`, through integration.f. Its actual
source hash is captured separately in verification.json; it is not copied
into this package or required by the standalone filter.
