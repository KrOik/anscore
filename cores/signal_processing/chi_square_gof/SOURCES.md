# B8 semantic, source and license preflight

Date: 2026-11-04. Baseline:
`99b5c8c1b3530775bb9dca0e5b4d1df07a014f68`.
This preflight and numerical/architecture brief preceded RTL implementation.

Production README/SPEC/RTL searches covered `chi.square`, `chi_squared`,
`chisquare`, `chi2`, Pearson statistic, goodness of fit, 卡方 and 拟合优度.
No equivalent service was found. Wider statistical/transform searches checked
moments, statistics, entropy, covariance, matrix decompositions and transforms.

- `stream_integer_moments` returns exact count/sum/squares/extrema; it does
  not accept expected frequencies or form sum((O-E)^2/E).
- `stream_cross_moments` returns bivariate raw moments. Its sufficient sums
  cannot supply category-dependent denominators for Pearson statistics.
- `dsp_isp_library/dsp/statistics` supplies amplitude/RMS statistics.
- `common_scaffold/image/entropy_filter` computes local gray-level Shannon
  entropy. Its entropy ROM/window schedule does not implement this statistic.
- Existing solver, OLS, Levinson, lattice, eigen and vector-normalization
  services have different numerical contracts and are not duplicated here.

The existing tracked `fp_div_iter` already provides the required nearest-even
division. Its complete file `../dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv`
is used without copying or editing. The other module in that file,
`fp_div_pipe`, is not instantiated. Source is unchanged from the baseline;
current dependency SHA256 is recorded in verification. Both manifests include
this one dependency. Its existing root Apache-2.0 LICENSE/NOTICE provenance is
retained in place. No untracked support source is needed.

## Fixed external read-only reference

[SciPy](https://github.com/scipy/scipy), tag v1.15.2, resolved via GitHub API to
fixed commit `0f1fd4a7268b813fa2b844ca6038e4dfdf90084a`.

| Inspected file | Bytes | SHA256 |
| --- | ---: | --- |
| [LICENSE.txt](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/LICENSE.txt) | 1536 | `c29fb8e5936f33237a8b15256b4c6e93037f05bbf58c3d7b5755aede4c200173` |
| [scipy/stats/_stats_py.py](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/stats/_stats_py.py) | 417517 | `01b665feba503fd53684d00ca6f322550fa41d414e09da482ab97f48d64b8a5b` |

The complete BSD 3-clause license was actually read. It names Enthought and
SciPy Developers, requires notices/conditions/disclaimer and restricts name
endorsement. The actual `_power_divergence` and `chisquare` function bodies
were read at that fixed commit: Pearson terms are squared observed/expected
differences divided by expectation, then summed; the common-mass sum check,
df adjustment and separate p-value computation were inspected.

This RTL selects integer common-mass inputs, excludes 0/0 categories, rejects
positive/0 and active<2, and returns only a quantized statistic with uncorrected
df metadata. It does not reproduce SciPy's floating tolerance, p-value,
broadcasting, alternative divergence families or ddof parameter.

Every network curl call had a 15-second bound. The raw source request timed
out; the pinned GitHub contents API then supplied the full actual source.
Temporary downloads were deleted. External source was parsed as text/AST for
inspection only; no upstream scripts, installers, builds or implementation
were executed, copied, translated or included. No external copyright-bearing
implementation or license is redistributed. New RTL, wrapper, TB, Fraction
oracle, runner and prose are original repository Apache-2.0 contributions,
covered by root [LICENSE](../../../LICENSE) and [NOTICE](../../../NOTICE).
