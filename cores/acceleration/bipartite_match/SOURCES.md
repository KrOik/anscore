# Semantic, external-source and license review — 2026-11-04

Baseline: cf9b62d. Before implementation, repository production RTL and
README/SPEC searches covered bipartite, Hungarian, augmenting path, maximum
matching, 最大匹配, 二分图 and 二部图. No equivalent assignment core was found.
Existing template/SAD/Chamfer matching compares image content, nearest-neighbor
cores rank candidates, and DSU/Kruskal maintain undirected graph components;
they do not enforce one-to-one compatibility assignment at maximum cardinality.

Read-only external candidate check:

- Repository: https://github.com/boostorg/graph
- Fixed commit: fca983ec9ddb07bfc89c8da391757e09ca95bdfd
- File: include/boost/graph/max_cardinality_matching.hpp
- Fixed URL: https://github.com/boostorg/graph/blob/fca983ec9ddb07bfc89c8da391757e09ca95bdfd/include/boost/graph/max_cardinality_matching.hpp
- Source retrieved: 31000 bytes; SHA256
  09c26de2626a0baf4699045569a563440569a7c704f95291adfbae6a3ed9395f.
- The commit was confirmed using the GitHub commit API. The viewed header
  declares copyright (c) 2005 Aaron Windsor and Boost Software License 1.0;
  the matching-size helper and software graph representation were inspected.
  The official BSL-1.0 text at https://www.boost.org/LICENSE_1_0.txt was already
  read during this goal's earlier DSU review. A follow-up attempt to retrieve
  the implementation region hit TLS EOF; no full general-graph implementation
  review is claimed.

The candidate is general-graph software and is not imported. This hardware
independently implements a bounded bipartite-only alternating BFS with explicit
storage, frame and output contracts. No upstream code is copied, translated,
adapted, executed or redistributed. No upstream build/installation script ran.
The source, example, finite TB, max-flow/subset-DP oracles and prose are original
Apache-2.0 contributions under the root LICENSE/NOTICE. Boost is not a build
or offline dependency.

Existing local FIFOs were considered read-only: cip_sync_fifo uses CE-qualified
transfers and asynchronous active-low reset; ips_fifo_sync_fwft also has
power-of-two depth semantics. A bounded private BFS scratch queue avoids
introducing an asynchronous per-search reset adapter and keeps queue ownership
coupled to the visited map. It is internal search storage, not a new general
FIFO product. No existing RTL was changed and no historical hardware evidence
was inherited.
