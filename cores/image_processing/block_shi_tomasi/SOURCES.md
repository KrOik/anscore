# Semantic review and read-only source/license preflight

Baseline: `99b5c8c1b3530775bb9dca0e5b4d1df07a014f68` (published seventh batch).
Only this new package directory is written. Existing assets, shared indexes
and stable references are untouched. The RTL, wrapper, TB, independent oracle
and prose are original work under the repository Apache License 2.0.

Read-only semantic searches covered structure tensors, minimum eigenvalue
corner scores, Shi-Tomasi, Harris, FAST, optical flow and tensor terminology.
No generic gradient-block minimum-eigenvalue scorer was found. The existing
`common_scaffold/image/optical_flow/README.md` explicitly describes a determinant
threshold rather than a minimum-eigenvalue threshold. FAST/Harris, OLS fitting
and the arbitrary symmetric eigenvalue command have different input/output
capabilities. This package composes the latter with exact streamed tensor
accumulation and block rejection/threshold semantics, rather than copying it.

The tracked dependencies were inspected and are reused unchanged:

| Dependency relative to this package | Role |
|---|---|
| `../../signal_processing/symmetric_eigen2x2/rtl/symmetric_eigen2x2.sv` | Exact signed eigenvalue floor/saturation, trace, PSD and repetition flags |
| `../../signal_processing/dsp_isp_library/infra/fixedpoint/rtl/sqrt_unit.sv` | The eigen solver's unsigned iterative RNE root and exact-square flag |

Both offline manifests list the full closure. The runner records exact sibling
SHA256 values; final packaging also compares those bytes with the committed
baseline blobs. Dependencies retain their existing source/provenance and root
license in place. No untracked similarly named arithmetic candidate is used.

Before implementation, actual source and full license files were retrieved
read-only through GitHub's contents API at the immutable scikit-image v0.24.0
commit `a160f384523ac70173d069954b7084bee79fb68e`. External text was treated as
reference data. No upstream scripts, installers, build system or program ran.

| Inspected file | Git blob | SHA256 |
|---|---|---|
| [skimage/feature/corner.py](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/skimage/feature/corner.py) | `3fbb64e706b2dc1ae7dc337a4e15cd7091c4686f` | `2cfa8b0b92ab7854a371323cb21d74769c8cdf1dc522e5523b5dc89a8411c0bd` |
| [LICENSE.txt](https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/LICENSE.txt) | `dc6a0f0db801d80daa92cd19ee0b63bf77bed047` | `51f15344f59759ed5d8ddb6dad48e8b994bdd45b050a80fe58a419bd0f98aed0` |

The actual license's general `Files: *` entry is BSD-3-Clause, copyright
2009-2022 the scikit-image team. `corner.py` has no differing file exception.
The inspected `corner_shi_tomasi` forms a structure tensor and computes the
smaller eigenvalue, with Gaussian neighborhood averaging in upstream code.
The local RTL independently computes an exact uniform integer block sum and
uses the committed hardware solver. It does not claim upstream Gaussian
filtering, floating-point behavior, raster API or bit compatibility.

No upstream source file, executable, generated data or license-bearing source
fragment is copied or redistributed. There is no external runtime download or
transitive external RTL dependency. The fixed external reference is conceptual
provenance, not an imported implementation. No external source was modified.
