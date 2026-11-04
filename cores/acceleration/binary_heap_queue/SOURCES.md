# Source and reuse review, 2026-11-04

Baseline commit: `430d420`. Existing uncommitted assets were treated as available
capabilities during semantic de-duplication and were left unchanged.

Repository comparisons:

- `stream_topk`: keeps only K best items for a closed frame and drains at LAST;
  cannot preserve arbitrary queued entries across interleaved push/pop commands.
- `stream_frame_sort`: frame-bounded stable insertion sort, no online queue.
- `system/ip_series/src/ips_irq_priority_ctrl.v`: prioritizes interrupt bits,
  without dynamic key/payload storage or multiset commands.
- `system/common_scaffold/image/watershed/watershed_priority_frame.v`: image
  segmentation by gray level, not a reusable priority-queue command interface.
- Production filename and content searches for heap and priority queue found
  no reusable online key/payload heap implementation. Board snapshots and
  generated reports were excluded from the production-source comparison.

External pre-development read-only search used GitHub repository search for
`verilog priority queue`. The web search endpoint returned HTTP 500; GitHub
REST repository/commit/tree inspection and raw file reads succeeded.

Candidate: https://github.com/gvilardefarias/Hardware-Data-Structures

- Fixed commit: `f76ff951be8813471c9bb0bef86170488c28fd57`.
- Read files: `README.md` and `rtl/priority_queue.sv`.
- Source: https://github.com/gvilardefarias/Hardware-Data-Structures/blob/f76ff951be8813471c9bb0bef86170488c28fd57/rtl/priority_queue.sv
- License: GitHub metadata reports no license; recursive tree has no license
  file and inspected source has no explicit license grant. **Not eligible for
  incorporation.** No upstream code was copied, translated or adapted.
- Candidate uses a parallel ordered array and shifts entries. This package
  independently implements a serialized synchronous-memory binary heap with
  response ownership, signed keys, payload tie ordering, peek and clear.
- Imported files, local upstream modifications, third-party RTL dependencies:
  none. No remote installation or external build scripts were run.

All production RTL, examples, testbench and runner were independently authored
for ANSCORE under Apache-2.0. Python 3 and Icarus are optional local verification
tools, not delivered dependencies of the RTL. Offline compilation requires only
the RTL listed in `files.f`; no generator, network or memory file is needed.
