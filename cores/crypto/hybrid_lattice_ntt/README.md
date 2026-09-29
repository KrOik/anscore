# Hybrid Lattice NTT Tang 20K Baseline

This project is a hardware milestone toward the hybrid ML-KEM-768 / ML-DSA-44
security engine. It now contains an operation-scheduled dual-bank two-lane
256-point dual-mode NTT/INTT engine that uses two identical shared fused
butterfly datapaths, even/odd block-RAM backed coefficient banks, explicit
KEM/DSA transform operation opcodes, a bounded scheduler-level flow skeleton,
and synthesized systolic issue/control-plane plus bounded arithmetic-lane
self-tests, with a board-visible full-stream monitor.

## What This Milestone Proves

- `fused_butterfly.v` implements the forward butterfly `t = b * twiddle mod q`,
  `y0 = a + t mod q`, and `y1 = a - t mod q` for both ML-KEM `q = 3329` and
  ML-DSA `q = 8380417`. Its inverse mode implements the GS-style slot
  `y0 = a + b mod q`, `y1 = (a - b) * twiddle mod q`.
- The same shift-add modular multiplier architecture is used in both modes and
  in both lanes. There is no reconfiguration, alternate multiplier, or pipeline
  drain between KEM and DSA arithmetic operations.
- `ntt256_serial_core.v` runs a full 256-point iterative DIT NTT in each mode
  and an inverse GS schedule with final `n^-1` scaling, reusing the fused
  butterflies while deriving forward and inverse twiddles from the same
  precomputed flattened table.
- The scheduler pairs adjacent independent butterflies when `j + 1 < m`,
  starts both fused butterflies together, and uses even/odd synchronous
  coefficient banks so adjacent paired operands and outputs can be read and
  written in parallel. Stage `m = 1` remains single-lane.
- `hybrid_lattice_op_scheduler.v` accepts `KEM_NTT`, `DSA_NTT`, `KEM_INTT`,
  `DSA_INTT`, bounded `KEM_FLOW`, and bounded `DSA_FLOW` commands over the
  shared core. `HYBRID_RUN` and broader future flow opcodes still return
  explicit `done/error`.
- `ntt256_systolic_issue_pipe.v` accepts one operation descriptor every clock
  and carries per-stage KEM/DSA parameters, NTT/INTT direction metadata, and
  modulus/root/n^-1 constants through an 8-stage systolic control pipeline.
- `ntt256_systolic_stream_selftest.v` issues 17 back-to-back descriptors
  covering all 16 ordered adjacent pairs over `KEM_NTT`, `DSA_NTT`,
  `KEM_INTT`, and `DSA_INTT`, and proves zero invalid bubbles, fixed 8-cycle
  fill latency, and conflict-free bank mapping for all 128 butterfly slots
  across 8 stages in both NTT and INTT directions.
- `ntt256_systolic_arith_pipe.v` adds a throughput-one 23-stage shift-add
  modular arithmetic lane. `ntt256_systolic_arith_selftest.v` feeds the same
  17-operation mixed stream with deterministic coefficient pairs and checks
  exact KEM/DSA forward/inverse butterfly outputs with zero invalid bubbles.
- `ntt256_systolic_full_stream_selftest.v` extends that proof to
  `KEM_NTT -> DSA_INTT -> KEM_INTT`, enumerating all 3072 butterfly slots and
  checking exact modular outputs in RTL simulation. The synthesized
  `ntt256_systolic_full_stream_monitor.v` exposes the corresponding
  no-bubble, count, latency, transition, and bank-check invariants on the board.
- The deterministic self-test initializer is strength-reduced to shift-add
  arithmetic, so the current synthesized head uses 0 DSP-class cells.
- `hybrid_ntt256_selftest.v` checks the KEM and DSA transform digests on FPGA
  through the scheduler and drives pass/fail pins plus a short UART report.

This is not yet the full research target. The full-stream proof shows every
butterfly slot for three adjacent full transform operations can move through
the systolic stream with no output bubbles, but the full objective still
requires a coefficient-state equivalent 256-point numerical zero-switch-overhead
NTT systolic array with banked coefficient movement through every stage, a
complete ML-KEM-768 / ML-DSA-44 scheduler, side-channel protection, TVLA
capture, formal composition evidence, and CHES/TCHES benchmark comparison.

## Commands

From the repository root:

```powershell
.\scripts\test_hybrid_lattice_ntt_sim.ps1
.\scripts\build_hybrid_lattice_ntt_with_oss.ps1
.\scripts\export_hybrid_lattice_ntt_metrics.ps1
.\scripts\program_hybrid_lattice_ntt.ps1
.\scripts\read_hybrid_lattice_ntt_uart.ps1 -Seconds 3
```

The UART report is sent at 115200 baud on `uart_tx_pin` after the self-test
finishes. The first line preserves the historical NTT comparator contract; the
later lines expose the four transform slots, bounded flow skeletons, systolic
issue/control-plane self-test, bounded arithmetic-lane self-test, and
full-stream monitor:

```text
N256 PASS D=2F9C94AD C=0000979A
OPS4 PASS D=444A5032
FLOW PASS K=EDAA6354 D=E9B06052
PIPE PASS B=0000 P=FFFF
SYST PASS D=EF556C7C B=0000 P=FFFF
FULL PASS D=C4090C17 B=0000 O=0C00 L=0017
```

The latest validated SRAM run is recorded in `doc/VALIDATION_LOG.md`. The
machine-readable metrics snapshot is written to `build_oss/metrics.json`.
The board-visible legacy 256-point dual-mode NTT line still reports 38810
cycles. The top-level self-test also executes `KEM_NTT`, `DSA_NTT`,
`KEM_INTT`, and `DSA_INTT` sequentially and emits `OPS4 PASS D=444A5032` as the
aggregate transform-slot digest. The bounded `KEM_FLOW` and `DSA_FLOW`
skeletons are now board-visible as `EDAA6354` and `E9B06052`. The systolic
control-plane line reports zero invalid bubbles (`B=0000`) and full ordered
adjacent-pair coverage (`P=FFFF`). The `SYST` line reports the bounded
arithmetic-lane digest `EF556C7C`, zero invalid arithmetic bubbles, and full
ordered adjacent-pair coverage for exact modular butterfly checks. The `FULL`
line reports the full-stream monitor digest `C4090C17`, zero invalid output
bubbles, 3072 outputs, and 23-cycle first-output latency. The latest OSS CAD
Suite build reports 10793 LUT-class cells, 4095 FF-class cells, 0 DSP-class
cells, 2 BRAM-class cells, and about 69.95 MHz post-route Fmax.

## Board Pins

- `clk`: H11, 27 MHz board clock.
- `uart_tx_pin`: M11.
- `status_pass`: T9, high after all vectors pass.
- `status_fail`: P9, high after a vector mismatch.
