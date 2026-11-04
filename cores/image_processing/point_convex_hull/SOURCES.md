# Source search and license

The RTL, example, exact oracle and generated TB template are independently
written under the repository Apache-2.0 license. No third-party source text
was copied, adapted or translated. No upstream runtime dependency is required.
Development baseline: `e711afc3a3c977cd850b55eb98462b190d22d082`.

Repository-wide searches of RTL/README/SPEC files for convex hull, convex
polygon, polygon fill/rasterization and related geometry found no point-set
hull implementation. Existing contour extraction emits ordered cell edges;
CCA gives component bbox statistics; the geometry library transforms images.
Those distinct assets were left unchanged.

Read-only predevelopment reference:

- Repository: https://github.com/TheAlgorithms/Python
- Fixed commit: `574d100b7181956e9c8384552fd078165e4cc326`
- File: `geometry/monotone_chain.py`
- URL: https://github.com/TheAlgorithms/Python/blob/574d100b7181956e9c8384552fd078165e4cc326/geometry/monotone_chain.py
- Source Git blob: `05e530e02d93d9ef2add84989499879b4ad84c8d`
- Source SHA256: `1f76ce2110b374100cc0fef2063e003e0241b1f4a7abb347563391a498d59d3c`
- License: MIT, actual text retrieved at the same fixed commit.
- License URL: https://github.com/TheAlgorithms/Python/blob/574d100b7181956e9c8384552fd078165e4cc326/LICENSE.md
- License Git blob: `de631c3ef33374d91a78dca3a656806e4e3bb890`
- License SHA256: `4395a1dc4bda1d6054c45b4d1230c709c7398e6d66f1d0aff4b22d95973bea56`
- Upstream copyright: 2016-2022 TheAlgorithms and contributors.

The source was inspected to check the general Andrew algorithm, strict
collinearity rule, canonical ordering and degenerate cases. The local RTL
independently implements explicit bounded storage, insertion sorting, a shared
signed determinant multiplier, streaming transactions, masks, capacity error
handling and reset. The oracle deliberately uses the different Jarvis march
algorithm. No upstream Python was executed or imported by the tests.

The source's bibliography identifies Andrew, A. M. (1979), “Another efficient
algorithm for convex hulls in two dimensions”, Information Processing Letters
9(5), 216-219. This bibliographic pointer was not separately fetched or used
as a claim of paper-level verification.

All retrieval used read-only GitHub API requests. An initial unrelated old
candidate path request did not yield source and was abandoned. External text
was treated as reference data; no remote setup/build script or installation
command was run. No upstream license-bearing source is redistributed here.
