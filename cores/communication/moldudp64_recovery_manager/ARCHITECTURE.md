# Architecture and capability check

Baseline1e9e9130cef71127d2c8d2762affe815b067b9f5. Root approved the missing-prefix,
outstanding descriptor, explicit retry and partial-progress continuation
architecture before implementation. Whole public widths are preserved.

Actual neighboring RTL/specification inspection:

| Existing asset | Existing capability and boundary |
| --- | --- |
| moldudp64_itch_rx | Strict64-bit expected sequence,80-bit session, rejects whole future/overlap packet; no future payload buffer or request lifecycle |
| ram_replay_window | Highest-sequence plus seen bitmap, accepts unseen late numbers; no contiguous prefix or retransmission state |
| ordered_completion_buffer | Allocation/completion tags and ordered retirement; no feed/session request identity |
| ram_interval_set | Coverage union/subtraction metadata; no session lifecycle or request suppression |
| ram_sparse_assembler | Bounded immutable word collection/commit; no missing-message request control |
| prod_stream_sequence32 / prod_sequence_window32 | CE-qualified32-bit stream/modular sequence checks; no full64-bit recovery lifecycle |
| ITCH order state / pretrade_credit_ledger | Order-ID/quantity or account/ticket lifecycle; no network recovery |

Repository-wide production RTL/README/SPEC keyword searches for Mold,
retransmission, gap fill and re-request found only the strict receiver and
unrelated matches. The new function is persistent bounded recovery control,
not a renamed replay window, interval set, order book, credit ledger or payload
reorder buffer. The actual receiver/request serializer example supplies a
direct upstream/downstream composition without changing any existing source.

The integer representation avoids modular64-bit ambiguity. A65-bit hint sum
rejects ordinary overflow; heartbeat/EOF counts are distinguished before
addition. A280-bit BRAM-compatible row includes six zero pad bits and an
invariant check. One controller owns the private RAM and result; no speculative
read/modify/write, concurrent contexts or hidden timeout policy is introduced.
Scalar result/candidate registers duplicate only one row. Context resource
growth is linear and bounded; non-power-of-two index checking precedes slicing.
