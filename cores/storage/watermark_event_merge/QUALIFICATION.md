# B43 finite qualification

PASS: the sole approved attempt completed 3 archived numerical-preparation children and 11 HDL children, with 4 successful simulations and no retry, failure or repair. Hardware remains HW_UNVERIFIED. The receipt is `reports/20261106T094526734115Z/results.json` (SHA256 `d1914d7309d7709ab6553387ff6800ce3e36033f832297a336b92575417ac1cc`).

The reviewed pending plan `07dba1746c29cea0ba4c8ce10ea4814d69a21c94a13c825a82b0362e1c6f4e82` differs from approved plan `81beec0a64374e3ae4cbcc53236c8c081a48ac58ce536f725954ad5f70a14aa1` only in `source_review`; exact byte reversal is recorded in `planning/APPROVAL_TRANSITION.json`. All17 executed inputs and archived copies,3 tool binaries,14 process records,28 raw streams,3 vector/summary pairs and4 compiled images were independently checked from saved evidence without importing project code.

| Profile | Commands | Held cycles | Actual future offers | Actual future GETs | Resets |
|---|---:|---:|---:|---:|---:|
| f1_d8_t1 | 625 | 3750 | 619 | 245 | 6 |
| f3_d128_t8 | 955 | 5730 | 949 | 370 | 6 |
| f8_d512_t32 | 1780 | 10680 | 1774 | 659 | 6 |

Core totals: 3360 commands, 20160 held cycles, 3342 actual future offers, 1274 future GETs and 18 resets. Each profile reached all five live reset phases. The real two-decoder composition checked 9 packets, 7 merged events, 10 admin results, 65 held cycles, 2 actual future requests, 4 resets and 1 canceled held event.

Icarus emitted inherited/missing-timescale warnings in syntax and compilation logs; all exact warnings are retained in EVIDENCE_AUDIT.json. No synthesis, placement/routing, STA, board, PPA or inherited regression was run. All four compiled images are retained outside the formal Git package; no cleanup was attempted.

- Finite syntax and simulation qualification only; synthesis, placement/routing, timing, board and PPA are not run.
- One serialized owner remains active through response retirement; first-result-valid source bound is 8*FEEDS+24 cycles, excluding initial reset erasure and output stalls.
- Inclusive watermark W promises future accepted timestamps >=W; an empty open feed releases candidate t only with W>t, so equality intentionally blocks.
- The caller supplies truthful explicit watermark/EOS promises; packet completion, heartbeat and absence do not prove event-time completeness or repair packet loss.
- Reset cancels the complete epoch, including a claimed but unretired event; backend inconsistency sticky-invalidates without rollback.
- Legal timestamp and sequence domains are full unsigned64, feed validation is full unsigned32, and payloads are preserved; finite profiles do not prove every legal input/state.
