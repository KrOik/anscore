# gw2a_comm_uart_rx

UART receiver, 8N1, oversampling FSM (start/data/stop detection), framing-error
flag, valid/ack byte handshake.

- Core: `uart_rx` (`src/uart_rx.v`)
- Validated: selftest unit 0 (URX), digest `6BC47DCE`
- Board evidence: `doc/board_uart_*.txt` (COMM5 report on pin M11, COM24)

## Ports

| port | dir | width | note |
|---|---|---|---|
| clk | in | 1 | system clock |
| rst_n | in | 1 | active-low reset |
| clk_en | in | 1 | step enable; tie 1 for full rate |
| rx_pin | in | 1 | serial input (idle high) |
| rx_data | out | 8 | received byte |
| rx_valid | out | 1 | byte-ready strobe, held until rx_ack |
| rx_ack | in | 1 | consume strobe |
| framing_err | out | 1 | asserted when stop bit sampled low |

## Parameters

| name | default |
|---|---|
| CLK_FRE | 27 |
| BAUD_RATE | 115200 |

## Notes

- Bit timing derives from CLK_FRE (MHz) / BAUD_RATE; default 27 MHz -> 115200.
- `framing_err` accompanies the byte on `rx_data`/`rx_valid` for that frame.
- Independent golden: `tools/golden_model.py`.
- Receive sampling runs independently of `rx_ack`, permitting contiguous
  one-stop-bit frames. `rx_valid` asserts after the third stop-bit sample;
  it does not indicate that a companion transmitter has finished its stop bit.
- There is one output holding register, not a FIFO. Acknowledge before the
  next frame completes. On overrun, the unread byte and its framing flag are
  retained and the newly completed byte is discarded; no overrun pin exists.
- 2026-09-24 regression and physical LA evidence:
  `artifacts/ip_optimization_20260924/` at repository root. The dedicated
  stream image tests 32 contiguous internally generated frames with delayed
  acknowledgement, reporting `URX2 PASS N=0020`. This is internal loopback,
  not external RX-pad/cable validation.
