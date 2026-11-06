# SoupBinTCP session receiver delivery

The formal executable entry is `followup01/files.f`, with top
`soupbintcp_session_rx`. It compiles `followup01/rtl/soupbintcp_session_rx.sv`
and the original private `rtl/deps/soup_rx_axis_fifo.v`; there is no alias wrapper.
The original `rtl/soupbintcp_session_rx.sv` and `files.f` are retained failed
historical inputs and are not canonical executable sources. The corrected core
moves only the existing `start_error` declaration before its first use.

The independently reviewed followup passed exactly nine HDL children: three syntax
checks, three compilations and three simulations, with zero new preparations.
Its receipt is `followup01/reports/20261106T132915604239Z/results.json`.
All nine recorded target PIDs exited0, completed raw capture and stayed within the
20-second execution budget. No timeout or cleanup helper occurred. Six frontend
records retain a missing-timescale warning; simulation stderr is empty. This is a
finite syntax/unit simulation qualification, not warning-free lint or hardware proof.

| FIFO depth | Tag bits | Protocol cases | Checked completions | Payload bytes |
|---:|---:|---:|---:|---:|
| 32 | 1 | 48 | 56 | 70 |
| 128 | 8 | 48 | 56 | 166 |
| 4096 | 32 | 48 | 56 | 4134 |

Each simulation checks real upstream FIFO commit/rollback, login/sequence fields,
maximum sequence exhaustion, ignored debug, terminal/fatal drain rules, capacity,
held outputs, two genuinely held future frames, cancellation and recovery probes.
Each profile reports40 resets,4 cancellations and4 recoveries. Coverage remains
limited to these finite cases and this already reassembled ordered byte interface.

The original attempt remains intact at `reports/20261106T131548185120Z/results.json`:
one successful preparation (one oracle import/preparation) followed by one failed
syntax child, exit2, caused by declaration order. It launched no simulation.
The followup reused all three vector files at their original paths and exact hashes;
there was no regeneration or automatic retry. Both attempts' inputs, archives,
controls, raw streams, receipts and original execution images remain retained.

A read-only SHA256/byte-length audit matched59 current/archived followup bindings,
18 original source/archive pairs, both attempts' controls and guards,24 followup
runtime/tool bindings,3 reused vectors and their preparation receipt,3 compiled/
executed images,11 per-child records and22 raw streams. `QUALIFICATION.json` records
the exact hashes, terminal PIDs, counters and limits. The original
`QUALIFICATION.md` remains frozen and is a historical source-review document.

Maturity: LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED.
Synthesis, PnR, STA, board and PPA are NOT_RUN. No TCP stack, production network,
line-rate throughput or physical timing result is claimed. Parent licenses and
upstream provenance remain applicable and unchanged.
