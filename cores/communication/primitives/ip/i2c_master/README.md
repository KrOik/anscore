# gw2a_comm_i2c_master

I2C master: start/stop, 7-bit addressing, multi-byte read/write, ACK/NACK,
clock-stretch tolerant. Open-drain SDA/SCL via `*_oe` outputs: drive the pin
low when `oe=1`, release (Hi-Z + pull-up) otherwise.

- Core: `i2c_master` (`src/i2c_master.v`)
- Validated: selftest unit 2 (I2CM) vs internal slave model, digest `D6A89792`
- Board evidence: `doc/board_uart_*.txt` (COMM5 report on pin M11, COM24)

## Ports

| port | dir | width | note |
|---|---|---|---|
| clk | in | 1 | system clock |
| rst_n | in | 1 | active-low reset |
| clk_en | in | 1 | step enable; tie 1 for full rate |
| start | in | 1 | begin transaction |
| addr | in | 7 | 7-bit slave address |
| rw | in | 1 | 0=write, 1=read |
| len | in | 5 | data byte count 1..16 |
| tx_data | in | 8 | write byte |
| tx_valid | in | 1 | write byte valid |
| tx_ready | out | 1 | master wants next write byte |
| rx_data | out | 8 | read byte |
| rx_valid | out | 1 | read byte strobe |
| rx_ack | in | 1 | consume read byte |
| busy | out | 1 | transaction in progress |
| done | out | 1 | transaction complete |
| nack | out | 1 | slave NACK observed |
| sda_in | in | 1 | SDA pad input |
| scl_in | in | 1 | SCL pad input |
| sda_oe | out | 1 | drive SDA low when 1 |
| scl_oe | out | 1 | drive SCL low when 1 |

## Parameters

| name | default |
|---|---|
| QDIV | 64 |

## Notes

- Bit time = 4*QDIV clk_en beats; QDIV=64 at 27 MHz ~= 105 kHz.
- Clock stretching: the master waits for scl_in high after releasing SCL.
- `nack` latches until the next transaction start.
