# B10 semantic and fixed-source preflight - 2026-11-04

Baseline: `e2ccd5380052e92a5430e97b6fdbf0621a17503c`.
Preflight and the numerical/resource/interface brief preceded new RTL.

Production RTL/README/SPEC searches covered Mann-Whitney, Wilcoxon, rank
biserial, Kendall, Spearman, rank sums, two-sample comparisons, 秩和 and
秩相关. No equivalent two-group tie-aware rank-statistic service was found.
The old stable `stream_frame_sort` returns sorted records and ordinal output
positions, not average tie ranks, cross-group U or an effect. Histogram rank
selects one order statistic of a single population. Raw moments, chi-square,
PAVA and normalization have different mathematical outputs. None provides
this service by width or handshake adaptation alone.

The tracked, clean `dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv` already
supplies signed nearest-even final division. Its `fp_div_iter` is instantiated
unchanged; `fp_div_pipe` in the same complete source is not instantiated.
Baseline byte identity and the dependency SHA256 are verified in packaging.
Both manifests contain this one sibling source. Root Apache-2.0 LICENSE/NOTICE
provenance is preserved in place. No untracked dependency is included or edited.

## Actual external source and full license

[SciPy](https://github.com/scipy/scipy), fixed v1.15.2 commit
`0f1fd4a7268b813fa2b844ca6038e4dfdf90084a`.
The pinned GitHub contents API supplied complete actual bytes, which were
decoded and read. The full BSD 3-clause license and the actual `mannwhitneyu`
and `_get_mwu_z` function bodies were inspected before implementation.

| File | Bytes | SHA256 |
| --- | ---: | --- |
| [LICENSE.txt](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/LICENSE.txt) | 1536 | `c29fb8e5936f33237a8b15256b4c6e93037f05bbf58c3d7b5755aede4c200173` |
| [scipy/stats/_mannwhitneyu.py](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/stats/_mannwhitneyu.py) | 19330 | `2d0208d1fe42178f8e7d65ea06e3f8b8f8cd27c22e5603e9d388ada9a732d440` |

The license names Enthought and SciPy Developers, requires retained notices,
conditions/disclaimer, and restricts endorsement. The reference uses pooled
average ranks and U1=R1-n1*(n1+1)/2, with U1+U2=n1*n2. Its exact/asymptotic/
permutation p-value methods, tie variance correction and continuity correction
are a separate inference layer, intentionally absent here. The mathematical
rank-sum identity grounds the independent local oracle; no upstream `_rankdata`
implementation, numerical distribution code or test suite is adopted.

This RTL instead counts oriented cross-group comparisons with half-credit ties
and emits integer 2*U_A plus one final RNE effect division. No upstream source,
comments, tests, build scripts, implementation or license text was copied,
translated or redistributed. Every curl request had a 15-second bound;
temporary reference downloads were deleted. External source was parsed/read
as text only, not imported or executed. No remote build/installer ran.

New RTL, wrapper, average-rank/Fraction oracle, TB, runner and prose are original
repository Apache-2.0 work under root [LICENSE](../../../LICENSE) and
[NOTICE](../../../NOTICE). Offline users need no SciPy, network, downloaded
script, generated table, vendor primitive or third-party runtime source.
