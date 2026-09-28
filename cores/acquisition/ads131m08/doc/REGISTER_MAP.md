# Register map

All addresses are byte offsets for 32-bit single-beat accesses.

| Offset | Name | Access | Meaning |
|---:|---|---|---|
| 0x000 | CTRL | RW | soft reset, start init, enable, clear errors/FIFO, resync |
| 0x004 | STATUS | RO | count, SPI/init/config status, current device |
| 0x008 | SCHED | RW | scheduler mode and device enable mask |
| 0x00C | ERR | RO | sticky per-device, overflow, timeout, unmapped errors |
| 0x010 | IRQ_EN | RW | interrupt enables |
| 0x014 | IRQ_STATUS | RW1C | pending enabled errors |
| 0x018 | CFG0 | RW | OSR and power mode |
| 0x01C | CFG1 | RW | expected device ID |
| 0x020+4n | DEV_CTRL[n] | RW | per-device enable/resync |
| 0x060+4n | DEV_STATUS[n] | RO | init, ID, config, DRDY and timeout state |
| 0x100+4n | DEV_ID[n] | RO | read-back device ID |
| 0x140+4n | DEV_SAMPLES[n] | RO | frame counter |
| 0x180/184/188 | GAIN1/GAIN2/MODE | RW | raw device configuration values |
| 0x200 | FIFO_DATA | RO | Low 32 bits of the most recently popped beat |
| 0x204 | FIFO_STATUS | RO | FIFO level, full and empty flags |
| 0x208 | DROP_COUNT | RO | Number of samples dropped while full |

Unmapped reads return `DEADBEEF` as a side-effect-free diagnostic. Unmapped
writes set the sticky unmapped-access error at `ERR[18]`. `CTRL.W3` clears the
software-visible error latches, while `CTRL.W4` flushes the FIFO and clears its
overflow/drop state. The AXI response remains `OKAY` for compatibility;
changing that behavior requires a new regression and a H-005 update.
