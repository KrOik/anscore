# Semantic and external-source review — 2026-11-04

Baseline: cf23435. Production RTL and README/SPEC searches for Smith-Waterman,
local alignment, affine gap and 局部比对 found no equivalent. The existing
edit_distance implements unit-cost global Levenshtein distance; sequence_knn
composes that metric for candidate selection. Neither provides local affine-gap
scores/endpoints. No existing RTL or prior physical evidence was changed.

Predevelopment read-only reference:

- Repository: https://github.com/jeffdaily/parasail
- Commit, resolved through the GitHub API before retrieval:
  fb985ee4f2302c72c87d7d56443712b2d920b106
- src/sw.c: 4651 bytes, SHA256
  c2dcc44311a9a33b830a0af13e6ff4ff10594fca27dd2093398cc502e96ff847.
- LICENSE.md: 2346 bytes, SHA256
  31278448a29990fcfe74c6d85e95584d6b6cc843237aec5294bbce33554733a4.
- Fixed source: https://github.com/jeffdaily/parasail/blob/fb985ee4f2302c72c87d7d56443712b2d920b106/src/sw.c
- Fixed license: https://github.com/jeffdaily/parasail/blob/fb985ee4f2302c72c87d7d56443712b2d920b106/LICENSE.md

Both complete files were read, including the open/extend recurrence, score
boundaries and software endpoint tie rule. The license is Battelle Memorial
Institute's 2015 permissive text with source/binary notice, name-use and an
additional citation condition; it is not relabeled as plain BSD-3-Clause.
Its requested software reference is Jeff Daily, "Parasail: SIMD C library for
global, semi-global, and local pairwise sequence alignments", BMC Bioinformatics
17 (2016), DOI 10.1186/s12859-016-0930-z.

This is an algorithm/boundary comparison, not imported implementation. No
upstream code is copied, translated, adapted, executed or redistributed.
The new hardware independently uses packed synchronous row storage, zero-clamped
gap-state reasoning, explicit dual-stream ownership, whole-pair overflow
rejection and one-based earliest row-major endpoints. It does not claim API or
endpoint-tie compatibility with Parasail. The full-matrix/all-gap-length oracle
does not import that library. No upstream script, installation or build ran.

All delivered RTL, example, tests and prose are original Apache-2.0 contributions
under the repository root LICENSE/NOTICE. No external runtime/build dependency,
generated production source or online resource is required offline.
