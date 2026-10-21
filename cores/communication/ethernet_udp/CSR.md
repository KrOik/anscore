# UDP replay CSR contract

`udp_control` is transport neutral, using8-bit byte addresses,32-bit words,
four write strobes and one outstanding valid/ready request/response. Response
data/error remain stable under stalls. Unaligned, undefined or disallowed
accesses return an error without the requested side effect. Reset clears
configuration/version, pending work, result and replay ownership.

| Address | Access | Meaning |
|---|---|---|
| 00 | R | Magic55445031 (`UDP1`) |
| 04 | R | bit0 replay ready,1 result held,2 pending commit,3 commit ready,4 unaccepted command |
| 08 | R | Applied configuration version |
| 0c | W | Commit and launch once; full strobes/value1 |
| 10 | W | Acknowledge held completion; full strobes/value1 |
| 14,18 | R |64-bit build fingerprint low/high |
| 40..5c | RW | Byte-masked shadow writes; active configuration reads |
| 80 | R | Completed run ID |
| 84 | R | Replay terminal error (REPLAY.md) |
| 88 | R | Active replay cycles |
| 8c,90 | R | Paired TX completions, validated RX packets |
| 94,98 | R | Submitted TX payload bytes, accepted RX payload bytes |
| 9c,a0 | R | Complemented cumulative TX/RX CRC32 (zlib convention) |

Result addresses require a held completion, including failed runs. Reads do
not clear the result; only ACK consumes it. Results remain coherent across
all reads until ACK. The run ID is latched when the command starts, so a
queued run cannot change a held result's identity.

Configuration words `(address-0x40)/4`:

| Index | Meaning |
|---|---|
| 0 | Low16 packet count1..65535; high16 payload length4..1472 |
| 1 | Seed for deterministic data/stalls |
| 2 | Timeout active clocks, nonzero |
| 3 | Low2 fault flags; other bits ignored |
| 4 | Arbitrary32-bit run ID |
| 5..7 | Reserved storage, no operational effect; write zero |

The unchanged canonical `sys_atomic_config` captures a commit snapshot,
including a same-edge byte write. Active values are frozen while replaying
or holding a result. One commit may queue. Further writes/commits while
pending fail. After result ACK, the snapshot applies and its version change
starts exactly one operation. Identical-data commits also start one operation;
reset version0 does not start anything. Active readback during a queued commit
returns the previous run's configuration.

Probe bits7..0: error-present, result-held, pending-commit, looped-TX-enable,
looped-TX-dibit1, looped-TX-dibit0, command-valid, replay-ready. These levels
are debug observations, not a substitute for numerical CSR acceptance.

```
. ./scripts/env.ps1
python cores/communication/ethernet_udp/tools/test_control.py
```

Actual CSR->atomic configuration->UDP/RMII replay is exercised with response
stalls, partial byte writes, a queued configuration during running work,
pending write/commit rejection, frozen active readback, complete counter/CRC
readback, held ID/result, invalid timeout and explicit ACK. Python independently
computes expected per-run CRC32. No physical transport backend is tested here.
