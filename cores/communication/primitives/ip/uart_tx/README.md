# gw2a_comm_uart_tx

UART transmitter, 8N1, valid/ready handshake, busy flag. Reused verbatim from
the cnn_systolic_20k template; drives the COMM5 report on pin M11.

- Core: `uart_tx` (`src/uart_tx.v`)
- Validated: UART report path, `tb_top_uart_report` PASS (544/544 bytes)
- Board evidence: `doc/board_uart_*.txt` (COMM5 report on pin M11, COM24)

## Ports

| port | dir | width | note |
|---|---|---|---|
| clk | in | 1 | system clock |
| rst_n | in | 1 | active-low reset |
| tx_data | in | 8 | byte to send |
| tx_data_valid | in | 1 | byte strobe |
| tx_data_ready | out | 1 | accepts a byte |
| tx_pin | out | 1 | serial output (idle high) |
| tx_busy | out | 1 | frame in flight |

## Parameters

| name | default |
|---|---|
| CLK_FRE | 27 |
| BAUD_RATE | 115200 |

## Notes

- No `clk_en` port (core runs at full clock rate).
- Deassert `tx_data_valid` once `tx_data_ready` accepts, or the byte re-sends.
