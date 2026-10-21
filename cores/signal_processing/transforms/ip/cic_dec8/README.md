# gw2a_sig_cic_dec8

CIC decimator for Gowin GW2A-18: N=3 stages, decimation R=8, differential
delay M=1. Three integrators run at the input rate; the comb section runs at
the decimated rate. 0 DSP, 0 BSRAM.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk`/`clk_en`/`rst_n` | in | 1 | clock, clock-enable, async active-low reset |
| `in_valid` | in | 1 | strobe: sample `din` is consumed on this `clk_en` beat |
| `din` | in | 8 (signed) | input sample |
| `out_valid` | out | 1 | one-beat strobe, once per 8 `in_valid` beats |
| `dout` | out | 17 (signed) | decimated output |

## Datapath

Signed 17-bit wrapping arithmetic throughout: 8-bit input + growth
`N*log2(R) = 9` bits. Maximum register value `8^3 * 127 = 65024 < 2^16`, so
17 bits give full Hogenauer margin; wraparound is part of the CIC contract and
is matched bit-exactly by `tools/golden_model.py`.

`out_valid` strobes on the 8th, 16th, ... `in_valid` beat (first output after
8 input samples). The combs evaluate on the decimated integrator output, so
the output rate is exactly `in_valid_rate / 8`.

## Validation

- FNV-1a digest of 64 decimated outputs vs golden model: `076987E4`.
- Verified in `sim/tb_sig_selftest.v` (integrated) and on board.
