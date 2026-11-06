# Finite qualification

Current status is **FINITE_QUALIFICATION_PASS / HW_UNVERIFIED**. The core and
actual two-client example passed the single approved finite plan. The sealed
README and manifest retain their pre-execution authoring state; this document
and [QUALIFICATION.json](QUALIFICATION.json) record the later observed result.

The [receipt](reports/20261106T183141267050Z/results.json) has SHA256
`23181675d26c3172289e0369d657834195d7ff74355128a24abdc0c410b74489`.
Three preparation children and all eleven HDL children passed: three syntax,
four compile and four simulation. There were zero failures, timeouts, cleanup
actions or retries. Every target exited normally with code zero; all output
capture completed. No source or control was changed after execution.

| Profile | N/P/Q/T | Main commands | Main fills | Held cycles | Future offer blocked | Reset probes | Cycles |
|---|---|---:|---:|---:|---:|---:|---:|
| Singleton | 1/1/1/1 | 43 | 0 | 215 | 210 | 6 | 904 |
| Ragged | 5/9/7/4 | 116 | 9 | 616 | 575 | 6 | 3411 |
| Maximum | 32/32/32/32 | 413 | 36 | 2209 | 2060 | 6 | 30078 |
| Actual two-client example | 8/32/32/8 | 9 | 4 | 48 | — | — | — |

Core main vectors cover572 completions and45 fills. Together with the example,
the reported counters are581 completions,49 fills and3088 held cycles. These
exclude hand-derived core reset preamble commands/fills. Ragged and maximum
each accept one additional prefix fill before reset in a directed probe.
The eighteen explicit core reset probes are distinct from the example's two
reset pulses; neither is an aggregate count of all core reset pulses. The
example also observes one simultaneous two-client offer.

The independent list-based oracle generated three vector/preparation pairs.
Core comparisons check every completion and fill field, maker-price execution,
price-before-time and same-price FIFO, partial makers, cancellation and slot
reuse, zero/all-ones IDs and values, bad operations, conservative full-capacity
admission and error precedence. Genuine future offers remain blocked behind
held completions. Six probes per core profile exercise reset at private and
visible transaction stages. The maximum vector includes a31-maker sweep.
The real example checks round-robin arbitration, owner-specific held responses,
actual fills, a blocked client and reset during a held response.

The longest simulation child was the maximum profile at approximately0.453
seconds of host execution. Its30078 testbench cycles include finite fixtures
and stalls; this is not a physical throughput or unconditional service bound.
Seven syntax/compile stderr streams contain only the two inherited timescale
diagnostics from unchanged dependencies. Preparation/simulation stderr is empty.

[Author audit](POST_AUTHOR_AUDIT.json), [root audit](POST_ROOT_AUDIT.json) and
[independent peer audit](POST_PEER_AUDIT.json) found no discrepancy. They bind
nineteen current/archive source pairs, twenty-four tool files, the exact three
control pairs, fourteen initial/terminal/validated records each, twenty-eight
raw streams, four retained original images and three vector/preparation pairs.
Each simulation's exclusive initial record contains the prechecked image hash;
the reviewed runner fsyncs it before process creation. The consumed once guard,
original records and images remain retained. No new execution is authorized by
this qualification.

Both unchanged dependencies have mode100644/blob baseline proofs at
`05b9614c3962e9d4ae934c4b9c7bd315cc01aed4`, checked against the retained tree
and raw Git blob bytes. No support bridge was added.

Synthesis, PnR, STA, board validation, PPA and historical regression are
**NOT_RUN**. Physical RAM packing, fit and timing are unmeasured. The service
requires a free slot before any NEW fill, has no atomic amend, and resets an
epoch without reversing externally accepted fills. Risk, self-trade prevention,
market/IOC orders, auctions, venue compatibility, feed/session recovery,
persistence and certification remain outside scope.
