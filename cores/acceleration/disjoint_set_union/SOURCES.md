# Search, license and originality — 2026-11-04

Baseline: ba0b98f. Semantic repository searches covered union-find, disjoint
sets, connectivity, parent tables and path compression in production RTL and
README/SPEC files. The existing `dsp_isp_library/isp/cca` deferred equivalence
table supports frame-local pixel labeling and region features; common_scaffold
connected_components performs buffered image flood fill. Neither exposes this
arbitrary node-set FIND/UNION/SAME/CLEAR command and group-count interface.
No existing RTL or historical hardware evidence was changed.

Predevelopment GitHub repository searches for `union find verilog` and
`disjoint set FPGA` returned no candidates. A read-only primary software
reference was then inspected:

- Repository: https://github.com/boostorg/graph
- Fixed commit: fca983ec9ddb07bfc89c8da391757e09ca95bdfd
- File: include/boost/pending/disjoint_sets.hpp
- Fixed source: https://github.com/boostorg/graph/blob/fca983ec9ddb07bfc89c8da391757e09ca95bdfd/include/boost/pending/disjoint_sets.hpp
- The header explicitly declares Boost Software License Version 1.0 and
  University of Notre Dame copyright. The actual Version 1.0 text was read
  from https://www.boost.org/LICENSE_1_0.txt. The attempted same-file license
  URL in the component repository was absent (404); the header's official
  license URL succeeded. An initial boostorg/pending repository guess was
  also 404; no source was obtained from that path.
- The reference supplies general set/representative/rank concepts and software
  compression alternatives. The delivered hardware independently uses an
  explicit synchronous-RAM state schedule without path compression.
- No upstream source was copied, translated, adapted or redistributed. No
  Boost dependency, third-party modification, generated code or external
  primitive is incorporated. No upstream script/build/installation ran.

All delivered RTL, example, reference model, TB, runner and prose are original
Apache-2.0. Offline compilation and finite checks do not require Internet,
Boost, external memory images or downloaded source.
