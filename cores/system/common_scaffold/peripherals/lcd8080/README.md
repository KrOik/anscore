# 8080 parallel LCD transaction engine

`lcd8080_engine.sv` implements command/data writes and bidirectional reads on
an 8-bit or 16-bit 8080 LCD bus. Repository RTL searches for `8080`, `i80`,
`lcd_wr_n` and `lcd_rd_n` found no existing parallel LCD engine. Existing
`projects/spi_lcd_e203_20k/src/lcd_ctrl.v` and SPI transmitters are functional
SPI LCD drivers; `display/src/lcd_timing.v` generates display timing. Both
capabilities are preserved and differ from this asynchronous parallel bus.

## ABI

Single `clk`, synchronous active-low `rst_n`. `BUS_WIDTH=8` accepts 8 or 16;
`COUNT_W=16` accepts 1..24. `start_valid/start_ready` transfers only with CE=1.
The descriptor captures `read_mode` (1=read), `data_mode` (RS/DC pin),
`count[COUNT_W-1:0]` (number of bus beats), four 16-bit timing values and a
32-bit timeout. Count and every timing field must be nonzero; each timing
field accepts 1..65535 clocks. Invalid static/runtime configuration returns
error 1 without a bus cycle. One descriptor retains one direction and RS
value; submit a command descriptor followed by data descriptor(s) for DCS.
16-bit transfers are native words; 8-bit RGB565 requires MSB byte then LSB byte.
There is no implicit byte swapping or dummy read: represent required panel
dummy reads explicitly as extra beats and discard the corresponding host data.

Write beats use `tx_valid/tx_ready/tx_data[BUS_WIDTH-1:0]`. Read beats use
`rx_valid/rx_ready/rx_data/rx_last`. All host transfers require CE=1, including
DONE acknowledgment. READY itself does not imply CE. Producer data remains
stable until accepted. RX data and LAST remain stable under backpressure and
CE=0. `busy` covers every descriptor phase, including host waits.

Physical ports are active-low `lcd_cs_n/lcd_rd_n/lcd_wr_n`, `lcd_rs`,
`lcd_data_out`, `lcd_data_oe` and `lcd_data_in`. Top-level bidirectional I/O
buffers connect these to pads; this module deliberately exposes direction
instead of an internal fabric tri-state. No pin mapping or electrical level
translation is provided. Read data must meet synchronous sampling setup at
the end of RD-low; this is not an asynchronous-clock synchronizer.

Every accepted beat uses the captured timings:

1. `cfg_turnaround` clocks: CS/RD/WR high, data output disabled.
2. `cfg_setup` clocks: CS low, strobes high, write data driven or read high-Z.
3. `cfg_pulse` clocks: CS low and selected RD/WR low. Read captures input on
   the final low-pulse clock edge.
4. `cfg_hold` clocks: CS low, strobes high; direction and write data retained.

CS then deasserts and the data bus releases. Burst beats preserve ordering,
with a complete CS-separated physical cycle and turnaround for every beat;
this is a transaction engine rather than a gapless continuous-CS streamer.
CE affects host requests only and never stretches an active physical stage.
RX backpressure and absent TX data leave the physical bus released. Configure
timings in clocks using the actual panel datasheet and clock frequency.

## Completion, timeout, abort and reset

`done_valid` and `error_code[7:0]` hold until CE-qualified `done_ready`;
codes are 0 success, 1 invalid configuration, 2 timeout, 3 abort.
`cfg_timeout=0` disables timeout. Nonzero timeout counts wall-clock cycles
from descriptor acceptance, including TX/RX waits and CE-off clocks. It is
an error detection deadline, not permission to truncate physical strobes.
Abort is a CE-qualified request. If either occurs after a beat begins
turnaround, that beat completes setup/pulse/hold before error completion;
no subsequent beat is issued. First detected cause remains sticky; abort
wins when abort and timeout are first detected on the same cycle.

Once RX_VALID is exposed, abort/timeout cannot withdraw it. The error remains
pending, the token stays stable until CE&&RX_READY, and DONE(error) follows
that acceptance. Thus timeout completion can wait indefinitely for host RX
drain. A read whose error occurred before RX exposure is discarded at hold
completion. Reset overrides CE, cancels even an active pulse or exposed RX
token, immediately releases the bus on the reset clock and returns to idle.
Reset is the sole deliberate physical waveform cancellation mechanism.

## Validation

From repository root:

```
python -B cores/system/common_scaffold/peripherals/lcd8080/test_case.py
python -B cores/system/common_scaffold/peripherals/lcd8080/test_lcd8080.py
python -B cores/system/common_scaffold/peripherals/lcd8080/test_boundaries.py
python -B cores/system/common_scaffold/peripherals/lcd8080/test_parameters.py
python -B cores/system/common_scaffold/peripherals/lcd8080/synth.py
```

CASE is a narrow 8-bit four-beat command/write/read test. The full pin-only
panel BFM checks 8/16-bit independent bus waveforms, setup/pulse/hold duration,
turnaround high-Z, direction, command/data RS, TX data, RX sampling, LAST,
host backpressure and CE gaps. It never inspects DUT FSM or counters.
Each width covers 28 descriptors, including timeout/abort under RX stall,
CE-off RX drain rejection, timeout/abort during active pulses, invalid runtime
fields, held DONE, restart and normal read/write bursts. The independent DCS
panel parses actual 2A/2B address bytes and 2C pixel payload to verify an entire
8x6 RGB565 frame; 8-bit mode reconstructs pairs of bytes. Full profiles observe
165/117 physical beats and 48 image pixels per width.

Boundary tests check all four timing fields at 65535, active-pulse reset,
exposed-RX reset, CE-off abort rejection, captured configuration, first-error
retention and abort while waiting for TX. Parameter tests cover four illegal
profiles and legal COUNT_W extremes 1/24. Separate isolated Gowin synthesis
uses 426 LUT-class cells at width8/count16 and 437 at width16/count24, with
0 DSP and 0 BRAM. These are pre-route resource results, not board timing or
panel electrical compliance. No hardware/PHY validation is claimed.

`references.json` records actual fetched source bytes/SHA256 and excerpts for
Espressif ESP-IDF v5.4.1 I80 driver and Adafruit TFTLCD's mature parallel LCD
command/read/window code. `fetch_references.py` repeats these memory-only
downloads. RTL and BFM are original, not copies of either driver. Simulator,
generated testbench and synthesis intermediate files use automatically cleaned
C: temporary directories; only small logs and source-bound reports remain.
