# GW2A-18C validated crypto IP package

2026-09-24: AES composite-field optimization verified by equivalence,
256 random vectors, original board digest and 27 MHz full-rate ciphertext
capture. Isolated LUT1-4: 3,840 -> 2,276. See `aes128/README.md` and
repository `docs/IP_OPTIMIZATION_STATUS.md`; older evidence below is retained.

SHA-256 also optimized on 2026-09-24: shared word-loading/round shift path,
isolated LUT1-4 2,986 -> 2,465. SHA+CRC candidate now fits the 15K budget and
passes board digests. Full-rate 12-length digest/cycle capture also passes;
see `sha256/README.md` and the same ledger.

Cores: AES-128 ECB encrypt, SHA-256 streaming hash,
multi-mode byte-serial CRC. All passed iverilog sims and on-board
UART digest validation on GW2A-LV18PG256C8/I7 (27 MHz, uart_tx=M11
115200 8N1). Evidence: `../doc/board_uart_m01.txt`,
`../doc/board_uart_m1e.txt`, `../doc/utilization.txt`.
Note: the board UART stream was captured via an fx2lafw logic analyzer
on the uart_tx mirror pin (A11) because the host COM24/FTDI channel-B
path was dead on this machine (same deviation as dsp_20k). Raw LA
captures: `../build_oss/la_cap_m01.sr`, `../build_oss/la_cap_m1e.sr`;
0-byte COM24 attempt records kept in `../doc/board_uart_com24_*.txt`.

| IP | core | selftest unit | digest | board mask |
|---|---|---|---|---|
| `gw2a_crypto_aes128` | `aes128_core` | 0 (AESB) | 61C7D1CF | m01 |
| `gw2a_crypto_sha256` | `sha256_core` | 1 (SHAB) | 566ACEA2 | m1e |
| `gw2a_crypto_crc` | `crc_core` | 2/3/4 (CRC8/CR16/CR32) | FD957A4B/D0771E60/720D8B44 | m1e |
