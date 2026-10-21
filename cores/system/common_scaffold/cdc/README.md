# CDC / reset framework

Three minimal functional modules; no board, metastability-rate, timing-constraint
or independent-reset qualification is claimed. `run_tests.py` runs Icarus against
two independent clocks (10 ns / 14 ns), 48 ordered payloads, stalls and CE pauses.

* `cip_bit_sync`: two or more flip-flops for ONE slow asynchronous level. CE
  pauses the synchronizer. Not for a multi-bit bus or short pulses.
* `cip_reset_sync`: asynchronous assertion, release after STAGES clock edges.
  No CE by design: reset release must not depend on a paused datapath enable.
* `cip_cdc_mailbox`: single outstanding bundled-data word, four-phase req/ack,
  payload registered one source beat before request. Source/destination each
  use their own CE. Transfers are `local_ce && valid && ready`. Both domains
  MUST share reset. Independent-reset or missing-clock recovery is not supported.

Future integration must supply clocks/constraints and a CDC structural review;
the included simulation cannot model metastability. Payload must remain stable
for the documented handshake. No asynchronous coefficient-memory array is used.

From repository root:

```powershell
python cores/system/common_scaffold/cdc/run_tests.py
```
