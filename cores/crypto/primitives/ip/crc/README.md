# gw2a_crypto_crc

Byte-serial CRC engine, runtime mode select: CRC-8/SMBUS(0x07), CRC-16/CCITT-FALSE(0x1021), CRC-32/ISO-HDLC(0x04C11DB7 refl).

## Ports

| port | dir | width | note |
|---|---|---|---|
| clk | in | 1 | posedge clock |
| rst_n | in | 1 | active-low async reset |
| clk_en | in | 1 | step enable, tie 1 for full rate |
| mode | input | 2 | 0=CRC-8, 1=CRC-16, 2=CRC-32 |
| init | input | 1 | pulse 1 clk_en beat: load per-mode init |
| din | input | 8 | message byte |
| din_valid | input | 1 | one byte consumed per beat |
| crc_out | output | 32 | running/final residue, xorout applied |

## Validation
- selftest unit(s): 2/3/4 (CRC8/CR16/CR32), FNV-1a digest FD957A4B/D0771E60/720D8B44
- board bitstream mask: m1e
- UART evidence: `../../doc/board_uart_m1e.txt`
- golden: `tools/golden_model.py` (independent models)
