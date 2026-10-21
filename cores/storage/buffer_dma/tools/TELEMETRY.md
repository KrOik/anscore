# Host telemetry decoder

Run after scripts/env.ps1:

```powershell
python cores/storage/buffer_dma/tools/decode_metrics.py --self-test
python cores/storage/buffer_dma/tools/test_frame_buffer.py
python cores/storage/buffer_dma/tools/decode_metrics.py capture.json --output decoded.json
python cores/storage/buffer_dma/tools/decode_metrics.py later.json --previous earlier.json
```

The integration test saves fixed0/fixed1_snapshot.json and decoded.json files
from actual simulated CSR reads of all 51 registers. Full-table readback checks
snapshot IDs before/after; response backpressure is exercised for every read.
The schema contains schema="buffer_dma_metrics_v1", source_kind="simulation"
or "board", nonempty epoch_id, clock_hz, captured=true, snapshot_id_before,
snapshot_id_after, 64-bit timestamp and exactly 51 unsigned 32-bit words. See
../csr_map.md for mapping. Transport must fill these fields from verified
readback and known clock/reset context. A source label is provenance supplied
by the caller, not independent proof of physical hardware operation.

Decode outputs frame/error totals, per-stream byte/stall/CRC/duration values,
memory transactions and slot latency statistics. Without a previous snapshot,
no bandwidth is inferred. Two snapshots from the same clock/reset/source epoch
produce per-stream accepted bytes/second from byte-count delta and timestamp
delta. These counts include malformed accepted input beats, so inspect errors.
No payload loss rate or sustained full-system performance claim is inferred.

Intervals must be positive and no longer than floor((2^32-1)/4) clocks, since
each byte counter may increment by four per cycle. Unsigned modulo subtraction
handles one counter wrap; longer intervals are rejected as ambiguous. Reset
epochs must be explicitly distinct. Elapsed-clock delta must match timestamp
delta, and byte deltas cannot exceed four per cycle. Unknown clock frequency,
incoherent IDs, uncaptured state and malformed dumps are rejected. Minimum
latency FFFFFFFF decodes as unavailable; latency sum remains modulo 32 bits,
so no potentially misleading average is calculated. Slot latency can include
simultaneous frame residence and is not a throughput denominator.

No physical capture backend is implemented by this decoder. JTAG transport,
board wrapper, physical P&R and 25K board acceptance remain separate work.
