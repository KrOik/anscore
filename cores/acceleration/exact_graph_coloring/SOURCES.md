# Origin and semantic deduplication

Baseline: `ff2aadf8ebdc8e5475b7022cd68d47e496b9f593` (B19).
Before RTL, the cumulative 76-package inventory and the complete cores tree
were searched for chromatic number, graph/vertex coloring/colouring, conflict
graph and Chinese graph-coloring terms. Existing maximum_clique was read in
full: it selects a largest pairwise-compatible subset and explicitly returns
no vertex colours. Flow, bipartite matching and weighted interval scheduling
do not minimize colours of an arbitrary undirected conflict graph. Pixel
chromatic processing has unrelated semantics. No existing core implements the
proper-colouring service here. In particular, a five-cycle needs three colours
despite having maximum clique size two.

Read-only upstream reference, before the first local RTL write:

- Repository: https://github.com/networkx/networkx
- Version: NetworkX 3.5; annotated tag object
  `cd59914a6e46b04f006633f203ee7b4878d53159`, peeled through the GitHub Git tag
  API to commit `4fa222d2fb157e1b7f8c753c9f92e5907d1ddeb4`.
- Complete source actually fetched and read:
  https://raw.githubusercontent.com/networkx/networkx/4fa222d2fb157e1b7f8c753c9f92e5907d1ddeb4/networkx/algorithms/polynomials.py
  (11278 bytes, SHA256
  `88fdf4fe670e963f3556bcede2207f659c58891a24b9bb3e3b58bd456e29813c`).
- Complete BSD-3-Clause license actually fetched and read:
  https://raw.githubusercontent.com/networkx/networkx/4fa222d2fb157e1b7f8c753c9f92e5907d1ddeb4/LICENSE.txt
  (1763 bytes, SHA256
  `3cf7c3a179d817b23b8b8568211769fefdf93797d207d984b8b2fa24d0220b33`).

The first raw lookup mistakenly used the annotated tag object and returned
404; the tag API resolved the actual commit. A GBK console print failed before
the initial source display; a UTF-8 display then read both complete files.
No remote code, install command, dependency or test was executed. The web
search connector was unavailable, so fixed primary GitHub sources were used.

NetworkX's deletion/contraction polynomial counts proper k-colourings. This
local RTL instead builds independent vertex subsets and an exact minimum
partition DP with a hardware backtrace. Local Python independently enumerates
restricted-growth colour assignments, with a second edge-subset inclusion/exclusion
chromatic count for small graphs. Neither implementation imports NetworkX or SymPy.
No upstream code or license text is copied into the production implementation;
all new files are original Apache-2.0 work under repository LICENSE/NOTICE.
There are no runtime third-party, sibling, network or generated-ROM dependencies.
