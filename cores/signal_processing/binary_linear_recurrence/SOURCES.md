# B14 semantic and actual fixed-source preflight - 2026-11-04

Baseline `01b92bf2f8d81fff097f1965de61edf81604ae4f` (published B13).
Before RTL, production RTL/README/SPEC searches for Berlekamp, Massey,
linear complexity and Chinese shortest-recurrence terms found no inference
service among the52 current numerical/graph packages. Actual nearby files
were read: system extended-library `lfsr_prng.v` and SPEC provide seeded
fixed32-bit Galois generation and scrambling; operator-library
`acc_lfsr_galois_keystream.v` and its per-IP SPEC use supplied seed and
fixed `80200003` taps; `ips_scr_descrambler.v` and README use fixed/supplied
43-bit taps. None infers minimal recurrences from raw observations. An initial
generic operator-library SPEC path was missing; the actual per-IP SPEC was
then read. No existing implementation is edited or used as a dependency.

## Actual source and complete license inspected before RTL

[mhostetter/galois](https://github.com/mhostetter/galois), v0.4.6 annotated
tag object `63a131839d3c7a873b75f24d4cff91266d6314d1`, peeled fixed commit
`d275dfc2b784166fbb9e645510b8941430a679d3`. Read-only GitHub contents API
requests had15-second HTTPS limits. Complete base64 content was decoded
as strict UTF-8. AST parsing extracted actual definitions without execution.

| File | Git blob | Bytes | SHA256 |
| --- | --- | ---: | --- |
| [LICENSE](https://github.com/mhostetter/galois/blob/d275dfc2b784166fbb9e645510b8941430a679d3/LICENSE) | `504d6eca0f31d84ff3e973b348aa1d4a86977029` |1089| `f2f435b2d3447d8e4c2a49dd8f0e8e75414acbbd23d0bb29d3c5c2be8a97f878` |
| [src/galois/_lfsr.py](https://github.com/mhostetter/galois/blob/d275dfc2b784166fbb9e645510b8941430a679d3/src/galois/_lfsr.py) | `8fdb461a4b122e2338a176e3d292992d716df84f` |52381| `47d1d774e21d40164a6c50b0d76d648e957775891e22f1a67022e2bd4178dedd` |

The complete MIT license names copyright2020-2025 Matt Hostetter. Its full
permission, copyright/permission retention condition and warranty/liability
disclaimer were read. Actual complete `berlekamp_massey` lines1425-1517 and
`berlekamp_massey_jit` lines1520-1578 were inspected. They perform general
finite-field discrepancy calculation, polynomial correction and order update,
then expose characteristic coefficients. Local GF(2) arithmetic needs XOR
without inversion or division. The local shifted auxiliary is a scheduling
choice; the independent oracle solves increasing-order linear systems.

Upstream array length N, characteristic/coefficient orientation, generalized
field dtype/API and finite-prefix presentation differ from this inclusive
MAX_BITS+1 lag-vector contract. No API, dtype, bitwise polynomial or
characteristic-vector compatibility is claimed. In particular local recurrence
order is allowed to exceed the degree of its lag polynomial, and nonunique
shortest solutions are explicit.

No upstream implementation, source, comments, tests, license text or build
code was copied, adapted, translated, persisted, imported or executed.
Retrieved bytes were read-only reference text. New RTL, wrapper, independent
linear-system oracle, TB, runner and prose are original repository Apache-2.0
work under root [LICENSE](../../../LICENSE) and [NOTICE](../../../NOTICE).
Both manifests close locally and dependency lists are empty. Offline use
requires no galois, network, sibling/untracked RTL, generated table, vendor
primitive, external memory or remote build.
