# Sources and licenses

Read-only research was completed before authoring on 2026-11-07. Candidate:
alexforencich/verilog-axis at commit 48ff7a7e2ef782cf778d47910cf85835c64b1bce.

- COPYING: https://raw.githubusercontent.com/alexforencich/verilog-axis/48ff7a7e2ef782cf778d47910cf85835c64b1bce/COPYING
  1,062 bytes; SHA256 8ea57f95365e9b16a5b516f422b71269183a1ae53bab5878ae6d69039e58fe77.
- rtl/axis_rate_limit.v: https://raw.githubusercontent.com/alexforencich/verilog-axis/48ff7a7e2ef782cf778d47910cf85835c64b1bce/rtl/axis_rate_limit.v
  8,801 bytes; SHA256 bdfb4e29768c5224c543098765b8d648f3fe774eb42643c289d85b446414d155.

The full MIT license was inspected. The module uses fractional accumulator rate
control and optional frame-level pausing. It does not provide complete per-flow
payload ownership with exact KEEP-byte cost, atomic publication and SOP-only
whole-packet debit. It is a comparison reference only: no external source,
license text or executable was copied or run. The web connector failed; pinned
raw HTTPS source/license bytes were read with standard-library HTTPS instead.
New local RTL, model, tests and documentation are original Apache-2.0 work;
the repository Apache license is included locally.

Deduplication covered all 188 current formal packages, 410 root documents, 411
canonical HDL sources and common_scaffold production/documentation plus 150
operator specs and RTL. Existing multiflow_token_shaper is descriptor-only;
descriptor_drr_scheduler accrues by visits rather than wall-clock time;
cyclic_gate_packet_scheduler supplies cyclic service gates; shared_packet_queues
requires serialized explicit commands and POP. Packet-locked RR arbiters exist
but do not enforce per-flow real-time full-packet byte affordability. No combined
parent-port bucket is introduced here.

Unchanged offline canonical dependencies from baseline
3a58c99bda6f6f62a34d1c20247d3b42d8d89006:

- ../../system/multiflow_token_shaper/rtl/multiflow_token_shaper.sv
- ../../system/common_scaffold/memory/src/cip_sync_sp_ram.v
- ../../system/common_scaffold/memory/src/cip_sync_fifo.v

The source seal binds exact dependency and source bytes. No duplicate module,
new canonical alias or bridge is introduced. The independent model processes
whole packet lists and KEEP popcounts without importing the runner or RTL.
