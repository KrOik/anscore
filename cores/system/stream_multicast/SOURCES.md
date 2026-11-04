# Source and reuse review (2026-11-04)

Baseline repository commit: `430d420` (existing dirty assets left unchanged).

Before implementation, searched production source names and text for multicast,
broadcast, replication, fanout, forks, routing, arbiters and DMA capabilities.
`cores/system/stream_bus_library/rtl/sys_frame_switch4.v` locks a source to one
destination. `cores/system/common_scaffold/stream_bus/rtl/sb_stream_rr_arbiter.v`
is a many-to-one packet arbiter. Neither replicates one accepted beat to a
selectable set of independently backpressured consumers. Existing 2D video DMA
was also found and rejected as a duplicate development direction.

Read-only external candidate reviewed:

- Repository: https://github.com/alexforencich/verilog-axis
- Fixed commit: `48ff7a7e2ef782cf778d47910cf85835c64b1bce`
- File: `rtl/axis_broadcast.v`
- Source URL: https://github.com/alexforencich/verilog-axis/blob/48ff7a7e2ef782cf778d47910cf85835c64b1bce/rtl/axis_broadcast.v
- License: MIT; source header copyright (c) 2019 Alex Forencich. `COPYING`
  was separately fetched and its MIT grant checked before this delivery.
- Applicability: established AXI stream broadcast candidate; this package needs
  selective per-packet destination capture and a narrow explicit single-slot
  capacity contract, so a small independent design was chosen.
- Imported files: none. Local adaptations to upstream source: none.
- Additional third-party runtime/build dependencies: none. Icarus and Python
  are optional local validation tools and are not vendored into this package.

A preliminary DMA candidate was also read-only inspected before discovering
the repository's existing 2D DMA: https://github.com/alexforencich/verilog-axi
at `516bd5dadc3365b7f9e225d2af8fe0b8d804fe53`; MIT `COPYING` retrieved. No files
from that repository were adopted. No external install or build scripts ran.

All delivered RTL, example, scoreboard and runner are independently authored
for ANSCORE and covered by the root Apache-2.0 LICENSE. Full offline dependency
closure is `files.f` plus its listed source; the example and testbench are
separate optional consumers. No remote references are needed to compile it.
