# gw2a_crypto_sha256

SHA-256 hash engine (FIPS-180-4), byte-serial streaming input with internal 0x80/zero/length padding, 64-round iterative compression, 16x32 message-schedule shift register.

## Ports

| port | dir | width | note |
|---|---|---|---|
| clk | in | 1 | posedge clock |
| rst_n | in | 1 | active-low async reset |
| clk_en | in | 1 | step enable, tie 1 for full rate |
| init | input | 1 | pulse 1 clk_en beat to start a new message |
| din | input | 8 | message byte |
| din_valid | input | 1 | byte valid; honored only while din_ready |
| din_last | input | 1 | marks the final message byte |
| din_ready | output | 1 | low during 64-round compression |
| digest | output | 256 | {H0..H7}, H0 at [255:224] |
| digest_valid | output | 1 | level: digest complete |

## Validation
- selftest unit(s): 1 (SHAB), FNV-1a digest 566ACEA2
- board bitstream mask: m1e
- UART evidence: `../../doc/board_uart_m1e.txt`
- golden: `tools/golden_model.py` (independent models)

## 2026-09-24 shared-load optimization

Input and padding words now reuse the message-schedule shift path, replacing
the 16-way indexed-write selection. After all 16 words have entered, the
compression schedule is identical. External ports and control timing are
unchanged. Empty messages remain unsupported by the existing last-byte API;
this optimization does not add a zero-byte completion command.

Same-tool isolated `-noalu` synthesis: 2,986 -> 2,465 LUT1-4 (-17.4%),
1,130 FF unchanged, 0 DSP/BSRAM. SHA+CRC test top: 15,171 -> 14,634 LUT,
bringing the candidate under the 15K gate. The oversized baseline was not
routed/programmed; its baseline board test uses the separate full-rate top.

Validation: 64 hashlib messages (46,294 total bytes), padding/multi-block
boundaries, stalls, bubbles, init aborts and reset recovery; every observed
ready/digest_valid/digest cycle matches original RTL. A bounded symbolic
proof checks arbitrary 64-byte first-block word loading (not whole-SHA
formal equivalence). Original crypto selftest and full UART report pass.

At 27 MHz / clk_en=1, 12 lengths from 3 to 255 bytes export all digest bytes
and cycle counts. Candidate captures: 9 + 8 complete reports across two
programming sessions; original: 8 reports. All digests match hashlib and
cycles match 129/257/385/641 as appropriate. Full-rate top LUT4:
12,422 -> 11,825; estimated Fmax 125.16 -> 118.85 MHz (not silicon Fmax).

Evidence at repository `artifacts/ip_optimization_20260924/sha256/`;
commands and scope in `docs/IP_OPTIMIZATION_STATUS.md`.
