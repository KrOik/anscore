# Author static review and execution boundary

The author wrote and manually reviewed the complete RTL, full-port example,
set/Fraction model, fixed recipes, TB, separate preparation gate, fixed matrix
runner and bounded process-tree launcher. This document records design review;
it is not compiler, oracle, numerical or hardware evidence.

Manual invariants reviewed before input sealing:

1. Every right/down candidate has an explicit boundary check before pixel RAM
   access. WIDTH/HEIGHT1 and non-square rasters use independent coordinates.
2. Both graph-generation passes use the same immutable captured pixels and
   source/direction traversal. Count sum E, exclusive prefixes, stable cursor
   scatter and complete0..E-1 replay give the specified full graph order.
3. Every RAM read has a separate capture state. Bank write/read conditions are
   exclusive. Neither payload nor synchronous read-q has a reset loop.
4. Every wrapper merge uses two current roots. Metadata is written only at the
   actual root returned by the unchanged rank-based backend. Canonical labels
   remain minimum members independent of physical roots.
5. Full product width includes C+8 and at least16 bits. The initial draft's
   small-profile K comparison-width truncation was found by static inspection
   and corrected before any numerical/HDL execution. The fixed1x7 checker case
   with K2048 detects that truncation without adding an adaptive test.
6. First K/minimum/tag capture is handshake-owned. Marker errors drain fixed N
   samples, accumulate all bits and suppress segmentation/final pixel outputs.
7. Final labels/areas/region count are emitted only after both selected phases
   complete. Held output payload and owner metadata cannot be overwritten.
8. TB asserts reset on the very observation negedge of each named predicate;
   RESETAT records that state. A next-frame offer is held through cancellation
   and its first actual post-reset handshake is checked.
9. TB verifies every sorted edge's source-derived weight, in-bounds direction,
   uniqueness and lexicographic order, and count E. It also compares each final
   output tuple. The runner checks exact raw tuple/sort/frame streams and probe
   predicates, rather than accepting a PASS substring.
10. Windows launch is suspended until Job Object assignment; no breakaway is
    enabled. One20-second launch deadline and bounded cleanup apply. Exclusive
    attempt directories preserve the first terminal failure and later NOT_RUN.
11. Raw evidence attributes cover root/nested preparation, reports, artifacts,
    failure_archive, history and evidence before execution. Raw/vvp bytes are
    -text. Source/fixture text is LF.

All actual preparation/tool/oracle/HDL statuses remain NOT_RUN. No package
program has been invoked by the author. Root must independently review the
sealed author inputs before numerical preparation, and independently review
the resulting source seal/receipt before the fixed HDL attempt. No source,
stimulus, criterion, timeout or matrix changes are authorized after a failure.
Any repair requires preservation and a new explicit root decision.
