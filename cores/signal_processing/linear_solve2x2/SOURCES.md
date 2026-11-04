# Search, license and originality record — 2026-11-04

Baseline: `6d1af43` (the preceding four-channel stable batch). Local semantic
search of Verilog/SystemVerilog and README/SPEC files under `cores/`, plus
`docs/IP_INDEX.md`, found no public arbitrary signed-integer 2x2 linear solve
interface. The existing `stream_gf2_solve` works in GF(2), while fixed-gain
Kalman modules do not solve matrices at runtime. Optical-flow and affine
image packages perform specialized internal 2x2 arithmetic with their own
sampling, range and update semantics. The new core supplies a standalone
equation command, full-width exact determinant/numerators, two fixed-point
answers and explicit singular/saturation results. No existing RTL was changed.

Before writing RTL, a read-only GitHub repository search used
`q=matrix+inverse+verilog`. Repository metadata and a pinned source tree were
examined as untrusted reference data. No upstream scripts, installation
commands or build systems were run.

| Candidate/reference | Fixed commit | Inspection and decision |
| --- | --- | --- |
| [charmichokshi/verilog_code_inverse_matrix](https://github.com/charmichokshi/verilog_code_inverse_matrix) | `5ce76e3a45d9086e786d8ae9c227a16de1d2c462` | Metadata reports no declared license. The pinned tree contains `inverseMatrix.v`, `invertMatrix_tb.v` and README/images but no license file. Not imported. A later request to inspect the implementation failed with a transient SSL EOF; no implementation text was used. |
| [Reference-LAPACK/lapack](https://github.com/Reference-LAPACK/lapack) | `472b3a0fcbc5e90bf30a41b13ead24e40fff54ce` | `LICENSE` and `SRC/dgesv.f` were read successfully using the GitHub contents API. License has BSD 3-clause conditions and the named university copyright notices. DGESV provides a primary reference for arbitrary linear-system and singular-result semantics, using LU with pivoting rather than this core's exact 2x2 integer determinant method. No source copied. |

Other matrix-inverse search results (`himol7/Inverse-of-Matrix-Verilog`,
`jaymodi98/Matrix_Inverse_verilog`, `neel112358/Linear-Algebra-Project`,
`pratikpadalia/MatrixInverse`) also had no declared repository license in the
returned metadata and were excluded from import.

Pin-specific primary links:
[LAPACK license](https://github.com/Reference-LAPACK/lapack/blob/472b3a0fcbc5e90bf30a41b13ead24e40fff54ce/LICENSE),
[DGESV solver contract](https://github.com/Reference-LAPACK/lapack/blob/472b3a0fcbc5e90bf30a41b13ead24e40fff54ce/SRC/dgesv.f), and
[unlicensed candidate tree](https://github.com/charmichokshi/verilog_code_inverse_matrix/tree/5ce76e3a45d9086e786d8ae9c227a16de1d2c462).

All delivered RTL, example, test generator and prose are original and use the
repository Apache License 2.0. No external implementation, copyright-bearing
source file, generated artifact or arithmetic primitive is redistributed.
There are no local third-party modifications or transitive RTL dependencies.
Online reference availability is unnecessary for offline use of the core.
