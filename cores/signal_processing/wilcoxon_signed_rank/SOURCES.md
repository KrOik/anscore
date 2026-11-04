# B13 semantic and actual fixed-source preflight - 2026-11-04

Baseline: `fcd2beef77f998da54801b91d74ce47946bee17c` (published B12).
Before RTL, actual production RTL/README/SPEC searches for Wilcoxon,
word-boundary signed-rank and Chinese signed-rank terminology found no equivalent
service. The first broad signed-rank expression also matched the substring in
unsigned-rank comments; a corrected word-boundary search excluded those hits.

Actual nearby RTL and README were read. `mann_whitney_u` receives independent
group labels and computes cross-group U/win/loss/tie statistics. It never forms
paired differences or ranks their absolute magnitudes. `stream_histogram_rank`
selects a supplied population rank/median from a histogram; `stream_frame_sort`
sorts supplied keys and returns ordered records. Neither derives signed sums
of averaged absolute-difference ranks. B12 `ks_histogram_distance` computes a
supremum of two histogram CDF differences. This paired Wilcoxon service has a
different input meaning, ranking population and statistic. No old package is
edited, promoted or used as an RTL dependency.

## Actual fixed source and complete license inspection

[SciPy](https://github.com/scipy/scipy), v1.15.2 fixed commit
`0f1fd4a7268b813fa2b844ca6038e4dfdf90084a`. Read-only GitHub contents API
requests returned complete base64 payloads with 15-second per-request limits.
They were decoded as strict UTF-8. The complete BSD3 license, actual Wilcoxon
implementation and actual average-ranking helper were inspected before local
RTL was written. Truncated tool display was followed by a focused reread of
the remaining Wilcoxon body.

| File | Git blob | Bytes | SHA256 |
| --- | --- | ---: | --- |
| [LICENSE.txt](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/LICENSE.txt) | `117117616e806a9bb960b1f32a552c8c912b0497` | 1536 | `c29fb8e5936f33237a8b15256b4c6e93037f05bbf58c3d7b5755aede4c200173` |
| [scipy/stats/_wilcoxon.py](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/stats/_wilcoxon.py) | `bdb475614d7d28edaf3ff04bfbda3f5a18242bef` | 9382 | `c2aff6b0fc2e895035900156270df27a0169d133f95950023e46224ccac3b3d5` |
| [scipy/stats/_stats_py.py](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/stats/_stats_py.py) | `4b8c1850cd0dad3d654216ae45dad04dafaa983b` | 417517 | `01b665feba503fd53684d00ca6f322550fa41d414e09da482ab97f48d64b8a5b` |

The full license names Enthought and SciPy Developers, requires retention of
notices, conditions and disclaimer, and restricts endorsement. The actual
`_wilcoxon_statistic` removes exact zero differences for its wilcox convention,
calls `_rankdata(abs(d),'average')`, and sums positive/negative ranks. The
actual `_rankdata` sorts values, finds equal groups, and assigns the average
occupied ordinal rank. The two-sided source result selects the smaller sign
sum. Its Pratt/zero-split variants, z score, tie-corrected variance, exact/
permutation/asymptotic p-values and inferential decisions are excluded locally.

The local core computes fully extended integer x-y and exact doubled ranks;
the upstream API has floating arrays, broader zero conventions, NaNs and
inference. Local zero-population/overflow rejection and bounded-prefix
diagnostics are explicit hardware contracts. No API, dtype, NaN, floating-point
or bitwise compatibility is claimed. The local algorithm uses per-target
serial comparisons rather than an upstream sort or vector operation.

No upstream implementation, source, comments, tests, license text or build code
was copied, adapted, translated, executed or redistributed. Retrieved bytes
were reference text only; no downloaded file was persisted, imported or run.
New RTL, wrapper, independent sorted-group oracle, TB, runner and prose are
original repository Apache-2.0 work under root [LICENSE](../../../LICENSE) and
[NOTICE](../../../NOTICE). Both manifests are local, dependency lists are empty,
and offline use requires no SciPy, network, sibling/untracked RTL, generated
table, external RAM, vendor primitive or remote build.
