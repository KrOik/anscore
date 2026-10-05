# sigproc_20k IP manifest

Packaged signal/statistics cores for Gowin GW2A-18C (Sipeed Tang Primer 20K,
27 MHz). All cores are clock-enable clean, BSRAM-friendly, and validated
against the independent pure-Python golden model `tools/golden_model.py`.

| IP | Wrapper | Function | DSP | BSRAM | Golden digest (FNV-1a) |
|---|---|---|---|---|---|
| gw2a_sig_fft64 | `ip/gw2a_sig_fft64.v` | 64-pt radix-2 DIT FFT, signed 16b complex Q1.15, natural-order I/O, shift-add twiddles | 0 | yes | `53D1DDAF` |
| gw2a_sig_cic_dec8 | `ip/gw2a_sig_cic_dec8.v` | CIC decimator N=3 R=8 M=1, 8b in -> 17b out | 0 | no | `076987E4` |
| gw2a_sig_hist256 | `ip/gw2a_sig_hist256.v` | 256-bin 8b histogram, BSRAM RMW, same-bin forwarding, 24b total | 0 | 1 | `C4B4F3D5` |
| gw2a_sig_otsu_thresh | `ip/gw2a_sig_otsu_thresh.v` | Iterative Otsu threshold over 256-bin histogram | 0 | no | `D97CE6D3` |

Per-IP docs and metadata: `ip/<name>/README.md`, `ip/<name>/manifest.json`.

Dependencies (compile together with each wrapper):

- `gw2a_sig_fft64`: `src/fft64.v`, `src/sig_sdp_ram.v`, `src/sig_rom.v`,
  plus `fft64_cos.mem`/`fft64_sin.mem` on the readmemh path.
- `gw2a_sig_cic_dec8`: `src/cic_dec8.v`.
- `gw2a_sig_hist256`: `src/hist256.v`, `src/sig_sdp_ram.v`.
- `gw2a_sig_otsu_thresh`: `src/otsu_thresh.v`.

Validation evidence: `doc/VALIDATION_LOG.md`, `doc/board_uart_*.txt`,
`build_oss/yosys.log`, `build_oss/nextpnr.log`.
