# Tang Primer 20K DSP/ISP IP Board Verification — 2026-09-28

This session is restricted to the remote K1 host (`bianbu@192.168.31.176`) and the Tang Primer 20K Dock.  No NANO DAP / Tang Mega 138K Pro SoM testing was performed, and the previous 138K UART probe was not repeated.  The goal of the overall DSP/ISP IP library remains unfinished; this document records the Tang-only evidence and classification produced in this round.

## 1. Remote Tang Primer 20K Hardware Confirmation

| Item | Value |
|------|-------|
| host | `bianbu@192.168.31.176` |
| remote hostname | `spacemit-k1-x-MUSE-Pi-Pro-board` |
| architecture | `riscv64` |
| Tang USB | `0403:6010` FTDI FT2232C/D/H |
| FX2 LA | `1d50:608c` fx2lafw |
| NANO/CMSIS-DAP | `0d28:0204` present but **not used** for this Tang session |
| Tang JTAG detect | idcode `0x81b`, manufacturer `Gowin`, family `GW2A`, model `GW2A(R)-18(C)` |
| UART device | `/dev/ttyUSB1` (FT2232 channel B) at 115200 baud |
| FX2 sigrok device | `fx2lafw:conn=2.16` |
| decode convention | `uart:rx=D0:baudrate=115200` |

Hardware discovery was already successful in the preceding thread; this session reused the proven Tang 20K plumbing (`isp_stream_harness` / `dsp_stream_harness` / `board/remote/run_board_remote.py`).

## 2. `.boardlock` Ownership and Release

A Tang-specific lock was acquired before any programming:

```text
session=devin_20260928_tang20k
owner=devin
board=Tang_Primer_20K_Dock
host=bianbu@192.168.31.176
purpose=tang20k_dsp_isp_adapter_verification
```

The lock was released at the end of the session into `.boardlock_released.json` with the same session token.  All board access was serial and exclusive.

## 3. Blocked-Item Inspection and Adapter Categories

The 27 currently blocked requirements were inspected.  The dominant failure mode is **transport-shape mismatch** against the existing 1:1 `BLK1`/`IMG1` contracts, not algorithmic IP failure.  The requested narrow adapter families map as follows:

| Adapter family | Representative requirements | Blocker |
|---------------|----------------------------|---------|
| Rate-change / multi-count | DSP-01, DSP-03, DSP-10 | output count != input count |
| Block/frame report | DSP-06, DSP-14, ISP-09 | per-block/per-frame report instead of streaming beat |
| Wide-word (>30 bit) | DSP-12, DSP-13, ISP-12 | output word wider than one transport word |
| LUT/table load | ISP-13, ISP-18, ISP-19 | runtime coefficient/coordinate table |
| Two-pass / replay | ISP-11, ISP-17 | frame accumulation then second pass |
| Multi-frame / multi-channel | ISP-16, DSP-16 | pass/channel/frame IDs and counts |
| Multi-cfg / pipeline | ISP-08, ISP-14 | multiple sequential configuration writes |
| Standalone primitive harness | INFRA-01, INFRA-03, INFRA-05, INFRA-07 | needs explicit board-visible primitive path |

The four entries that **must remain Tang failures/blockers** are unchanged:

- DSP-14 (STFT) — Tang P&R failure retained, 138K P&R not promoted.
- ISP-06 (scale_poly6) — existing Tang failure retained.
- ISP-10 (integral_stats / adaptive_threshold) — Tang timing failure retained, 138K evidence not promoted.
- ISP-11 (histeq) — Tang timing failure retained; two-pass adapter still needed.

## 4. Adapter Implemented This Session — ISP-07 Bayer Demosaic

The first narrow Tang adapter added `isp/bayer/rtl/bayer_demosaic.sv` into the existing `isp_stream_harness` as **CORE=4**.  The 8×8 `IMG1`/`IMR1` frame contract already carries enough framing for Bayer: `config_word[1:0]=cfg_cfa`, `[2]=cfg_ox`, `[3]=cfg_oy`, `[7:4]=cfg_reserved` (must be zero).  Output is 24-bit RGB `{R,G,B}` packed into the 30-bit `odata` field plus `sof`/`eol` sidebands.

### Changed files

- `cores/signal_processing/dsp_isp_library/board/isp_stream_harness/isp_stream_harness.v` — added `CORE==4` bayer branch.
- `cores/signal_processing/dsp_isp_library/board/isp_stream_harness/run.py` — added `bayer` to `CORES`.
- `cores/signal_processing/dsp_isp_library/board/isp_stream_harness/protocol.py` — added bayer model load, oracle, cases, and config validation.
- `cores/signal_processing/dsp_isp_library/requirements.json` — updated `ISP-07` status and evidence paths.

### Commands run

```text
python cores/signal_processing/dsp_isp_library/board/isp_stream_harness/run.py --core bayer --bits 8 --padding 1
python cores/signal_processing/dsp_isp_library/board/isp_stream_harness/run.py --core bayer --bits 8 --padding 1 --build
python cores/signal_processing/dsp_isp_library/board/remote/run_board_remote.py \
  --build cores/signal_processing/dsp_isp_library/board/isp_stream_harness/evidence/bayer8_pad1_20260928_151135_762658 \
  --output artifacts/bayer_tang20k_20260928_01
python cores/signal_processing/dsp_isp_library/board/remote/run_board_remote.py \
  --build cores/signal_processing/dsp_isp_library/board/isp_stream_harness/evidence/bayer8_pad1_20260928_151135_762658 \
  --output artifacts/bayer_tang20k_20260928_02_reprogram
```

### Tang build metrics (GW2A-18C, 27 MHz target)

```text
lut        = 1138
routed_lut4= 1138
dsp        = 0
fmax_mhz   = [187.86, 117.65]
bitstream_sha256 = 59980b8a14a40eb60fa1ca3c74358e0a1c9cb73da2180b324321d123cd2600fe
```

All gates are within the Tang budget (≤15K LUT, ≤4 DSP, ≥27 MHz).

### Board evidence

| Run | Path | Result |
|-----|------|--------|
| First program | `artifacts/bayer_tang20k_20260928_01/verdict.json` | PASS (16 cases, all CFA/ox/oy combos, malformed rejection PASS) |
| Reprogram/retest | `artifacts/bayer_tang20k_20260928_02_reprogram/verdict.json` | PASS |
| FX2 capture (first) | `artifacts/bayer_tang20k_20260928_01/case_00/capture.sr` | captured |
| FX2 capture (reprogram) | `artifacts/bayer_tang20k_20260928_02_reprogram/case_00/capture.sr` | captured |
| Build log | `cores/signal_processing/dsp_isp_library/board/isp_stream_harness/evidence/bayer8_pad1_20260928_151135_762658/build_summary.json` | BUILD_PASS_NOT_BOARD |
| Simulation log | `cores/signal_processing/dsp_isp_library/board/isp_stream_harness/evidence/bayer8_pad1_20260928_151135_762658/simulation_summary.json` | PASS |

The independent `isp/bayer/models/reference.py` model was used for the oracle; expectations are not derived from DUT output.  Malformed-packet rejection was exercised by the harness negative cases and by the per-case `negative_check` corruption test.

## 5. Tang-Only PASS / PARTIAL / FAIL / BLOCKED Classification

| ID | Top status | Board test | Route timing | Tang classification |
|----|------------|------------|--------------|---------------------|
| DSP-01 | blocked | BLOCKED | PASS | BLOCKED (rate-change adapter needed) |
| DSP-02 | pass | PASS | PASS | PASS (already qualified, not rerun) |
| DSP-03 | blocked | BLOCKED | PASS | BLOCKED (rate-change adapter needed) |
| DSP-04 | pass | PASS | PASS | PASS (chain evidence) |
| DSP-05 | partial | PARTIAL | PASS | PARTIAL (mag_squared partial) |
| DSP-06 | blocked | BLOCKED | PASS | BLOCKED (block-report adapter needed) |
| DSP-07 | pass | PASS | PASS | PASS (already qualified, not rerun) |
| DSP-08 | blocked | BLOCKED | PASS | BLOCKED (wide status adapter needed) |
| DSP-09 | pass | PASS | PASS | PASS (chain evidence) |
| DSP-10 | blocked | BLOCKED | PASS | BLOCKED (rate-change adapter needed) |
| DSP-11 | pass | PASS | PASS | PASS (already qualified, not rerun) |
| DSP-12 | blocked | BLOCKED | PASS | BLOCKED (wide-word adapter needed) |
| DSP-13 | blocked | BLOCKED | PASS | BLOCKED (wide-word adapter needed) |
| DSP-14 | blocked | BLOCKED | FAIL | **FAIL** (Tang P&R failure retained) |
| DSP-15 | pass | PASS | PASS | PASS (already qualified, not rerun) |
| DSP-16 | blocked | BLOCKED | PASS | BLOCKED (multi-channel adapter needed) |
| ISP-01 | pass | PASS | PASS | PASS (chain evidence) |
| ISP-02 | pass | PASS | PASS | PASS (already qualified, not rerun) |
| ISP-03 | pass | PASS | PASS | PASS (already qualified, not rerun) |
| ISP-04 | pass | PASS | PASS | PASS (already qualified, not rerun) |
| ISP-05 | pass | PASS | PASS | PASS (chain evidence) |
| ISP-06 | fail | FAIL | FAIL | **FAIL** (existing failure retained) |
| ISP-07 | pass | PASS | PASS | **PASS** (this session) |
| ISP-08 | blocked | BLOCKED | PASS | BLOCKED (multi-cfg pipeline adapter needed) |
| ISP-09 | blocked | BLOCKED | PASS | BLOCKED (report adapter needed) |
| ISP-10 | blocked | BLOCKED | FAIL | **FAIL** (Tang timing failure retained) |
| ISP-11 | blocked | BLOCKED | FAIL | **FAIL** (Tang timing failure retained) |
| ISP-12 | blocked | BLOCKED | PASS | BLOCKED (wide-word adapter needed) |
| ISP-13 | blocked | BLOCKED | PASS | BLOCKED (LUT-load adapter needed) |
| ISP-14 | blocked | BLOCKED | PASS | BLOCKED (3×3 matrix + 24-bit RGB adapter needed) |
| ISP-15 | blocked | BLOCKED | PASS | BLOCKED (spatial-format/rate-change adapter needed) |
| ISP-16 | blocked | BLOCKED | PASS | BLOCKED (pass-chained adapter needed) |
| ISP-17 | blocked | BLOCKED | PASS | BLOCKED (two-frame adapter needed) |
| ISP-18 | blocked | BLOCKED | PASS | BLOCKED (LUT-load adapter needed) |
| ISP-19 | blocked | BLOCKED | PASS | BLOCKED (coordinate LUT-load adapter needed) |
| INFRA-01 | blocked | BLOCKED | PASS | BLOCKED (primitive harness pending) |
| INFRA-02 | pass | PASS | PASS | PASS (chain evidence) |
| INFRA-03 | blocked | BLOCKED | PASS | BLOCKED (dual-clock board path pending) |
| INFRA-04 | tooling | PASS | NA-tooling | PASS (tooling scope) |
| INFRA-05 | blocked | BLOCKED | PASS | BLOCKED (standalone fixedpoint harness pending) |
| INFRA-06 | blocked | BLOCKED | BLOCKED | BLOCKED (no external memory controller) |
| INFRA-07 | blocked | BLOCKED | PASS | BLOCKED (test-source/sink harness pending) |

**Tang real-board PASS count this session: 1 new (ISP-07) plus the previously established 9 Tang harness/chain passes.**  The total DSP/ISP IP goal is **not** claimed complete.

## 6. Next Steps

- Continue the narrow adapter families in priority order:
  - Rate-change: DSP-01, DSP-03, DSP-10, ISP-15
  - Wide-word: DSP-12, DSP-13, ISP-12
  - LUT-load: ISP-13, ISP-18, ISP-19
  - Two-pass: ISP-11, ISP-17
  - Multi-frame/multi-channel: DSP-16, ISP-16
  - Multi-cfg: ISP-08, ISP-14
- For each candidate, first run simulation, then Tang P&R gate, then acquire `.boardlock`, program SRAM, capture FX2, decode, compare to the independent model, and repeat the program/retest before releasing the board.
- Keep DSP-14, ISP-06, ISP-10, and ISP-11 as Tang failures/blockers regardless of any 138K evidence.
