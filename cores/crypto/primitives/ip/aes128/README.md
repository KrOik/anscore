# gw2a_crypto_aes128

AES-128 ECB single-block encryptor (FIPS-197), iterative 1-round/clk_en datapath, on-the-fly key expansion, composite-field S-boxes.

## Ports

| port | dir | width | note |
|---|---|---|---|
| clk | in | 1 | posedge clock |
| rst_n | in | 1 | active-low async reset |
| clk_en | in | 1 | step enable, tie 1 for full rate |
| start | input | 1 | pulse 1 clk_en beat; key/din must be stable |
| key | input | 128 | cipher key, byte 0 = key[127:120] |
| din | input | 128 | plaintext block, byte 0 = din[127:120] |
| dout | output | 128 | ciphertext, valid when done pulses |
| done | output | 1 | 1-beat pulse when dout is ready |
| busy | output | 1 | high while a block is being processed |

## Validation
- selftest unit(s): 0 (AESB), FNV-1a digest 61C7D1CF
- board bitstream mask: m01
- UART evidence: `../../doc/board_uart_m01.txt`
- golden: `tools/golden_model.py` (independent models)

## 2026-09-24 optimization

The S-box uses GF(16)[y]/(y^2+y+8), with GF(16) polynomial x^4+x+1.
`tools/gen_aes_composite_sbox.py` derives the AES basis maps and exhaustively
checks all 256 values against AES-field inversion. Yosys also proves all
eight output bits equivalent to the archived original LUT S-box.
This is an unmasked implementation with no side-channel protection claim.

Same-tool isolated synthesis: 3,840 -> 2,276 LUT1-4 (-40.7%), 390 FF
unchanged, zero DSP/BRAM. Interface and ten enabled round cycles are unchanged.
The existing board AES digest stays `61C7D1CF`. The added
`aes128_rate_board` runs clk_en=1 at 27 MHz, checks ten round cycles, and
exports all 64 ciphertext bytes for independent host comparison.
20 complete captured reports passed (four known-answer blocks per report).

Evidence at repository root: `artifacts/ip_optimization_20260924/aes/`.
See `docs/IP_OPTIMIZATION_STATUS.md` for commands, resource comparisons and
scope. Full-rate board top: 3,543 LUT4, 1,014 FF, 0 DSP, 0 BRAM.
