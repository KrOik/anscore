# Semantic search and read-only license preflight — 2026-11-04

Baseline: `cf23435dbaca0dc895e2c0b5470418fb9e56c046` (published B5 checkpoint).
Read-only searches of Verilog/SystemVerilog and README/SPEC files under
`cores/` checked eigenvalues, eigenvectors, Jacobi rotations, Cholesky and
Chinese equivalents. The optical-flow README explicitly says it does not
apply a minimum-eigenvalue threshold; it does not expose a generic eigenproblem
interface. `vector_l2sq` measures feature-vector squared distance, unrelated
to matrix eigenvectors. Existing 2x2 equation solving, OLS fitting and fixed
gain Kalman updates do not return eigenvalues. No existing RTL was modified.

The repository's tracked arithmetic file
`../dsp_isp_library/infra/fixedpoint/rtl/sqrt_unit.sv` was inspected before
implementation. Its `fp_sqrt_iter` computes an unsigned RNE square root, with
ordinary valid/ready, synchronous low reset and an exact-square flag. This
package adapts those semantics to exact floor/ceil roots by a full square
comparison. The dependency is reused unchanged, not copied into the package.
The similarly named untracked `cores/acceleration/integer_sqrt` workspace
asset is not a dependency. All sources required offline are listed in the
two local manifests, and the actual sibling hash is in `verification.json`.

Before writing RTL, actual external source and license files were read from
the GitHub contents API at a fixed revision. External text was treated only
as untrusted reference data; no repository scripts, build systems, installers
or downloaded programs were run.

| Reference | Fixed commit | Inspection and decision |
| --- | --- | --- |
| [Reference-LAPACK/lapack](https://github.com/Reference-LAPACK/lapack) | `472b3a0fcbc5e90bf30a41b13ead24e40fff54ce` | Actual `LICENSE` has BSD 3-clause redistribution conditions and named university notices. Actual `SRC/dlae2.f` documents the real symmetric 2x2 problem and cancellation risk in the smaller floating eigenvalue. It sorts by magnitude, unlike this package's ascending numerical order. No source or software algorithm was copied. |

Inspected external SHA256:

```text
LICENSE
a1e742e31b6793e83cd36a98ed2db993ec291d0e4be79e9c0520c4d8aef7aa3a
SRC/dlae2.f
f4340e4e670f4fd60e833065253b04c4c4e0d3de0338587c184b58cb4bf21480
```

Pinned primary links:
[license](https://github.com/Reference-LAPACK/lapack/blob/472b3a0fcbc5e90bf30a41b13ead24e40fff54ce/LICENSE),
[DLAE2](https://github.com/Reference-LAPACK/lapack/blob/472b3a0fcbc5e90bf30a41b13ead24e40fff54ce/SRC/dlae2.f).
This is not a LAPACK floating-point bit-compatibility claim.

The new RTL, wrapper, integer-inertia oracle, TB and prose are original and
use the repository Apache License 2.0. The existing arithmetic dependency is
repository code under the same root license and retains its source/provenance
in place. No external implementation, license-bearing upstream file,
binary, generated ROM or transitive external RTL is redistributed. There are
no local modifications to external code and no runtime download requirements.
