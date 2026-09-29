# Hybrid Lattice NTT Validation Log

Date: 2026-05-26
Board: SiPEED Tang Primer 20K

## Current Generated Artifact

Bitstream:

```text
cores/crypto/hybrid_lattice_ntt/build_oss/hybrid_lattice_ntt_20k_state_equiv_trimmed.fs
```

SHA-256:

```text
D0B7668931F046D619BE35B1F36FAE345EE9C8C7A190CD21AF8E229D8FBE8E89
```

This artifact has been synthesized, placed, routed, and packed for
`GW2A-LV18PG256C8/I7`. It has not yet been programmed to the physical board in
this pass, and there is no fresh UART capture for this exact `.fs`.

The current top-level bundle keeps:

- legacy serial NTT self-test and UART comparator line
- OPS4 and bounded FLOW scheduler digest reports
- lightweight systolic issue/control-plane self-test
- coefficient-state-equivalence systolic NTT/INTT monitor

The older `ntt256_systolic_full_stream_monitor` is no longer instantiated in
the placed top-level bundle. Its simulation/log evidence remains historical
slot-stream evidence, but it is not part of the current trimmed bitstream.

## Current Simulation Evidence

Focused monitor simulation:

```text
tb_ntt256_systolic_state_equiv_monitor PASS issue=4608 output=4608 bubbles=0 signature=0b1a0306
```

Trimmed top-level status simulation:

```text
tb_top_status_report PASS syst_sig=0b1a0306 syst_bubbles=0000 syst_issue=1200 syst_output=1200 pipe_bubbles=0000 pipe_pairs=ffff
```

The state-equivalence monitor covers four transform slots and reproduces the
trusted scheduler digests:

- KEM NTT: `1E664367`
- DSA NTT: `7FC8E2FC`
- KEM INTT: `B88A6C64`
- DSA INTT: `D23ECEF9`

The trimmed UART contract expected from this bitstream is:

```text
N256 PASS D=2F9C94AD C=0000979A
OPS4 PASS D=444A5032
FLOW PASS K=EDAA6354 D=E9B06052
PIPE PASS B=0000 P=FFFF
SYST PASS D=0B1A0306 B=0000 I=1200
```

This expected UART report is simulation-backed, not yet board-captured for the
trimmed `.fs`.

## Build Evidence

Yosys hierarchy/check reported:

```text
Found and reported 0 problems.
```

The pending `y1` writeback queue is mapped into Gowin block RAM:

```text
mapping memory top.state_equiv_monitor.pending_y1_hi via $__GOWIN_DP_
mapping memory top.state_equiv_monitor.pending_y1_lo via $__GOWIN_DP_
```

The untrimmed bundle that kept both the older full-stream monitor and the new
state-equivalence monitor failed placement:

- LUT4: 16704 / 20736
- DFF: 4949 / 15552
- BSRAM: 12 / 46
- nextpnr error: `Unable to find legal placement for all cells`

The accepted trimmed bundle passed nextpnr:

- LUT4: 15998 / 20736
- DFF: 4412 / 15552
- ALU: 4104 / 15552
- BSRAM: 12 / 46
- Final max frequency: 84.75 MHz
- 12 MHz target: pass

gowin_pack generated:

```text
cores/crypto/hybrid_lattice_ntt/build_oss/hybrid_lattice_ntt_20k_state_equiv_trimmed.fs
```

Pack warnings were apycula performance warnings about missing `numpy`,
`msgspec`, and `fastcrc`; they were not functional pack errors.

## Historical Board Evidence

The latest physical UART capture in
`artifacts/experiments/systolic_full_stream_20260525/uart_full_monitor_3s.log`
belongs to the previous full-monitor bitstream, not the current trimmed
state-equivalence bitstream. It reported:

```text
N256 PASS D=2F9C94AD C=0000979A
OPS4 PASS D=444A5032
FLOW PASS K=EDAA6354 D=E9B06052
PIPE PASS B=0000 P=FFFF
SYST PASS D=EF556C7C B=0000 P=FFFF
FULL PASS D=C4090C17 B=0000 O=0C00 L=0017
```

That historical capture remains useful evidence for the older lightweight
`FULL` monitor, but it must not be cited as physical evidence for
`hybrid_lattice_ntt_20k_state_equiv_trimmed.fs`.

## Claim Boundary

The current artifact supports this claim:

The project has a synthesized, placed, routed, and packed board-visible monitor
that checks coefficient-state equivalence for four 256-point ML-KEM/ML-DSA
NTT/INTT transform slots through the systolic arithmetic pipe, with 4608
issued slots, 4608 outputs, zero invalid output bubbles, and final digests that
match the trusted scheduler.

The current artifact does not support these stronger claims:

- no fresh physical UART evidence for the trimmed state-equivalence `.fs` yet
- no production coefficient-moving systolic NTT/INTT array yet
- no board-measured throughput claim for a complete numerical systolic array
- no complete ML-KEM-768 or ML-DSA-44 top-level engine yet
- no masking, randomized control flow, TVLA, or formal glitch evidence yet

## Next Validation Step

Program the trimmed bitstream:

```powershell
openFPGALoader -b tangprimer20k cores\crypto\hybrid_lattice_ntt\build_oss\hybrid_lattice_ntt_20k_state_equiv_trimmed.fs
```

Then capture UART at 115200 baud and verify the five-line trimmed report ending
with:

```text
SYST PASS D=0B1A0306 B=0000 I=1200
```

## Addendum 2026-10-08: Zero-Switch Chain Proven in Simulation, Subsystem Sized

This addendum records new evidence and does not modify any entry above. The
board-artifact claims and the Claim Boundary section above still stand as
written; nothing here was programmed to a board.

### What was proven

`hybrid_descriptor_bridge.v` (new) sits between the Task 2 descriptor sequencer
and the Task 1 coefficient-state systolic array. The sequencer holds an
initiation-interval-1 contract and flags any cycle in which it holds a
descriptor while the consumer is not ready; the array is busy for roughly 3000
cycles per operation and only accepts a start while idle. The bridge absorbs a
whole burst into a FIFO and grants `start` combinationally on
`array_start_ready`, which is what makes the accept land on the first edge that
can honour it.

Two new composition benches:

- `sim/tb_ntt256_systolic_zero_switch_chain.v` -- sequencer -> bridge -> state
  array, two descriptor bursts (17 descriptors covering all 16 ordered
  adjacent operation pairs, and 32 descriptors), every completion checked
  against the frozen digests `1E664367 / 7FC8E2FC / B88A6C64 / D23ECEF9`, plus
  seven negative checks N1..N7 (zero-length burst, unsupported opcode,
  over-push, late consumer, healthy consumer, array error, producer starvation).
- `sim/tb_ntt256_systolic_chained_roundtrip.v` -- the array with `auto_init`
  low throughout and coefficients arriving through `coeff_load`, four three-op
  chains, `INTT(NTT(x)) == x` folded from the testbench's own load data.

Commands:

```powershell
.\scripts\test_hybrid_lattice_ntt_sim.ps1
```

Verdicts (both benches `$fatal(1)` on any failed check, so a green suite is a
green chain):

```text
burst tag=1 descriptors=17 mask=ffff max_handoff=1 dead=0 underrun=0 seq_bubbles=0
burst tag=2 descriptors=32 mask=c3c3 max_handoff=1 dead=0 underrun=0 seq_bubbles=0
negative N1..N7 done underrun=3
tb_ntt256_systolic_zero_switch_chain PASS pairs=16 streams=2 max_handoff=1_edge dead_cycles=0 underrun=0 negative=7

op=0 accept=12999 last=15784 handoff=257 duration=2785 digest=59139f3c
op=2 accept=15785 last=18853 handoff=1   duration=3068 digest=da72ccee
op=0 accept=18854 last=21639 handoff=1   duration=2785 digest=59139f3c
baseline auto_init=1 durations kem_ntt=3041 dsa_ntt=3041 kem_intt=3324 dsa_intt=3324
tb_ntt256_systolic_chained_roundtrip PASS chains=4 ops_per_chain=3 saved=256 cycles/op handoff=1_edge_no_dead_cycle
```

Read against the baseline, a chained operation costs exactly the 256 cycles of
the `S_INIT` self-pass and nothing else (2785 = 3041 - 256 for KEM_NTT, 3068 =
3324 - 256 for KEM_INTT), and every operation after the first is accepted one
edge after the previous `done`. The `underrun=3` figure belongs to the N7
starvation check and is the detector proving it is not vacuous; both positive
bursts report `underrun=0`.

### Harness changes made in the same pass

- Both benches are now compiled and run by
  `scripts/test_hybrid_lattice_ntt_sim.ps1`; `ntt256_systolic_full_stream_selftest.v`
  and `hybrid_descriptor_bridge.v` were added to its yosys hierarchy check.
- `scripts/export_hybrid_lattice_ntt_metrics.ps1` no longer restates the
  switch-over claims. It re-runs the two benches and publishes what they print
  (`function.zero_switch_chain`, `function.chained_roundtrip`), and throws if
  either verdict is not PASS or the `.vvp` artifacts are absent.
- The same script now splits slice LUTRAM from block RAM. `bram_class_cells`
  was reporting 74 for a netlist that uses 2 block RAMs; the old regular
  expression matched the 72 `RAM16SDP4` LUTRAM instances as well. It now emits
  `bram_class_cells = 2` and `lutram_class_cells = 72`.
- The same script publishes nextpnr's packed utilization table
  (`resource.packed_device_utilization`), because the yosys LUT-class cell sum
  is not the number of LUT4 sites the router occupies.

### Subsystem resource verdict (standalone synthesis, this RTL)

`scripts/measure_hybrid_lattice_ntt_systolic_resources.ps1`, first run:

```text
Module                                  LUTCells ALUCells SliceCells FFCells BRAMBlocks LUTRAMCells DSPCells
ntt256_systolic_state_array                 5886     2169       8055    3172          4          72        0
hybrid_descriptor_bridge                     450      256        706     304          0           0        0
hybrid_zero_switch_descriptor_sequencer      229      227        456     142          0           0        0
SUBSYSTEM TOTAL                          6565.00  2652.00    9217.00 3618.00       4.00       72.00     0.00
Under15kLUT : True   Under15kLUTPlusALU : True   Under4DSP : True
```

The four 256x23 coefficient banks carry `ram_style = block` and map to four
`SDPX9B` blocks; the 72 `RAM16SDP4` instances are the small pipeline-holding
arrays, not coefficient state. No DSP primitive is used: the modular multiply
remains the 23-stage shift-add pipe.

Against the current board top, which reports `lut_class_cells = 13717` and, in
nextpnr's own table, `LUT4: 17281/20736 (83%)` with `BSRAM: 10/46`, the
subsystem cannot be added to that top: 13717 + 9217 = 22934 slice-class cells.
The zero-switch engine therefore fits the 15K/4-DSP target only as its own
top-level that retires the legacy serial core and the existing monitors, not
alongside them.

### Boundaries of this evidence

- Simulation only. Neither `hybrid_descriptor_bridge.v` nor
  `ntt256_systolic_state_array.v` is instantiated in `src/top.v`, so no UART
  report carries any of this and no bitstream in `build_oss` contains it.
- The zero-switch result is bounded by the bridge FIFO depth. The sequencer
  treats a not-ready consumer as a fatal invalid bubble, so a burst longer than
  `DEPTH` cannot be absorbed; the benches use `DEPTH = 64` with 17 and 32
  descriptors. A 4096-descriptor stream needs a credit-controlled sequencer
  port, which is an open design decision, not a measured result.
- The chained bench's forward digests for its loaded vectors
  (`59139f3c`, `4e05fca5`, `ad4d03c3`, `36b3babb`) were derived offline from
  `models/ntt256_systolic_golden.py`; the load vectors themselves are generated
  inside the bench, so re-deriving those four constants requires feeding the
  bench's load data to the model by hand. That is a harness gap, not a claim.
- Throughput is stated in cycles at simulation time. No board-measured
  frequency exists for this subsystem; the top-level design routes at 68.58 MHz
  against a 12 MHz target, which says nothing about the array's own critical
  path.

