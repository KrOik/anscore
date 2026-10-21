# SPI NOR Flash transaction controller

`spi_nor_flash.sv` fills a missing flash-specific controller layer. Existing generic SPI/QSPI cores accept low-level byte/opcode requests; this module implements NOR transaction semantics, page limits, automatic WREN/WEL checks, sector alignment and bounded WIP polling. It is a single-clock, single-lane, MSB-first, 24-bit address controller for standard SPI modes0 and3. Quad/QPI,4byte addresses, bank/extended-address registers, SFDP discovery, protection-register changes, deep-power-down, erase-suspend and vendor error flags are outside this interface. The device must already be in standard SPI,24bit addressing mode.

## Host command contract

A descriptor handshakes on `cmd_valid && cmd_ready`; fields remain stable until acceptance. One command is outstanding until its response is consumed and the chip-select high cooldown has expired. `ce` gates only new command admission. Accepted W/R/response handshakes and all pin activity continue when ce=0. `abort` also prevents admission. All streams use independent valid/ready; a stalled read byte remains stable until accepted, timeout, reset or abort. Preload requires exactly `cmd_length` W bytes; excess W bytes are not accepted. No WLAST is used.

| cmd_op | Operation | cmd_length | Wire command |
|---|---|---|---|
|0|JEDEC ID|3|9f +3bytes|
|1|Read|1..256|03 +24bit address +data|
|2|Fast read|1..256|0b +24bit address +8dummy clocks +data|
|3|Page program|1..256, within one256byte page|06;05(WEL);02 +address +data;05 polling|
|4|4KiB sector erase|0, address aligned4096|06;05(WEL);20 +address;05 polling|
|5|Write enable|0|06;05(WEL)|
|6|Read status|1|05 +1byte|
|7|Poll WIP until clear|0|repeated05 +1byte|

ID/read/fastread first read status and fail if WIP is set. Program/erase/WREN send the harmless WREN command before checking WIP/WEL; a busy compliant NOR ignores WREN, and the following status yields BUSY. Program buffers its entire payload in synchronous RAM before issuing WREN, so preload starvation never launches a partial program. Program bytes are sent in order under one CS assertion. The controller never splits page-crossing requests or wraps24bit reads. Sector erase addresses must be aligned. Read data and JEDEC/status bytes use the R stream; program/erase/WREN/poll have no R payload. Final `rsp_status` is the last sampled status byte.

`rsp_bytes` counts accepted R bytes for reads,3 for completed ID,1 for completed status, the requested length for a program whose WIP completed, and0 for erase/WREN/poll. A failed/aborted program reports0 and may have changed flash; this is not a rollback or verified-program count. Response fields remain stable under rsp backpressure, irrespective of ce or abort. Read status/WIP cannot prove a protected/failed program changed data; application readback verification is required where needed.

## Errors, abort and reset

| rsp_error | Meaning |
|---|---|
|0|Completed|
|1|Invalid descriptor/opcode/address/length/alignment|
|2|HOST_TIMEOUT clocks without W preload or R consumption|
|3|POLL_LIMIT status samples all report WIP|
|4|WEL not set after WREN|
|5|Device busy at admission status check|
|6|Aborted active command|

A W/R handshake on the final permitted timeout cycle takes priority over timeout. Timeout counts continuous host inactivity separately for each byte, not total serial duration. Poll limit counts completed status samples, not raw clock cycles. Invalid descriptors cause no pin transaction. Abort of active work deasserts CS and cancels the byte engine at that clock, restoring SCLK to CPOL, discarding a held R byte and preserving already accepted R-byte count. An R handshake visible at the same clock as abort is counted, while the terminal response remains ABORT. Abort while a completed response is held leaves that response unchanged. Reset is synchronous active-low, drops controller work/outputs, restores CS high and SCLK idle, and clears host response state. Flash internals are not reset. Abort/reset after program/erase CS release cannot cancel device-internal mutation; WIP may remain set. Readiness polling or external recovery is then required.

## Timing parameters

CLOCK_DIV1..65535 gives each SCLK half-cycle that many system clocks. SPI_MODE is0 or3 (CPOL=CPHA=0 or1). CS_HIGH_CYCLES1..65535 is enforced between all transactions and after abort/error/reset before new admission. HOST_TIMEOUT and POLL_LIMIT are positive signed32bit integers (1..2147483647). Defaults are divider2, mode0, CS high4, host timeout4096 and poll limit1024. At50MHz system clock, default CS high is80ns and SCLK is12.5MHz. Select actual parameters from the flash datasheet; ideal simulation at high1/div1 does not claim electrical compliance. SCLK may pause at its idle level between bytes while CS remains asserted; device and host must support this standard SPI behavior. There is no clock stretching, bus arbitration, or CDC synchronizer; MISO must meet sampling timing at the FPGA pin.

## Validation and resources

```powershell
python -B cores/system/common_scaffold/peripherals/spi_nor_flash/run_tests.py
python -B cores/system/common_scaffold/peripherals/spi_nor_flash/run_synthesis.py
```

The separate `nor_device_model.v` interprets physical CS/SCK/MOSI edges, implements64KiB of byte storage, NOR1-to0 program semantics, page wrap behavior, WEL/WIP and delayed completion. It does not access controller state. A separate host shadow-memory scoreboard checks readback, bitwise repeated programming, sector isolation, full256byte pages, fast-read dummy cycles and high24bit address serialization. Eight mode/divider/CS profiles run65 transactions each, including twelve varying pages, randomized host CE/data gaps/backpressure, descriptor errors, preload/R timeout, WIP timeout, WEL refusal, busy-device refusal, deadline-handshake precedence, abort while a physical byte/held R/held response is active, staged-request reset and post-error recovery. Eight invalid parameter declarations are rejected. This is ideal digital simulation, not flash endurance or board evidence.

Actual Gowin synthesis with `check -assert`: default778 LUT-class /0DSP /1BRAM; maximum declared timing/count parameter configuration808 LUT-class /0DSP /1BRAM. The256byte preload buffer infers synchronous block RAM. Pinned public opcode/driver sources with SHA and inspected excerpts are recorded in `references.json`. No external RTL is copied. All simulation binaries/netlists/download buffers use auto-cleaned C: temporary storage. Shared registration, placement/routing, timing closure and hardware integration are parent-owned.
