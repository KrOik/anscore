# B15 semantic and actual fixed-source preflight - 2026-11-05

Baseline `9716da0847c26f09f4a9b856a84fc330dfb26351` (published B14).
Before RTL, the actual56-package committed inventory and README capability
leads were read. Production RTL/README/SPEC searches for Kendall, Spearman,
concordance, discordance, rank correlation and Chinese rank/inversion terms
found no service. Actual neighboring RTL/contracts were inspected:

- Theil-Sen computes a median of rational slopes between paired observations.
- Mann-Whitney compares independent group-labeled one-axis values for U.
- Wilcoxon ranks absolute within-row x-y differences and sums their signs.
- Stream linear fit forms normal equations for ordinary least squares.
- Label Adjusted Rand compares categorical pair equality and is invariant
  under arbitrary label relabeling, without ordinal directions.

None computes ordinal concordance/discordance and the Kendall marginal tie
normalization. This package has a different input meaning and mathematical
output; it does not specialize an existing width or rename a pair statistic.
No old/shared package is edited, promoted or depended upon. B14's root numeric
TIMEOUT remains untouched.

## Actual fixed upstream code and complete license, before RTL

[SciPy](https://github.com/scipy/scipy), v1.15.2 fixed commit
`0f1fd4a7268b813fa2b844ca6038e4dfdf90084a`. The documentation web endpoint
returned HTTP500. Read-only GitHub contents API requests with15-second HTTPS
limits succeeded; complete base64 payloads were decoded as strict UTF-8.
AST parsing selected the actual Python definition without executing it.

| Actual file | Git blob | Bytes | SHA256 |
| --- | --- | ---: | --- |
| [LICENSE.txt](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/LICENSE.txt) | `117117616e806a9bb960b1f32a552c8c912b0497` |1536| `c29fb8e5936f33237a8b15256b4c6e93037f05bbf58c3d7b5755aede4c200173` |
| [scipy/stats/_stats_py.py](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/stats/_stats_py.py) | `4b8c1850cd0dad3d654216ae45dad04dafaa983b` |417517| `01b665feba503fd53684d00ca6f322550fa41d414e09da482ab97f48d64b8a5b` |
| [scipy/stats/_stats.pyx](https://github.com/scipy/scipy/blob/0f1fd4a7268b813fa2b844ca6038e4dfdf90084a/scipy/stats/_stats.pyx) | `567a2bceadacb609468b1f68c9e2a0108bcf00a9` |27210| `de1368dab08c654cce5a321fb47a590b9dc415336a61defd97e4c34be484f7dc` |

The complete BSD3 license was read: Enthought and SciPy Developers copyright,
source/binary notice retention, nonendorsement condition and full warranty/
liability disclaimer. Actual `kendalltau` is lines5412-5637; its complete
executable body5525-5637 and nested tie-count helper were inspected. It sorts
and dense-ranks y, stable-sorts x, counts discordance, obtains marginal/joint
ties, rejects a constant axis and derives a floating tau-b from the signed
concordance difference divided by two square roots. It also implements tau-c,
NaN policies, inference and p-value choices that are excluded here.

The actual complete `_kendall_dis` Cython helper lines84-110 was read. It
queries a Fenwick cumulative rank tree for an equal-x group before inserting
that group, excluding x ties from discordant counts. The local RTL instead
classifies each unordered raw sample pair online using shared synchronous
RAM and direct signed comparisons. The local independent oracle uses strict
merge-sort inversions and multiplicity counts rather than that tree or RTL
pair scan. The output is an exact algebraic S/sqrt(R) representation with a
runtime shift-add radicand product, not SciPy's float scalar/API/dtype/pvalue.
No upstream bitwise or floating-point compatibility is claimed.

No upstream source, comments, tests, license text or build code was copied,
adapted, translated, persisted, imported or executed. All retrieved bytes were
read-only reference text. Local RTL, wrapper, oracle, TB, runner and prose are
original repository Apache-2.0 contributions under root
[LICENSE](../../../LICENSE) and [NOTICE](../../../NOTICE). The local manifests
close completely, with empty dependency lists. No SciPy, NumPy, online source,
generated table, external memory, vendor primitive or sibling/untracked RTL is
required for offline use.
