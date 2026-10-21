# SD-SPI register and protocol contract

`rtl/common_sd_spi.v` implements an SD version 2 SPI host through the native 32-bit command/response port. It instantiates `common_serial_spi_byte.v` and uses SPI mode 0, MSB first. Addresses below are byte addresses. No broad board top or build script changes are required.

The serial engine runs on every physical `clk` edge, including while `clk_en=0`. `clk_en` gates CSR command acceptance and response consumption only. Responses stay stable until `clk_en && rsp_ready`. There is one outstanding CSR request; a buffer read adds a synchronous RAM-read cycle. Command responses acknowledge the CSR operation; software polls STATUS for completion of card operations.

| Address | Access | Meaning |
| --- | --- | --- |
| `00` | R | STATUS: busy bit 0, initialized bit 1, high-capacity addressing bit 2, live card_present bit 3, sticky completed bit 4, engine error bits 15:8, most recent R1 bits 23:16. Other bits zero. |
| `04` | W | CONTROL: 1 initialize, 2 read one block, 3 write one block, 4 send custom command, 8 abort. Values are exact integers, not independent command bits. |
| `08` | RW | ARGUMENT: logical block number for block operations; raw 32-bit argument for custom commands. |
| `0c` | RW | RAW_COMMAND: command index bits 5:0; response class bits 9:8: 0 R1, 1 R1b, 2 R2, 3 R3/R7. Reserved bits must be zero. |
| `10` | R | Up to four additional response bytes, shifted in wire order. R2 occupies bits 7:0. R3/R7 occupies all 32 bits. R1 is always in STATUS. |
| `14` | RW | BUFFER_INDEX: 0..511, automatically incremented modulo 512 after a successful BUFFER_DATA access. |
| `18` | RW | BUFFER_DATA: one byte in bits 7:0. A read uses synchronous RAM. Write ignores upper 24 bits. |
| `1c` | R | Received block CRC16 bits 31:16; calculated block CRC16 bits 15:0. Received value is meaningful after a block read. |
| `24` | R | Number of successfully completed block reads/writes since reset, modulo 2^32. Raw commands do not increment this count. |
| `28` | R | OCR from the most recent initialization CMD58. |
| `2c` | RW | SPI half-period in physical clock cycles, nonzero. Reset value max(1, CLOCK_DIV). |

`rsp_error=0` means accepted/read succeeded, 1 means invalid address/value, 2 means busy, unavailable/invalid buffer byte, incomplete write buffer, or invalid block-operation state. Unsupported register accesses return a finite error. Failed buffer reads return zero and leave BUFFER_INDEX unchanged. While a card operation is running, software may read status/metadata, but buffer accesses and configuration writes are rejected. Abort is always accepted. Invalid configuration writes do not launch a card transaction.

CONTROL clears completed/error on an accepted start. Successful asynchronous completion sets completed and clears busy. Completed remains set until the next accepted start/reset. Engine errors: 0 success, 1 card removed/absent, 2 response/token/busy/init retry timeout, 3 unexpected R1, 4 invalid CMD8/OCR response or unsupported card generation, 5 read data error token, 6 read CRC mismatch, 7 card rejected write data, 8 incomplete write buffer or software abort. Custom commands preserve their exact R1/R2 response for software interpretation rather than treating every legal card-reported R1 status as an engine failure.

Initialization transmits 80 clocks with CS high, CMD0, CMD8 with 0x1AA check, repeated CMD55/ACMD41 with HCS, and CMD58 with voltage/busy checks. SDHC/SDXC uses logical block addressing. Version-2 SDSC uses CMD16 to set a 512-byte block length, and logical block numbers are converted to byte addresses. SDSC block numbers above 0x7FFFFF are rejected before shifting. Version-1 SDSC and MMC are explicitly rejected at CMD8; they are not silently claimed compatible. Firmware must wait for card power to stabilize before initialize, and choose a half-period that keeps initialization SCLK at or below 400 kHz. The host may increase the divider register's speed after initialization within the card/board's supported rate; frequency is `Fclk/(2*half_period)` during active bytes.

Every command transmits calculated CRC7, including CMD0 and CMD8. A read uses CMD17, waits for FE, receives exactly 512 bytes and validates the polynomial-0x1021 CRC16. A write uses CMD24, FE, exactly 512 bytes and calculated CRC16, validates the data-response token, and polls card busy until FF. CS remains asserted through command/data/busy, then the host supplies one idle byte with CS deasserted. Custom commands implement the selected response/busy phase only, with no generic custom data phase. Raw data commands are therefore not substitutes for CONTROL=2/3. Custom commands which reset/reconfigure card state require software to reinitialize before subsequent block operations.

The 512-byte data array is never reset, allowing synchronous block-memory inference. A separate 512-bit validity mask rejects uninitialized buffer reads and incomplete writes without exposing X values. Software may fill bytes in any order; all 512 bytes must be valid before CMD24 starts. Beginning a block read invalidates old buffer contents; failed/aborted/removed reads invalidate the entire buffer. A successful read publishes the complete block. Removal always invalidates initialization and immediately aborts an active serial operation; the board must synchronize/debounce `card_present` before this interface. `sd_miso` is sampled at generated SCLK edges by the synchronous SPI byte engine.

`RESPONSE_TIMEOUT_TICKS` bounds polling bytes, with minimum one byte. Each response, read-token wait, write-response wait and busy wait has a fresh bounded count; initialization also bounds its ACMD41 retry count. Thus a byte timeout is approximately `timeout * 16 * half_period` host cycles plus a small FSM overhead. There is no unbounded card busy wait.

A typical transaction is: initialize and poll STATUS; fill BUFFER_INDEX/DATA for a write (or start read); set ARGUMENT to the logical block number; write CONTROL=2/3; poll busy until zero; require completed=1 and error=0; read buffer bytes after a successful read.

## Development check

From the repository root:

```powershell
. .\scripts\env.ps1
iverilog -g2012 -s tb_common_sd_spi -o cores/system/common_scaffold/peripherals/sd_spi_test.vvp cores/system/common_scaffold/peripherals/rtl/common_serial_spi_byte.v cores/system/common_scaffold/peripherals/rtl/common_sd_spi.v cores/system/common_scaffold/peripherals/sim/tb_common_sd_spi.sv
vvp cores/system/common_scaffold/peripherals/sd_spi_test.vvp
```

The independent SPI-pin SD model checks command CRC7, SDHC and version-2 SDSC initialization/addressing, a complete 512-byte read and write, transmitted/received CRC16, R2/R1b raw responses, malformed read CRC, finite no-response timeout, removal, buffer-validity errors and physical-clock progress with CSR CE low. Expected marker: `PASS SD SPI:`. This is a code-development simulation; no physical card, timing closure, resource synthesis or filesystem support has been claimed.
