# Bounded synchronous measurement replay

`rtl/lockin_replay.v` owns the virtual ADC and lock-in core. One command
starts both; success requires both to finish with no error. Results remain
stable until acknowledgement. A failed run returns zero measurement data,
an explicit error, cycle count and source counters. No automatic retry occurs.

Error bits 0..4 are the core timestamp/cadence/calibration/CORDIC/configuration
flags; bit 5 is invalid ADC configuration, bit 6 ADC overflow, bit 7 timeout.
Timeout zero rejects without launch. Timeout N expires after exactly N run
clocks. Timeout wins over completion on the same clock. Abort discards pending
samples and resets the core, preserving the source timestamp epoch; global
reset clears that epoch. Aborted counter snapshots can include discarded
in-flight samples, so generated need not equal accepted plus dropped.

`sample_allow` permits intentional starvation tests. It must be tied high in
normal operation. The source never slows scheduled sample ticks to accommodate
backpressure; overflow is a failed measurement.

`rtl/lockin_config.v` wraps the unchanged canonical 16-word atomic configuration
bank. Shadow writes support byte strobes; a commit includes a same-edge write.
An applied version produces one held command until accepted. Another commit
may queue while busy, but neither active configuration nor version changes
until `idle` is true and the previous command has been accepted. The owner must
assert `idle` only when no measurement or unacknowledged result exists.
The adapter is transport neutral; CSR address decoding and field mapping are
not yet implemented. Every applied version triggers one operation, including
a commit containing identical data. Version zero after reset does not launch.

Offline commands (after `. ./scripts/env.ps1`):

```
python cores/signal_processing/lockin/tools/test_replay.py
python cores/signal_processing/lockin/tools/test_live.py
python cores/signal_processing/lockin/tools/test_config.py
```

Replay regression checks five successful exact-I/Q runs, five explicit error
completions, held results, recovery, monotonic timestamps across soft abort,
and global reset. Configuration regression checks same-edge commit, command
stall, deferred snapshot, byte masks, pending write rejection, exactly-once
launch and reset. These are digital simulations, not 25K board acceptance.
