# External transport qualification

Fresh T13 UART input and A11/D0 FX2 output were qualified twice on 2026-09-25.
`uart_injection_probe` transforms each externally supplied random byte by XOR A5.
Every decoded FX2 byte is checked against that new nonce stream, including
leading/trailing partial packets; at least two full packets are mandatory.

Build and run (fresh output directories required):

```
pwsh -NoProfile -File cores/signal_processing/dsp_isp_library/board/build_probe.ps1 -OutputDir artifacts/dsp_isp_20260925/uart_probe_build_NEW
python cores/signal_processing/dsp_isp_library/board/probe_external.py --image artifacts/dsp_isp_20260925/uart_probe_build_NEW/probe.fs --output artifacts/dsp_isp_20260925/uart_external_NEW
```

The build runs a 32-byte real-UART simulation including bad-stop rejection before
synthesis/P&R/pack. Actual build_01: 112 LUT4, 83 FF, 0 DSP, 0 BRAM; final
routed estimate 384.02 MHz, target 27 MHz. This estimate is not measured Fmax.
Sources/hashes, logs and bitstream are preserved in that build directory.

Physical runs `uart_external_01` and `_02` under the same artifacts directory:
373 and 377 fresh decoded bytes respectively PASS, distinct random input
packets, separate SRAM programming and raw `.sr`/decode/verdict records.
Both use JTAG 1 MHz, UART 115200, FX2 4 MS/s and D0=A11.
Both releases archived their owned `.boardlock`. Final SRAM is probe.fs SHA256
`acd8b8bdf48526f73e62ea8a7ff47db80690a0007fb4869b07ca3ecf38127d4e`.

COM24's first read contained 3906 historical bytes before the 768 current echo
bytes. These historical bytes are **not acceptance evidence**. The decision is
based exclusively on fresh FX2 data tied to each newly generated random packet.
The second serial file contains only its 768 current echo bytes, but is still
supplemental. Raw files are kept intact; no historical bytes were substituted
for new validation, and no invalid FX2 byte was discarded.

The script owns the board lock for its full detect/program/capture lifecycle and
refuses an existing lock. It writes SRAM only. If programming fails, SRAM content
must be treated as unconfirmed even if the image filename is recorded.

This proves the external **transport** path. It does not qualify any DSP/ISP
algorithm, loaded-buffer full-rate replay, throughput, or production integration.
Those require the block harness and independent per-result checks.

## Remote board operation (2026-09-26)

Dock UART/JTAG, FX2 (fx2lafw) and the 138K SOM are attached to the remote
bianbu board (192.168.31.176, riscv64), not the Windows host. Remote tools on
the board: openFPGALoader 0.12.0, sigrok-cli, pyserial 3.5, iverilog/yosys/
nextpnr-himbaechel/gowin_pack (apycula 0.33 venv at ~/venvs/apycula).

Remote drivers in `board/remote/` mirror the local flow (same images,
verification oracles and negative checks):

    # Transport probe (build locally with build_probe.ps1, then):
    python board/remote/probe_remote.py --image <build>/probe.fs --output <new_artifacts_dir>

    # dsp_chain harness (build locally with dsp_chain_harness/run.py --build, then):
    python board/remote/run_chain_remote.py --build <evidence/chain_dir> --output <new_artifacts_dir>

UART is /dev/ttyUSB1 (dock FT2232 channel B) at 115200; FX2 capture at
4 MS/s on D0 (=A11). Programming writes SRAM only (openFPGALoader -b
tangprimer20k). All runs are orchestrated on-board via a single SSH session so
serial pacing and capture timing are local to the hardware. Evidence trees are
downloaded intact (capture.sr, decoded.bin, per-case verdicts, program.log).

Boardlock: the repo .boardlock convention still applies — take the lock
locally before starting a remote physical run and release it after; the remote
scripts currently assume exclusive hardware ownership during execution.

## Generic harnesses (2026-09-27)

Two parameterized harnesses qualify stream cores standalone (no dependency on
the production chain harnesses):

- `board/dsp_stream_harness/` (BLK1/RES1, 1:1 32-bit words): CORE 0=farrow,
  1=agc, 2=biquad(canned SOS), 3=lms(serial), 4=mag_squared.
  `python run.py --core <name> --build` -> dstream.fs.
- `board/isp_stream_harness/` (IMG1/IMR1, 8x8 frames): CORE 0=median,
  1=convolution(canned kernels), 2=gradient, 3=morphology.
  `python run.py --core <name> --build` -> image.fs.

`board_case_remote.py` auto-detects `dstream.fs` (mode 'dstream', frozen
protocol.py self-contained).  Sequential multi-core board runs:

    python board/run_all_remote.py --plan board/plan.json

Qualification evidence: artifacts/dstream_board_20260927/<core>_0{1,2*}/
(verdict + per-case capture.sr at 4MS/s, FX2 D0 = A11 UART).

Bulk route/timing audit of every requirement-level core:

    python cores/signal_processing/dsp_isp_library/tools/pnr_audit.py            # all specs
    python cores/signal_processing/dsp_isp_library/tools/pnr_audit.py --only <case...>

Per-case artifacts under <core>/evidence/pnr_*/<case>/ (summary.json with
lut/ff/dsp/bram/fmax/gates + full yosys/nextpnr logs).
