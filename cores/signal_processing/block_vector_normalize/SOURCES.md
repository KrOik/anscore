# Source preflight and semantic audit — 2026-11-04

Baseline: `f19addd5fec59ec6affee05af7195ca1758d40dc` (published B6 checkpoint).
Read-only RTL and README/SPEC searches under `cores/` checked vector/unit/L2
normalization and Chinese equivalents. Existing AGC tracks leaky absolute
level and a log-gain loop; existing amplitude statistics emits RMS rather
than rescaled vector components. HOG uses a specialized L1 block descriptor,
and CORDIC vectoring returns an uncompensated gain-scaled norm/angle. These
are not a bounded general signed-vector-to-L2-normalized stream interface.
No existing assets were changed.

The tracked `sqrt_unit.sv` and `recip_div.sv` under
`../dsp_isp_library/infra/fixedpoint/rtl/` were inspected for parameter domains,
RNE semantics, output flags, synchronous-low reset and ordinary ready/valid.
Both are reused unchanged through named iterative instances. Exact paths and
SHA256 are bound by `verification.json`, and both local manifests include them.
There are no untracked, include, package, ROM, vendor or generator dependencies.

Before implementation, actual pinned external files were read through the
GitHub contents API. External text was reference data only; no remote scripts,
installers, build systems or downloaded executables were run. An initial
`BLAS/SRC/dnrm2.f` request returned not-found; the pinned directory listing
identified the actual `dnrm2.f90`, which was then retrieved and read.

| Reference | Fixed commit | Inspection and decision |
| --- | --- | --- |
| [Reference-LAPACK/lapack](https://github.com/Reference-LAPACK/lapack) | `472b3a0fcbc5e90bf30a41b13ead24e40fff54ce` | Actual `LICENSE` has BSD 3-clause conditions and named university notices. `BLAS/SRC/dnrm2.f90` defines Euclidean norm and uses safe floating scaling; `BLAS/SRC/dscal.f` scales a vector by a scalar. They support the norm/scale capability distinction, not this package's integer staged-rounding contract. No source or software implementation was copied. |

Inspected external SHA256:

```text
LICENSE
a1e742e31b6793e83cd36a98ed2db993ec291d0e4be79e9c0520c4d8aef7aa3a
BLAS/SRC/dnrm2.f90
40392a1d1ae40c821bf386cb5118b36a20518ca5b37c98b1d3d6c76fdf5beb71
BLAS/SRC/dscal.f
004c0bf71dc9c29f6e681330bf23d021e38f83b3752f9b71ef70a13ddb851886
```

Pinned primary links:
[license](https://github.com/Reference-LAPACK/lapack/blob/472b3a0fcbc5e90bf30a41b13ead24e40fff54ce/LICENSE),
[DNRM2](https://github.com/Reference-LAPACK/lapack/blob/472b3a0fcbc5e90bf30a41b13ead24e40fff54ce/BLAS/SRC/dnrm2.f90),
[DSCAL](https://github.com/Reference-LAPACK/lapack/blob/472b3a0fcbc5e90bf30a41b13ead24e40fff54ce/BLAS/SRC/dscal.f).

New RTL, wrapper, tests, oracle and prose are original repository Apache-2.0
contributions. Both existing arithmetic sources remain under the root
LICENSE/NOTICE and retain their own library provenance in place. No external
copyright-bearing implementation or license file is redistributed, no local
upstream modifications exist, and offline use needs no online source retrieval.
