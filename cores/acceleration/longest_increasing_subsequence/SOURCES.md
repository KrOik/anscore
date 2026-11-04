# Pre-RTL source and license inspection

Baseline: `83b11ea30d4762c5893cf37a8303b11706321876`.

Read-only GitHub contents API inspection on 2026-11-05, before local RTL:

- Repository: https://github.com/TheAlgorithms/Python
- Fixed commit: `574d100b7181956e9c8384552fd078165e4cc326`
- Actual file: `dynamic_programming/longest_increasing_subsequence_o_nlogn.py`
- Source SHA256: `2c711292c4008166a31d89971d08f3774b9dbb51f519787f9d70255ea30f0cf0`
- Git blob: `bbc7a62b6b5c6b212a2c40fdcc6e72cd7803a6fc`
- Full actual `LICENSE.md` read; MIT, copyright 2016-2022 TheAlgorithms and contributors.
- License SHA256: `4395a1dc4bda1d6054c45b4d1230c709c7398e6d66f1d0aff4b22d95973bea56`
- License blob: `de631c3ef33374d91a78dca3a656806e4e3bb890`.

The inspected function computes length using minimum tails and lower bound
(`>=`), so equality cannot extend a strict subsequence. Its comment describes
subsequence output, but the actual function returns only a length. The local
RTL is independently authored Apache-2.0: synchronous serial memory accesses,
predecessor history, forward witness replay, stream ownership, marker/overflow
errors and reset cancellation are new. No upstream Python is executed or
required, copied source, generated artifacts or remote build dependencies.
The complete inspected license is retained below as reference provenance.

## MIT License

Copyright (c) 2016-2022 TheAlgorithms and contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Semantic deduplication

Global production RTL/README search for longest increasing subsequence,
patience sorting and Chinese equivalents found no service. `edit_distance`
computes pairwise Levenshtein distance; `smith_waterman_affine` computes local
alignment scores; `sequence_knn` ranks candidates by distance. Top-K,
prefix/window extrema and frame sorting discard the original index partial
order or do not optimize subsequence length. None returns an optimal strict
subsequence of arbitrary raw signed samples with original indices.

Offline closure is exactly files.f plus the local example; Python standard
library and Icarus are verification tools only. Root LICENSE/NOTICE apply.
