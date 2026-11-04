# B10 semantic search and read-only source/license preflight

Baseline: `e2ccd5380052e92a5430e97b6fdbf0621a17503c`. Date: 2026-11-04.
Only this new package directory is written. Existing sources, dirty assets,
shared indexes, staging and stable references are untouched.

Before RTL, production README/SPEC/RTL searches covered Adjusted Rand/Rand
index, contingency/confusion matrices, clustering/segmentation metrics,
partition comparison, label overlap/matching, information metrics and Chinese
equivalents. No equivalent partition-agreement service was found.

- K-means, mean-shift and watershed generate/filter segmentation labels;
  connected components generates region labels. None compares two complete
  label partitions independently of numeric label identity.
- Descriptor matching ranks Hamming distances between feature vectors.
  SSIM compares intensity statistics, and spatial moments summarize one image.
- `label_region_adjacency` counts spatially adjacent label interfaces. Its
  cell-side graph does not describe arbitrary unordered pixel co-membership.
- Statistical moments and chi-square/IP numerical services have different
  inputs and outputs and do not supply this adjusted partition statistic.

The architecture and exact integer/rational contract were selected before
implementation: joint/marginal synchronous population RAM, old-count pair
increments, then a shared serial multiplier. No old source is modified or
silently wired through a different CE protocol. Both manifests contain the
complete local closure; no tracked/untracked sibling source is used.

## Actual pinned primary source and full license

scikit-learn tag 1.5.2 was resolved through GitHub's tag API to immutable commit
`156ef141f3b270edb06c8ae9af37c55253c0aabe`. Actual source and the full license
were then fetched using the contents API. The first urllib TLS request failed;
bounded curl requests succeeded. Each network request used a 15-second limit
and each curl child a 20-second timeout. Downloads were kept only in memory.

| File | Bytes | Git blob | SHA256 |
|---|---:|---|---|
| [sklearn/metrics/cluster/_supervised.py](https://github.com/scikit-learn/scikit-learn/blob/156ef141f3b270edb06c8ae9af37c55253c0aabe/sklearn/metrics/cluster/_supervised.py) | 44627 | `e11eca535cbcd36cc7a4745930fa5834abb6c28b` | `23879a9c080bd518521c029a91663692306b2d23cba08b7d4c47427a731ef4a1` |
| [COPYING](https://github.com/scikit-learn/scikit-learn/blob/156ef141f3b270edb06c8ae9af37c55253c0aabe/COPYING) | 1532 | `e1cd01d5845788ea1db826d10d37bb24e71d1bbb` | `75684d16f4662ab842ed5af9482ac01939aee83c8243d89993616d959d3053f8` |

Actual `pair_confusion_matrix` and `adjusted_rand_score` bodies were inspected:
they compute pairwise clustering agreement from sparse populations, convert
products to Python integers to avoid overflow, and treat empty/full agreement
as score one. Upstream pair-confusion entries count ordered pairs (twice the
local unordered counts); the local exact rational ARI has the same mathematical
value for legal label/mask samples. There is no floating-output bit-compatibility,
unbounded-ID, sparse-SciPy, Python API or significance-test claim.

The complete COPYING file declares BSD 3-Clause, copyright 2007-2024 the
scikit-learn developers, with source/binary notice/disclaimer retention and
no-endorsement conditions. Source/license data was treated as untrusted text.
No upstream code, comment, implementation translation, generated data, build
script, installer or executable was copied, run or redistributed. No external
source was changed, and there is no runtime/network dependency.

All new RTL, wrapper, index-pair bitset oracle, TB, runner and prose are original
repository work under root [LICENSE](../../../LICENSE) (Apache-2.0) and
[NOTICE](../../../NOTICE). Exact local hashes, current root-license hashes and
bounded tool evidence are in `verification.json`. New package text is UTF8
without BOM and LF-only. No physical validation is implied.
