# B9 semantic and external-source preflight - 2026-11-04

Baseline: `807d992b6b0e793c08ceba2d44993d21c1dd1583`.
These read-only checks and the numeric/architecture brief preceded new RTL.

Production RTL/README/SPEC searches covered isotonic, PAVA, pool adjacent
violators, monotone/monotonic regression and fit, weighted regression,
single-valued calibration, 保序 and 单调回归 terms. No equivalent ordered
weighted least-squares monotone projection service was found.

- `common_scaffold/image/raw_gamma` consumes a caller-supplied piecewise table
  and interpolates it, including nonmonotonic tables. It does not fit observations.
- `stream_linear_fit` fits one unconstrained straight line by OLS. It does not
  solve a piecewise constant inequality-constrained projection.
- Moments, chi-square, rank/sort, normalization, eigen and linear solvers have
  different mathematical outputs and cannot provide this service by an adapter.

The old `cores/acceleration/fraction_compare/rtl/fraction_compare.v` was
inspected as a possible unsigned rational-order primitive. `git ls-files`
returned no entry and `git status` identified it as preexisting untracked work.
The exact path was immediately reported to root. Root required preserving it
without promotion, dependency or copying. It is unchanged and excluded from
both manifests. The new package therefore implements only the necessary
signed-block comparison itself: ordinary LSB serial multiplication retains
two magnitude cross products using one shared adder. This is independent new
code tailored to this package's SUM_W/TOTAL_W bounds; the old Horner-difference
implementation, metadata, tests and reports are not copied or redistributed.
There is no tracked/untracked sibling RTL dependency.

## Actual fixed external inspection

[SciPy](https://github.com/scipy/scipy), tag v1.15.2, fixed commit
`0f1fd4a7268b813fa2b844ca6038e4dfdf90084a`.
The pinned directory listing identified `_pava/pava_pybind.cpp`. Actual complete
source and the full license were fetched via the GitHub contents API and read.

| File | Bytes | SHA256 |
| --- | ---: | --- |
| [LICENSE.txt](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/LICENSE.txt) | 1536 | `c29fb8e5936f33237a8b15256b4c6e93037f05bbf58c3d7b5755aede4c200173` |
| [scipy/optimize/_pava/pava_pybind.cpp](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/optimize/_pava/pava_pybind.cpp) | 5048 | `2e73ea5c6508307566d345818c3fdbf473df48101328b6a446a8f3e5580679ee` |

The BSD 3-clause license names Enthought/SciPy Developers, requires notices,
conditions and disclaimer, and restricts endorsement. The source implements
weighted PAVA on double arrays with look-ahead pooling and in-place expansion.
Its use of >= rather than > explicitly coalesces equal-valued output blocks;
this mathematical block convention was inspected. This RTL uses a conventional
serialized exact numerator/denominator stack instead of floating means,
look-ahead modification or software arrays. No implementation, comments,
tests, build files or upstream license text was copied or translated.

Each curl request had a 15-second bound; temporary downloads were removed.
External data was inspected only, and no upstream scripts, builds, installers
or executables ran. There is no external/runtime Python/SciPy dependency.
The Fraction max-min and partition-loss oracles are original local test code.
All new RTL, example, tests, runner and prose are original repository Apache-2.0
work, covered by root [LICENSE](../../../LICENSE) and [NOTICE](../../../NOTICE).
No third-party copyright-bearing implementation or license is redistributed.
