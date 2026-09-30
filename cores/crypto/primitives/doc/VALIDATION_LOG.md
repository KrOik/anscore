# crypto_20k validation log

## 2026-09-24 SHA-256 shared word-load optimization

Changed only schedule word-loading mechanics in `src/sha256_core.v`:
input/padding complete words use the existing shift path, avoiding separate
per-word indexed writes. Round arithmetic and external protocol unchanged.
Added `sha256_rate_board`, stress/full-rate TBs, independent hashlib vector
and board models, capture verifier, bounded symbolic-load proof tool, and
build/regression scripts. Updated SHA package docs/metadata and central ledger.

`scripts/test_crypto_sha256_optimization.ps1`: PASS all five benches.
Includes 64 hashlib messages (46,294 bytes), lengths 1..4096 with boundary
coverage, stalls, input bubbles, loading/compression init aborts and reset
recovery. Every ready/digest_valid/digest cycle compared to preserved original
RTL. Original three SHA answers, complete crypto selftest and 192-byte UART
report pass with all original digests unchanged. Empty-message API remains
unsupported. `prove_sha256_word_load.py`: PASS bounded symbolic 64-byte
first-block loading into actual original/candidate schedule registers;
scope is loading, not complete SHA algorithm equivalence.

Same-tool `synth_gowin -noalu -family gw2a` core LUT1-4: 2,986 -> 2,465
(-17.4%), FF 1,130 unchanged, DSP/BSRAM 0. SHA+CRC mask 0x1e top:
15,171 -> 14,634 LUT; oversized baseline stopped by budget gate before
P&R/programming. Candidate routed at 14,634 LUT4 / 1,617 FF / 0 DSP/BSRAM,
estimated Fmax 49.62 MHz. Physical UART reports SHAB `566ACEA2`, CRC8
`FD957A4B`, CR16 `D0771E60`, CR32 `720D8B44`, twice each. AES disabled in
this subsystem image; full-mask crypto integration passed simulation.

Separate full-rate before/after top (same harness): 12,422 -> 11,825 LUT4,
4,524 FF unchanged, 0 DSP/BSRAM; Fmax estimates 125.16 -> 118.85 MHz.
Both tested on hardware at 27 MHz / clk_en=1 only. 12 message lengths
(3,55,56,63,64,65,119,120,127,128,129,255), full digest bytes and exact
129/257/385/641 cycle counts match hashlib/protocol calculations.
Candidate captured 9 and 8 complete reports in two programming sessions;
baseline captured 8. Corrupt digest/cycle reports are rejected by host checker.

Commands: `scripts/build_crypto_sha256_optimization.ps1` (optional `-FullRate`
and `-CoreSource` baseline), openFPGALoader, sigrok-cli fx2lafw @4 MHz on
D0=A11, UART decode @115200, `verify_sha256_board_capture.py`.
All evidence, exact source snapshots/diffs/hashes and raw `.sr` captures:
repository `artifacts/ip_optimization_20260924/sha256/`; full reproduction
commands in `docs/IP_OPTIMIZATION_STATUS.md`. Older records below preserved.

## 2026-09-24 AES composite-field optimization

Changed `src/aes128_core.v` S-box only: generated composite-field arithmetic
replaces the case table. Sequential control, ports, ten enabled round cycles
and all expected ciphertexts/digests are unchanged. Added full-rate board
harness, stress/harness testbenches, independent vector/S-box generators,
host capture verifier and build/regression scripts. Package metadata updated;
historical resource evidence retained. Unmasked: no leakage-protection claim.

Commands: `scripts/test_crypto_aes_optimization.ps1` PASS all 5 benches;
`scripts/build_crypto_aes_optimization.ps1` PASS baseline and candidate;
same script with `-FullRate` PASS. `yosys equiv_simple` / `equiv_status -assert`
prove 8/8 S-box bits against original RTL. 256 independent PyCryptodome
vectors plus clk_en, busy-start, reset and recovery checks PASS.

Isolated LUT1-4: 3,840 -> 2,276 (-40.7%); FF 390 unchanged; DSP/BSRAM 0.
Same AES-only board harness, same seed: 8,292 -> 6,782 LUT4 (-18.2%),
578 FF unchanged; post-route Fmax 46.87 -> 63.49 MHz (tool estimates).
Full-rate test top: 3,543 LUT4, 1,014 FF, 0 DSP/BSRAM, routed 104.64 MHz,
operated on hardware at 27 MHz only.

Programmed with `openFPGALoader -b tangprimer20k`. fx2lafw at 4 MHz, D0=A11,
decoded by sigrok at 115200 8N1: original and optimized images both report
`U0 AESB P D=61C7D1CF` twice. Full-rate clk_en=1 image produces 20 complete
`AES27 PASS R=0A` frames; all 64 ciphertext bytes per frame match the
independent golden model. Host checker also rejects deliberately corrupted
complete frames. Other crypto cores retain full-mask simulation PASS; they
were disabled in these fresh board builds.

Evidence at repository `artifacts/ip_optimization_20260924/aes/`, including
original RTL, source diff/hashes, all synthesis/P&R logs, bitstreams, raw
`.sr` captures and verdict JSON. See `docs/IP_OPTIMIZATION_STATUS.md` for
exact reproduction commands and scope. Older validation follows unchanged.

Batch: security cores on Sipeed Tang Primer 20K (Gowin GW2A-18C, 27 MHz).
All commands run from `cores/crypto/primitives/` with
`oss-cad-suite/bin` + `oss-cad-suite/lib` on PATH.

## Units

| unit | name | core | stimulus | golden source |
|---|---|---|---|---|
| U0 | AESB | aes128_core | 4 ECB encrypt vectors | FIPS-197 C.1/B published CTs + pycryptodome |
| U1 | SHAB | sha256_core | "abc" + 56B NIST msg + 100B pattern | hashlib.sha256 |
| U2 | CRC8 | crc_core mode 0 | 64B stream ("123456789"+formula) | bit model, check 0xF4 |
| U3 | CR16 | crc_core mode 1 | same stream | bit model, check 0x29B1 |
| U4 | CR32 | crc_core mode 2 | same stream | binascii.crc32, check 0xCBF43926 |

FNV-1a digests folded byte-serial (MSB first) by the selftest and by
`tools/golden_model.py` independently. Values:

```
AESB 61C7D1CF   SHAB 566ACEA2
CRC8 FD957A4B   CR16 D0771E60   CR32 720D8B44
```

## Files

- `src/aes128_core.v` — AES-128 encrypt, 1 round/clk_en, on-the-fly key
  schedule, 20x LUT S-box. 11 beats/block.
- `src/sha256_core.v` — SHA-256, byte-serial in, internal pad (0x80/zeros/
  64-bit length), 64 rounds/block, 16x32 W shift register.
- `src/crc_core.v` — runtime mode[1:0]: CRC-8/SMBUS, CRC-16/CCITT-FALSE,
  CRC-32/ISO-HDLC (reflected, zlib semantics). 1 byte/clk_en.
- `src/crypto_selftest.v` — 5-unit harness, ce/16 beats, FNV-1a, `===`.
- `src/top.v` — UART report `CRYPT M=XXXX P=XXXX` + 5 unit lines (192 B).
- `src/uart_tx.v`, `src/top.cst` (clk H11, uart_tx M11, status T9/P9).
- `src/la_debug_top.v`, `src/la_debug.cst` — debug variant of top with
  uart_tx/status signals mirrored to the fx2lafw LA header pins
  (D0=A11 uart_tx, D1=B11 all_done, D2=N6 pass, D3=D11 fail, D4=N9 ce,
  D5=N7 rst_n, D6=L9 tx_busy, D7=N8 heartbeat); identical selftest +
  report FSM as `top.v`.
- `sim/txprobe_top.v` — minimal M11 square-wave probe used to prove the
  host-side UART path dead (0 bytes at the FTDI even for a ~211 kHz
  square wave).
- `sim/tb_{aes128,sha256,crc}_core.v` — standalone vectors.
- `sim/tb_crypto_selftest.v`, `sim/tb_top_uart_report.v`.
- `tools/golden_model.py` — independent digests (pycryptodome/hashlib/
  binascii + bit models). `tools/gen_uart_golden.py` — expected_report.mem.
- `tools/gen_ip_wrappers.py` — `ip/` tree.

## Commands / results

| step | command (abbrev) | result |
|---|---|---|
| syntax | `iverilog -g2012 -o /dev/null -s <m> <srcs>` | PASS all modules |
| AES TB | `vvp sim/tb_aes128_core.vvp` | PASS 4/4 (incl. 3 FIPS-197 published CTs) |
| SHA TB | `vvp sim/tb_sha256_core.vvp` | PASS 3/3 vs hashlib (1-, 2-block msgs) |
| CRC TB | `vvp sim/tb_crc_core.vvp` | PASS 6/6 (check values + 64B stream) |
| selftest | `vvp sim/tb_crypto_selftest.vvp` mask 1F | PASS, digests == golden |
| selftest | mask 03 / 1C | PASS (skipped units report S/seed) |
| UART rep | `vvp sim/tb_top_uart_report.vvp` | PASS, 192 B stream == expected_report.mem |
| yosys | `synth_gowin -top top` mask 1F | LUT4 20909 > 20736 -> split (SOP Phase 0) |
| yosys+pnr | mask 01 | LUT4 7782/20736 (38%), DFF 554, DSP 0, BSRAM 0 |
| yosys+pnr | mask 1E | LUT4 13545/20736 (65%), DFF 1593, DSP 0, BSRAM 0 |
| pack | `gowin_pack-script.py` | `crypto_20k_m01.fs`, `crypto_20k_m1e.fs` |
| IP synth | `synth_gowin -top gw2a_crypto_*` | aes128 ~3.8K LUT, sha256 ~2.3K, crc ~0.15K |
| program | `openFPGALoader -b tangprimer20k *.fs` | DONE (SRAM) |
| COM24 | `python tools/read_uart.py` + D2XX direct | 0 B — host path dead |
| LA cap | `sigrok-cli -d fx2lafw:conn=2.2 -c samplerate=1MHz` | `la_cap_m01/m1e.sr`, uart D0 decodes clean |
| board | LA-decoded reports | all units `P`, digests == golden (see below) |

nextpnr max-frequency reports (no STA sign-off, informational):
m01 143.80 MHz, m1e 69.70 MHz at 27 MHz operating clock -> >2x margin.

## Board evidence

Bitstreams programmed via `openFPGALoader -b tangprimer20k` (SRAM,
DONE confirmed each time). `.boardlock` owned by `crypto_20k_agent`
(previous `imgwin_20k` owner was >30 min stale and was replaced; their
agent process continued running and caused intermittent JTAG
contention — `usb_open()` failures — and reprogrammed the board between
its own builds; all captures below were taken in windows where the
crypto bitstream was the resident config).

### COM24 host path dead (deviation, same as dsp_20k)

`doc/board_uart_com24_m01.txt` / `doc/board_uart_com24_m1e.txt` are
intentionally kept at 0 bytes. Verified dead beyond doubt:

- 0 bytes on COM24 (pyserial) across ~20 attempts incl. a 120 s
  continuous read with 8 successful reprograms.
- 0 bytes with a previously board-validated imgwin bitstream
  (`imgwin_20k.fs` produced `doc/board_uart_full.txt`, 1344 B, at 02:21
  on the same setup — path died afterwards).
- 0 bytes reading FTDI channel B directly through D2XX
  (`ftd2xx.dll` FT_Open "USB Debugger B", FT_GetStatus RX queue empty
  for 8 s while the design ran).
- 0 bytes even for `txprobe_top.v` driving M11 with a ~211 kHz square
  wave over 18 uncontested program+read iterations — the FTDI RX pin
  sees nothing, so the failure is in the debugger/USB path, not the
  FPGA image.
- `host/ftdi_raw_uart_read.py` fails at `claim_interface`
  (NotImplementedError, VCP-bound interface — same as dsp_20k).

### Substituted evidence: fx2lafw LA decode (per dsp_20k precedent)

Debug bitstreams `build_oss/crypto_20k_la_m01.fs` and
`crypto_20k_la_m1e.fs` (`src/la_debug_top.v`, same selftest + report FSM
as `top.v`, uart_tx mirrored to A11 = LA D0) were programmed and
captured with
`sigrok-cli -d fx2lafw:conn=2.2 -c samplerate=1MHz --time 3s`
(`build_oss/la_cap_m01.sr`, `la_cap_m1e.sr`), decoded
`uart:baudrate=115200:rx=D0`. The identical uart_tx net also drives M11
in the production images (`top_m01/top_m1e` pnr JSON: OBUF at
X55Y26/IOBB), so the production design emits this stream on M11; only
the host COM24 capture path is non-functional.

`doc/board_uart_m01.txt` (960 B, 5 reports) — verbatim:

```
CRYPT M=001F P=001F           
U0 AESB P D=61C7D1CF          
U1 SHAB S D=811C9DC5          
U2 CRC8 S D=811C9DC5          
U3 CR16 S D=811C9DC5          
U4 CR32 S D=811C9DC5          
```

`doc/board_uart_m1e.txt` (576 B, 3 reports) — verbatim:

```
CRYPT M=001F P=001F           
U0 AESB S D=811C9DC5          
U1 SHAB P D=566ACEA2          
U2 CRC8 P D=FD957A4B          
U3 CR16 P D=D0771E60          
U4 CR32 P D=720D8B44          
```

All five unit digests match `tools/golden_model.py` byte-exact on
physical hardware; `M=001F P=001F` (all done, all pass) in both images;
skipped units correctly report `S` + FNV seed `811C9DC5`.

## Deviations

- Full 5-unit harness exceeds LUT budget (20.9K > 20.7K device, >15K
  budget) -> validated via two UNIT_EN bitstreams per SOP Phase 0:
  m01 (AES) + m1e (SHA + 3x CRC). Sim coverage still includes the
  full 0x1F mask for both selftest and UART report.
- COM24/FTDI channel-B host capture path dead on this machine (proven
  with known-good bitstream + square-wave probe, see above); board
  evidence captured via fx2lafw LA decode of the identical uart_tx
  stream on physical pin A11, same workaround as dsp_20k.
- Board shared with `imgwin_20k` agent: their stale lock was replaced
  per policy, but their process kept cycling the board during this
  session (intermittent JTAG contention and config overwrites); all
  successful captures were taken in verified-clean windows.
- AES S-boxes are combinational LUTs (not BSRAM) to keep the iterative
  datapath single-beat; DSP count is 0 everywhere.
- `crypto_selftest.v` pass-mask loop cleaned to avoid out-of-bounds
  `done_w[ui]` selects for ui>=5 (synthesis warning; semantics
  unchanged, all masks re-simulated PASS).
