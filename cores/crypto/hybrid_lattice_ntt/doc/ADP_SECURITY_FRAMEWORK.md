# ADP-Security Evaluation Framework

This document defines the evaluation surface for the hybrid lattice security
engine. The current design only fills functional unprotected NTT/INTT milestone
rows.

## Metrics

Area:

- LUT-class cells from synthesized JSON.
- FF-class cells from synthesized JSON.
- DSP-class cells from synthesized JSON.
- BRAM-class cells from synthesized JSON.

Delay / throughput:

- PnR maximum frequency.
- Cycles per primitive.
- Useful bits per primitive.
- Throughput in bits per second: `useful_bits * fmax / cycles`.

Power:

- Board-measured current and voltage, when available.
- Tool power estimate, when available.

Security:

- Masking order implemented.
- Randomized control-flow coverage.
- Formal evidence status.
- TVLA fixed-vs-random result.
- TVLA random-vs-random result.
- Trace count and acquisition setup.

Composite scores:

- ADP: `area_lut_equivalent * latency_seconds * power_watts`.
- Area efficiency: `throughput_bps / LUT-class cells`.
- Security gate: pass only if the claimed protection has both formal evidence
  and empirical leakage evidence.

## Current Rows

| Design | Scope | LUT | FF | DSP | BRAM | Fmax MHz | Board self-test | Security gate |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| `serial_zero_dsp` | Serial 256-point dual-mode KEM/DSA NTT self-test with table twiddles and shift-add deterministic initializer | 1960 | 573 | 0 | 1 | 99.18 | PASS, `N256 D=2F9C94AD C=00010E1A` | FAIL: unprotected |
| `two_lane_batched` | Two-lane batched 256-point dual-mode KEM/DSA NTT self-test with one synchronous coefficient memory | 3380 | 843 | 0 | 1 | 85.73 | PASS, `N256 D=2F9C94AD C=0000AF9A` | FAIL: unprotected |
| `dual_bank_batched` | Two-lane batched 256-point dual-mode KEM/DSA NTT self-test with even/odd synchronous coefficient banks | 3853 | 837 | 0 | 2 | 90.86 | PASS, `N256 D=2F9C94AD C=0000979A` | FAIL: unprotected |
| `scheduled_dual_bank` | Operation-scheduled dual-bank two-lane KEM/DSA NTT self-test with explicit unsupported-opcode error handling | 3863 | 842 | 0 | 2 | 90.69 | PASS, `N256 D=2F9C94AD C=0000979A` | FAIL: unprotected |
| `scheduled_ntt_intt` | Operation-scheduled dual-bank two-lane KEM/DSA NTT plus simulation-covered KEM/DSA INTT slots | 3981 | 854 | 0 | 2 | 87.67 | PASS, `N256 D=2F9C94AD C=0000979A`; INTT sim digests `B88A6C64` / `D23ECEF9` | FAIL: unprotected |
| `board_visible_ops4` | Top-level board-visible four-slot KEM/DSA NTT/INTT transform report preserving the legacy NTT line | 7123 | 965 | 0 | 2 | 80.61 | PASS, `N256 D=2F9C94AD C=0000979A`; `OPS4 D=444A5032` | FAIL: unprotected |
| `flow_skeleton` | Scheduler-level bounded KEM/DSA flow skeleton over existing NTT/INTT slots, preserving board-visible OPS4 report | 7224 | 1032 | 0 | 2 | 73.58 | PASS, `N256 D=2F9C94AD C=0000979A`; `OPS4 D=444A5032`; flow sim `EDAA6354` / `E9B06052` | FAIL: unprotected |

The `serial_zero_dsp` row supersedes the earlier 2005 LUT / 573 FF / 3 DSP /
1 BRAM serial row. The improvement comes from removing non-datapath initializer
multipliers; it does not change the NTT digest, cycle count, side-channel
status, or serial architecture caveat.

The `two_lane_batched` row is retained as the single-bank parallel comparator.
It keeps the same digest and zero DSP-class usage, raises LUT-class usage by
1420 cells versus `serial_zero_dsp`, and reduces self-test cycles from 69146 to
44954.

The `dual_bank_batched` row is retained as the pure datapath comparator. It
keeps the same digest and zero DSP-class usage, raises LUT-class usage by 473
cells and BRAM usage by 1 block versus `two_lane_batched`, and reduces
self-test cycles from 44954 to 38810.

The `scheduled_dual_bank` row is retained as the scheduler-only comparator. It
preserves the same board-visible digest and cycle count as `dual_bank_batched`,
adds explicit `KEM_NTT` / `DSA_NTT` opcodes plus unsupported-opcode error
handling, and costs +10 LUT-class cells and +5 FF-class cells versus the pure
dual-bank comparator.

The `scheduled_ntt_intt` row is retained as the simulation-covered INTT-slot
comparator. It preserves the same board-visible NTT digest and cycle count as
`scheduled_dual_bank`, adds `KEM_INTT` / `DSA_INTT` slots, and costs +118
LUT-class cells and +12 FF-class cells versus the scheduler-only comparator.

The `board_visible_ops4` row is retained as the board-visible transform-slot
comparator. It keeps the legacy NTT board line unchanged, executes KEM/DSA NTT
and KEM/DSA INTT slots before top-level pass/fail, and emits `OPS4 D=444A5032`
as a compact board-visible aggregate.

The `flow_skeleton` row is the current research head. It adds bounded
`KEM_FLOW` and `DSA_FLOW` scheduler opcodes that sequence NTT then INTT and
return deterministic scheduler digests `EDAA6354` and `E9B06052`, while keeping
`HYBRID_RUN` unsupported. The cost versus `board_visible_ops4` is +101
LUT-class cells and +67 FF-class cells, with no DSP-class or BRAM-class
increase. It is still unprotected and does not yet implement or board-report a
complete ML-KEM/ML-DSA flow.

## Rules For Future Benchmark Rows

- Compare complete primitives with complete primitives. Do not compare this
  serial NTT milestone against full ML-KEM or ML-DSA accelerators.
- Use the same device family, clocking assumptions, and bit-width accounting
  whenever possible.
- Mark any row as provisional if it lacks either public RTL, synthesis logs, or
  reproducible command lines.
- Separate unprotected, masked, randomized, and masked-plus-randomized variants.
- Record TVLA setup parameters with the result: sample rate, trigger, number of
  traces, fixed input, random input distribution, and threshold.
