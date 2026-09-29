# gw2a_comm_spi_master

SPI master: CPOL/CPHA parameters, programmable SCLK divider, 1..32-bit
transfers (8/16/32 validated), `cs_n` framing, MSB-first.

- Core: `spi_master` (`src/spi_master.v`)
- Validated: selftest unit 1 (SPIM) vs LFSR loopback slave, digest `E4107F07`
- Board evidence: `doc/board_uart_*.txt` (COMM5 report on pin M11, COM24)

## Ports

| port | dir | width | note |
|---|---|---|---|
| clk | in | 1 | system clock |
| rst_n | in | 1 | active-low reset |
| clk_en | in | 1 | step enable; tie 1 for full rate |
| start | in | 1 | begin transfer |
| nbits | in | 6 | transfer length 1..32 |
| tx_data | in | 32 | MSB-first transmit word |
| rx_data | out | 32 | received word |
| busy | out | 1 | transfer in progress |
| done | out | 1 | transfer complete |
| sclk | out | 1 | SPI clock |
| mosi | out | 1 | master out |
| miso | in | 1 | master in |
| cs_n | out | 1 | chip select (active low) |

## Parameters

| name | default |
|---|---|
| CPOL | 0 |
| CPHA | 0 |
| SCLK_DIV | 4 |

## Notes

- Default mode 0 (CPOL=0, CPHA=0); sclk half-period = SCLK_DIV clk_en beats.
- `nbits` is 6 bits so 32 is representable; rx_data is MSB-first aligned.
- Wait for `done` to clear before pulsing `start` for the next transfer.
