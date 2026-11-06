# B49 finite qualification

Current evidence: core LINT_PASS + UNIT_SIM_PASS; composed residual encoder
UNIT_SIM_PASS + INTEGRATION_CANDIDATE. Both remain HW_UNVERIFIED.

The independently reviewed one-shot plan ran once. All15 children passed:
four numerical preparations, three Icarus syntax checks, four testbench
compiles and four finite simulations. There were no failed or timed-out
children, termination helpers or retries. The [receipt](reports/20261106T181832559017Z/results.json)
has SHA256 `a414acd84e3f3787a5f6cceaa56e2f689861b72b9f8ec872272e490b848c175f`.

| Profile | Codes × dimensions | Tag bits | Query responses | Replay/encoded components | Reset pulses |
| --- | --- | --- | --- | --- | --- |
| Tiny core | 1 × 1 | 1 | 31 | 20 | 13 |
| Ragged core | 3 × 5 | 8 | 33 | 57 | 13 |
| Maximum core | 64 × 256 | 32 | 33 | 2,316 | 13 |
| Residual encoder | 16 × 16 | 8 | 35 | 158 | 14 |

The132 query responses include valid results and specified errors. There
were17,832 configuration responses,2,551 replay/encoded components,43,878
held-output checks and53 reset pulses. Tests cover deterministic ties, a
unique winner in the last row, full-vector distance16,646,400, signed residual
extremes, RNE ties/clipping, prefix shortening and recovery, invalid commands
and configuration writes, input gaps, held configuration/summary/replay,
configuration priority, resets in five active phases, and overlapping old
encoded output with a new query using a different shift/tag.

Four original VVP images remain in the ignored .work directory. All15 children
have distinct immutable initial, terminal and validated JSON records. Each
simulation's initial record includes its checked image SHA and prechecked
flag, durably written before Popen by the reviewed runner. Raw streams,
16 current/archive source pairs and26 pinned tools were rechecked after
execution. [POST_ROOT_AUDIT.json](POST_ROOT_AUDIT.json) records the root audit;
[POST_PEER_AUDIT.json](POST_PEER_AUDIT.json) records the independent153-file
post-execution audit. Root rehashed all153 listed files again after readback.

Syntax checks are finite Icarus compilation checks. No synthesis, PnR, STA,
board test, PPA or historical regression ran. The maximum simulation's
1.125-second host runtime and567,279 testbench clocks are simulator evidence;
no FPGA frequency, power, device fit or application accuracy is established.
