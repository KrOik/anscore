# Bounded qualification status

Implemented only within this directory: `dsp_chain_harness.v`, `chain_ram.v`,
`protocol.py`, `tb_chain.sv`, `tb_fault.sv`, `run.py`, `run_board.py`,
`audit_build.py`, `test_audit.py`, and README.
Shared algorithm sources and the existing physical runner were not modified.

Commands executed from repository root:

```
python cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/run.py --build
python cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/run.py --dc-source cores/signal_processing/dsp_isp_library/dsp/dc/candidates/registered_output_v3/dc_stream.sv --dc-latency 2 --build
python -m py_compile cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/protocol.py cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/run.py cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/run_board.py
python cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/run_board.py --help
```

DC latency1 snapshot: `evidence/chain_20260925_034743_100379/`.
UART simulation and fault tests PASS: 577 complete 128-bit results plus flags,
10 blocks, six invalid requests, 110 rejected report corruptions. Full-rate
64-sample blocks take 66 RUN clocks. Noalu synthesis/route/pack PASS:
7886 LUT1–4, 3 MULT18X18, 6 BRAM, final routed Fmax 81.50 MHz.
`chain.fs` SHA256:
`0fbaa92eae7cb382042b31e5a4b9fc59d5d4b13bf352a59f6bb829b64545a7a7`.

DC latency2 candidate snapshot: `evidence/chain_20260925_035056_409839/`.
Same UART/fault matrix PASS; full-rate 64-sample blocks take 67 RUN clocks.
Noalu synthesis/route/pack PASS: 7476 LUT1–4, 3 MULT18X18, 6 BRAM,
final routed Fmax 84.27 MHz. `chain.fs` SHA256:
`5acd51f53d3dd984ce53355f6a06a79231910746e6f35a8443191bf2f60def64`.

Both saved mapped netlists independently pass `check -assert` with zero
problems. Full Yosys/PNR log audits pass; PNR has no warnings. Yosys warnings
are explicit statistics arrays lowered to registers and ABC combinational
partition/carry-box notes, not logic loops. The first conservative audit rejected
these ABC informational notes; that FAIL audit is preserved in audit_history.
No logic-loop, latch-inference or missing-clock/constraint diagnostics exist.
`structural_audit.json` binds reviewed logs and netlist by hash; `run_board.py`
checks this before taking the board lock. New builds also run `check -assert`
directly after synthesis. Default DC latency is now obtained from the production
manifest, with an exact source-hash check; current production is the same v3
source as the qualified frozen candidate. No identical-source rebuild was done.

Python syntax/help and an offline replay using the exact frozen latency1
protocol/reference models PASS. No board programming or capture was performed
by this task. Route acceptance is not physical numerical acceptance.

Executable structural-gate mutations PASS in
`evidence/audit_negative_20260925_035959_003355/summary.json`: separate copied
build reports with injected logic-loop, inferred-latch and no-clock warnings
were all rejected. Command:
`python cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/test_audit.py cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/evidence/chain_20260925_035056_409839`.
Production DC source and manifest exactly match the frozen v3 build source.

## RMS physical failure follow-up

The original DCv3/statistics1 chain later failed the parent's full-rate physical
test: RMS alone differed; other data fields/flags and serial/LA agreed. The same
host input failed after reprogramming with different erroneous RMS values;
stall=7 passed. This is a physical failure despite prior RTL/tool PASS results.
Original artifacts and expected data are preserved. Production statistics stays
unchanged.

New candidate selection: `--statistics-source <statistics_stream.sv>` requires
explicit `--stats-latency`; default remains production statistics1.
`--vector-json` replays original inputs and recomputes expected data. Cycle oracle
models the combined DC/statistics per-stage elasticity. Frozen legacy reports
remain supported by `run_board.py`.

The isolated `dsp/statistics/candidates/sqrt_pipeline4/` candidate has total
statistics latency5 and removes the old unregistered RMS arithmetic. Full UART
matrix and strict build PASS at `evidence/chain_20260925_040649_856760/`:
7685 LUT, 3 DSP, 6 BRAM, final routed tool Fmax149.70 MHz. Total chain latency7,
64 full-rate inputs take71 RUN clocks. Source/final image hashes, full-log
structural audit and mapped root-register/old-RMS-removal proof are saved there.
Original-input UART replay PASS at `evidence/chain_20260925_040901_161923/`.
No board operation was performed by this agent; parent owns physical re-test.
`run_board.py` and `protocol.py` are frozen for that test round.

## 2026-09-25 main-agent physical re-test: RESOLVED via sqrt_pipeline16

Physical sessions (COM24, FX2 4 MS/s, fresh SRAM each run):

- `chain_20260925_040649_856760` (sqrt_pipeline4, stats_latency5):
  `artifacts/dsp_isp_20260925/dsp_chain_sqrt4_board_01/` FAIL, 57/64 RMS fields
  wrong at stall0, wrong only in record bits[42:32] (rms[10:0]);
  `dsp_chain_sqrt4_stall_01/` FAIL 56 records at stall1;
  `dsp_chain_sqrt4_stall7_01/` FAIL only index3, rms=2047.
- `chain_20260925_042134_163385` (sqrt_pipeline16, stats_latency17):
  `artifacts/dsp_isp_20260925/dsp_chain_sqrt16_board_01/` PASS all11 cases;
  `dsp_chain_sqrt16_board_02/` PASS all11 cases on second SRAM program.
  Includes the original failing host vector replayed bit-exact.

Root cause established: the radix-4 `root_four` four-iteration combinational
chains did not settle within one 27 MHz cycle on real silicon (tool Fmax was
optimistic), corrupting late (low) root bits; and stage0 evaluated `leaf_data`
combinationally at its update edge, so the largest simultaneous radicand
transition (0x3FF0F801 -> 0x00000009) was captured as the blend 0x3FF009,
giving the deterministic rms=2047 that survived stall7. One restoring
iteration per register stage removes both failure modes on hardware.
The 16-stage candidate is now the physically qualified statistics variant for
this chain; production `dsp/statistics/rtl/statistics_stream.sv` is unchanged
and its own DSP-04 re-qualification remains a separate ledger item.
