# B19 semantic preflight and fixed reference inspection

Baseline actual HEAD: `897cf84f5861f5fada3c1a5d64127e64cdb9af92`.

An initial isotonic-regression candidate was rejected after actual tracked and
untracked production searches found the complete `weighted_isotonic` package.
No file was created for that candidate. The selected NNLS2 capability was then
searched across all cores (including ignored/untracked RTL/README content) for
NNLS, nonnegative/non-negative least squares, constrained least squares,
active-set and 非负最小二乘. No equivalent service was found. Actual
`stream_linear_fit` and `linear_solve2x2` RTL/contracts plus the
`weighted_isotonic` contract were read. They provide unconstrained fixed-
intercept regression, arbitrary square equation solving with output quantization,
and order-constrained vector fitting, respectively. None implements arbitrary
two-column nonnegative least squares from raw sample rows. No old package is
modified, copied or instantiated.

## Actual fixed upstream source and full license read before RTL

Repository: <https://github.com/scipy/scipy>

Commit: `0f1fd4a7268b813fa2b844ca6038e4dfdf90084a`.

| Complete file inspected read-only | Bytes | Git blob | SHA256 |
| --- | ---: | --- | --- |
| [scipy/optimize/_nnls.py](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/optimize/_nnls.py) |3233| `be904c90d715583faaf7751ce62b9c992e07e208` | `b5dd05380bd42027944c6ad7a8599d57a5171a2fc2cb43eb1bc850be20eca9ee` |
| [scipy/optimize/_cython_nnls.pyx](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/optimize/_cython_nnls.pyx) |7495| `53bfb82adf9538b4905b2d2bfb3c7ddf0a8a14d1` | `eaa84be52696f2ba5b87295ee56895b7e89bb31e0e83378c43a628de7d1a47cd` |
| [LICENSE.txt](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/LICENSE.txt) |1536| `117117616e806a9bb960b1f32a552c8c912b0497` | `c29fb8e5936f33237a8b15256b4c6e93037f05bbf58c3d7b5755aede4c200173` |

All three complete files were fetched via read-only fixed-ref GitHub contents
API with 15-second network limits, strictly UTF8 decoded and read before local
RTL. The complete BSD-3-Clause license names 2001-2002 Enthought, Inc. and
2003-2024 SciPy Developers. Related source imports QR/Householder/Givens LAPACK
and BLAS helpers, uses floating arrays and generic active-set iteration,
tests numerical independence, and returns a residual norm or iteration failure.
The local bounded RTL instead specializes exact integer Gram/KKT conditions for
two variables, rejects exact rank deficiency as its service contract, returns
rational coordinates, and contains no numerical tolerance or upstream API claim.

This is mathematical/reference inspection only. No external source, comment,
test, license text or build dependency was copied, adapted, persisted, imported,
installed or executed. Local RTL, wrapper, testbench, Gaussian/KKT oracle,
fixtures and prose are original Apache-2.0 repository work under the unchanged
root LICENSE/NOTICE. Untrusted remote source text was not treated as instructions.

## Local offline closure

`.gitattributes` was the first local file created. All package files use LF.
`files.f` names only `rtl/nonnegative_least_squares2.sv`; `example/files.f` adds
only the local default `nonnegative_fit16` wrapper. Production needs no external
arithmetic, includes, memory initialization, generated assets, vendor primitives,
untracked sibling files, network or host runtime. Optional tests need only
standard-library Python and the existing native Icarus/vvp tools. The frozen
generator and exact fixture bytes are included for offline reproducibility.
