# Block harness handoff — 2026-09-25

## Physical diagnosis update

Parent subsequently reports inferred-RAM identity passed320 physical words,
while explicit-RAM DC still failed the original numerical vector. This does
not establish an unconditional RAM defect; arithmetic/layout/timing remains
under investigation. No arithmetic golden or expected data was changed.
New optional source/latency bindings support isolated algorithm candidates.
DC mean_narrow_3237f607 with original inferred RAM passed same UART/negative
suite and build in `dc8_inferred_20260925_025755_339428`:2560 LUT,3 DSP,
69.43MHz final tool estimate, latency1. Physical comparison is parent-owned.
Four-stage CSC8 isolated candidate with the same inferred RAM passed all UART
and negative tests and strict build in
`csc8_inferred_20260925_031306_002825`:4055 LUT,0 DSP, final tool estimate
73.64MHz, latency4. Source is `isp/candidates/pipeline4/csc_stream.v`;
production CSC is unchanged. Host must bind latency4 from this image's
simulation_summary/build_summary, not use it with prior one-cycle captures.
CSC10 from identical frozen source likewise passed in
`csc10_inferred_20260925_031627_439716`:4703 LUT,0 DSP,66.93MHz final tool
estimate, latency4. Both preserve12 CSC configurations, actual SOF/EOL export,
full-rate and controlled stalls, five invalid request tests and fault harness.

Parent reported DC and CSC8 numerical mismatches with matching LA/COM raw
responses; these are preserved physical failures, not accepted board results.
Shared algorithm cores/golden remain unchanged. Original inferred SDPX9B RAM
is a suspect under the repository SOP T9 warning, not a proven cause yet.
Added CORE=2 identity to isolate the exact transport/storage/replay path.
Both diagnostics passed independent random32-bit,64-word,stall0/1/7 UART
simulation, fault tests and strict noalu27MHz build:

| Identity diagnostic evidence directory | LUT / DSP | Final estimated MHz |
|---|---:|---:|
| identity8_20260925_024758_393920 | 541 / 0 | 218.44 |
| identity8_explicit_20260925_024943_177082 | 548 / 0 | 239.01 |

First uses original inferred RAM; second uses four measured-wiring DPX9B
18-bit banks total. Their raw identity protocol and independent expected
words are identical. Original source snapshots and all failed evidence remain.
Diagnostic building did not perform physical operations or alter CSC/DC RTL.

Algorithm candidates using MEM_IMPL=1 also passed the unchanged numerical
oracle, all UART/fault tests and build gates:

| Candidate evidence directory | LUT / DSP | Final estimated MHz |
|---|---:|---:|
| dc8_explicit_20260925_025050_139396 | 2868 / 3 | 94.97 |
| csc8_explicit_20260925_025037_256366 | 3711 / 0 | 214.13 |

Commands: `python cores/signal_processing/dsp_isp_library/board/block_harness/run.py --core
identity --mem explicit --build` (replace identity by dc or csc). Each has
its own block.fs/build_summary/source snapshots. These are ready for parent
physical diagnosis; they are not asserted to repair the observed failures.

## Initial implementation handoff

Final RTL, real serial-line simulation, independent response verification,
strict resource-gated noalu synthesis, 27 MHz nextpnr and bitstream packing
PASS for DC, CSC8 and CSC10. This subagent performed no JTAG/serial/LA hardware
operations. Board acceptance belongs to the parent's fresh physical evidence.

| Final evidence directory (under evidence/) | LUT1–4 / routed LUT4 | DSP | BRAM | Final tool Fmax MHz |
|---|---:|---:|---:|---:|
| dc8_20260925_024141_026470 | 2850 / 2850 | 3 MULT18X18 | 1 DPX9B + 2 SDPX9B | 57.86 |
| csc8_20260925_024117_132038 | 3731 / 3731 | 0 | 2 SDPX9B | 178.13 |
| csc10_20260925_024128_223094 | 4485 / 4485 | 0 | 2 SDPX9B | 170.68 |

Each final directory contains `block.fs`, `build_summary.json` with image
SHA256, RTL snapshots/hashes, input byte streams, actual raw serial output,
independent numerical/identity/config/count/cycle verdicts, five invalid
request tests, fault.log and full build/route/pack logs. `independent_models/`
archives the unchanged host models and hashes. Fmax is an implementation tool
estimate, not measured silicon Fmax; target clock stays 27 MHz. All final
images meet the 15K LUT / 4 DSP limits. Resource table is whole board wrapper,
not isolated core. No physical acceptance claim is made here.

Numerical cases: DC blocker, running mean lengths1/8/64, baseline; CSC all
twelve configuration modes at each sample width. Each has a single-word
transaction then maximum64-word blocks, replay stall patterns0/1/7, sequential
packets and independent raw values. CSC result bit31 and bit30 capture the
actual core output SOF/EOL, including stalled/single-word boundaries.
Every accepted result and every replay cycle count is checked. Ten byte
corruption positions per block are rejected by the host verifier.

Negative UART packets: count0, count65, stall8, illegal mode, reserved config.
Fault TB: truncated payload emits nothing; bad stop discarded; unexpected
busy RX after flags byte persists into next report; forced watchdog boundary
with simultaneous result capture reports/copies that result consistently.
BusyRX is sticky until POR. Invalid config leaves no processed output. The
fault TB uses internal force only to reach watchdog in bounded simulation;
this is not evidence of fault injection on silicon.

Reproduce from repository root:

```
python cores/signal_processing/dsp_isp_library/board/block_harness/run.py --core dc --build
python cores/signal_processing/dsp_isp_library/board/block_harness/run.py --core csc --bits 8 --build
python cores/signal_processing/dsp_isp_library/board/block_harness/run.py --core csc --bits 10 --build
```

Changed files exclusively here: block_harness.v, protocol.py, tb_block.sv,
tb_fault.sv, run.py, README.md, STATUS.md and append-only evidence directories.
Frozen shared CSC/DC/Stream/UART implementations remain unchanged. Earlier
failed synthesis (two inferred input RAM read ports) was preserved; final
code uses one address mux and one synchronous RAM read. Earlier successful
images lacking sideband export or sticky-error repair remain historical,
and must not substitute for these final evidence directories.

Known limits: <=64 input words, one image row per CSC block, per-block DC
state reset, no load/replay overlap, no receive timeout or arbitrary corrupted
byte-stream resynchronization. UART loading/export rate is separate from
full-clock RAM replay. It is not a full-frame camera or unbounded DSP host
stream. Host must wait for each complete response and reject nonzero flags.
