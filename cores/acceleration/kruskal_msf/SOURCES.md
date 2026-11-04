# Sources, semantic review and license — 2026-11-04

Development baseline: e711afc. Repository searches for minimum spanning,
Kruskal, Prim algorithm and 最小生成 in production RTL and README/SPEC found
no existing equivalent. A heap alone sorts edges and a DSU alone manages
components; neither implements graph framing, forest selection, total weights
and error policy. The new wrapper provides that capability by composition.

Read-only predevelopment reference:

- Repository: https://github.com/boostorg/graph
- Fixed commit: fca983ec9ddb07bfc89c8da391757e09ca95bdfd
- File: include/boost/graph/kruskal_min_spanning_tree.hpp
- URL: https://github.com/boostorg/graph/blob/fca983ec9ddb07bfc89c8da391757e09ca95bdfd/include/boost/graph/kruskal_min_spanning_tree.hpp
- Retrieved source SHA256:
  bf3a87bbb3b847f78ee75329b6f8f1da6fd5a2f4f312c2e23e37182a9eba409b
- Header declares Boost Software License 1.0 and University of Notre Dame
  copyright (1997–2000; authors Andrew Lumsdaine, Lie-Quan Lee, Jeremy G. Siek).
  The actual BSL-1.0 text at https://www.boost.org/LICENSE_1_0.txt was read
  earlier in this session during the existing DSU source review; a repeat
  request here hit transient TLS EOF. The fixed algorithm header was
  successfully read after the first TLS request failed. No external build,
  script or installation was executed.

The software reference confirms the undirected edge-order plus set-link
algorithm. No Boost code was copied, translated, adapted or redistributed.
The synchronous command schedule, framing/error rules, RTL, TB, independent
Prim oracle and prose are original Apache-2.0 contributions under the root
LICENSE/NOTICE. Boost and Internet access are not runtime/build dependencies.

Reused local RTL (unmodified):

- ../binary_heap_queue/rtl/binary_heap_queue.sv, feature af5fdeb, Apache-2.0.
- ../disjoint_set_union/rtl/disjoint_set_union.sv, feature 2510a69, Apache-2.0.

The exact bytes of both dependencies are bound in verification.json and the
cumulative source snapshot. Their own SOURCES records retain upstream review
history. No generated memory, external storage image or vendor core is needed.
