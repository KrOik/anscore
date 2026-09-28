# Parameters and reset contract

| Parameter | Range / default | Meaning |
|---|---|---|
| `ADC_COUNT` | 1..16, 1 | Number of shared-bus devices |
| `CLK_HZ` | positive, 50 MHz | Input clock used for timing counters |
| `SCK_DIV` | non-negative, 1 | `fSCLK = CLK_HZ/(2*(SCK_DIV+1))` |
| `FIFO_DEPTH` | power of two, 512 | Synchronous sample FIFO entries |
| `OSR_SEL` | 0..7, 2 | ADS131M08 oversampling selection |
| `PWR_SEL` | 0..3, 2 | ADS131M08 power-mode field |
| `SCHED_DEFAULT` | 0..1, 0 | Round-robin or DRDY-priority scheduler default |
| `EXPECT_ID_DEFAULT` | 16-bit, `0801` | Expected device ID |
| `ADDR_W` | >=12, 12 | AXI-Lite byte-address width |

The current RTL is validated for `ADC_COUNT=1,2,4,16` in simulation and for
20K scalar bring-up at `ADC_COUNT=1`. Elaboration rejects invalid
`ADC_COUNT`, `FIFO_DEPTH`, `SCK_DIV`, `CLK_HZ`, `OSR_SEL`, `PWR_SEL`,
`SCHED_DEFAULT` and `ADDR_W` configurations. The boundary matrix covers the
minimum and maximum values of those fields independently, including the
minimum legal address width; the full cross-product parameter matrix remains
open as H-006.

Asynchronous assertion of `rst_n` clears control/status state. FIFO storage is
synchronous and is not reset element-by-element; the FIFO pointers define its
valid contents. `CTRL.W4` flushes the FIFO and clears overflow/drop counters.
No physical-board verification is claimed by this document.
