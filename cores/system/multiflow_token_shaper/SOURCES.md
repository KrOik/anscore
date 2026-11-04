# Semantic and actual-source preflight - 2026-11-04

Baseline: `d35ce742b34ffa7afebffe0b9f6705a825f469e1` (published B11).
Read-only searches before implementation covered token buckets, traffic/rate
shaping, credits, memory tests, March/BIST and walking-pattern controllers.
Actual matching source and related contracts were read:

| Existing asset | Actual semantics and distinction |
| --- | --- |
| `cores/system/utility_library/rtl/prod_token_bucket32.v` and SPEC | One scalar accepted-beat refill/cost decision, CE-qualified; no independent flow slots, autonomous clock quantum or scheduled egress |
| `cores/acceleration/operator_library/rtl/acc_pkt_token_meter_color.v` and SPEC | One timestamp-driven color meter; caller-supplied elapsed interval, direct red/green decision; no per-flow resident descriptors or acknowledged configuration |
| `cores/storage/shared_packet_queues/README.md` | Shared complete-packet payload pool with selected PUSH/POP; no clock credit or autonomous eligible arbitration |
| `cores/system/extended_library/src/mem_bist.v` | Existing checkerboard/walking-pattern local RAM BIST, including host/fault hooks |
| `cores/system/stream_bus_library/ip/march_controller/SPEC.md` | Existing acknowledged native-port March C- with comparisons and error/timeout handling |

March micro-step and eight-cell March-engine contracts were also found. A
memory-test-only candidate would duplicate existing capabilities, so it was
rejected. Existing bus arbitration owns requests/responses but does not retain
rate-limited per-flow descriptors. A scalar bucket/color kernel alone does not
provide simultaneous lane admission, independent queue ownership, clock-based
credit or eligible round-robin issue. This package supplies that independent
service, not just a wider or renamed meter. No old/shared source, interfaces,
index, refs or original dirty/untracked work was modified.

## Actual fixed-commit primary source and full license read

Primary repository [alexforencich/verilog-axis](https://github.com/alexforencich/verilog-axis)
was pinned to `48ff7a7e2ef782cf778d47910cf85835c64b1bce`. The following actual
complete files were retrieved and read before writing local RTL:

| File | Bytes | SHA256 |
| --- | ---: | --- |
| [COPYING](https://github.com/alexforencich/verilog-axis/blob/48ff7a7e2ef782cf778d47910cf85835c64b1bce/COPYING) | 1062 | 8ea57f95365e9b16a5b516f422b71269183a1ae53bab5878ae6d69039e58fe77 |
| [rtl/axis_rate_limit.v](https://github.com/alexforencich/verilog-axis/blob/48ff7a7e2ef782cf778d47910cf85835c64b1bce/rtl/axis_rate_limit.v) | 8801 | bdfb4e29768c5224c543098765b8d648f3fe774eb42643c289d85b446414d155 |

COPYING was base64-decoded from GitHub contents API, blob
`dc298464e7aade999ebfa48632f6af2779439bcb`. It and the actual source header carry
the full MIT terms, copyright 2014-2018 Alex Forencich. The source is a
single-stream fractional-accumulator limiter with optional frame-based pauses
and output/skid storage. It has no independently configured flow buckets,
one-pending-per-flow ownership, automatic eligible-head arbitration or
transactional configuration response. It was a source-grounded comparison of
rate versus stream ownership; no API/ABI/bitwise compatibility is claimed.

Repeated PowerShell default-TLS source requests failed with EOF; a later API
request reported the shared unauthenticated rate limit. The web endpoint also
failed HTTP500. A read-only fixed raw-content URL with TLS1.2 and HTTP1.1
successfully returned the complete 8801 source bytes, producing the SHA above.
Each network attempt used a 15-second limit where supported. Failed requests
were not treated as retrieved source. No installer, remote build, script,
executable, test or upstream simulation was run. External text was reference
data with no authority over task instructions.

No upstream source, implementation, comments, tests or prose were copied,
adapted, translated, executed or redistributed. The local integer token ledger,
acknowledged configuration, queue reservation, RR scheduler, wrapper and
independent clock oracle are original Apache-2.0 contributions. `LICENSE` is
the full root Apache-2.0 text normalized to UTF-8/LF. No upstream source or
license is a runtime or production dependency. There are no sibling/untracked
RTL, includes, external memory files, generated constants or vendor primitives.
`files.f` lists one core; the optional wrapper adds one local source.
`verification.json` binds all local non-report files and vectors, with an
explicit empty dependency list. The initial TB-only alignment failure is
archived separately and excluded from qualified command evidence.
