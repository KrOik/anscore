# External DC → statistics qualification harness

This isolated board top accepts actual host samples through UART, stores them
in a synchronous 64×16 RAM, then replays into `dc_statistics_stream` at full
rate or controlled output stalls. A synchronous 64×136 RAM captures every full
128-bit statistics record and its two flags. Nothing is reduced to a digest.
No physical acceptance is implied by a simulation or route result.

Request: ASCII `DSC1`, tag u32 LE, config u32 LE, count u8 (1..64), stall u8
(0..7), then count signed16 LE samples. Config bits 1:0 DC mode (0 blocker,
1 mean, 2 baseline), 17:2 pole, 21:18 DC window log2, 25:22 statistics log2
(0..6); bits 31:26 must be zero. Statistics are sliding, scale=0,
threshold=0x10000000. Each packet resets both algorithm histories before config.

Response: ASCII `DST1`, tag/config echoed, result count u8, error flags u8,
accepted input count u8, captured output count u8, RUN cycles u32 LE, followed
by count records of 16 data bytes LE and one flag byte (bits 7:2 zero).
Data fields from MSB to LSB: position32, meanpower32, meanabs16, floorRMS16,
earliest-tie peak16, latest amplitude16. Result flags: bit0 clipping, bit1
threshold. Header errors: bit0 invalid count/stall, bit1 framing, bit2 busy RX
(sticky until power-on reset), bit3 invalid config, bit4 watchdog (4096 cycles).
Watchdog returns precisely the outputs captured, including its terminal edge.

Host must await the complete response before sending another packet. Invalid
count/stall returns an empty report immediately after the header; invalid config
consumes payload then returns empty. A truncated request does not execute and
requires power-on reset; this protocol deliberately has no receive timeout.
Bad stop bytes are discarded. No load/replay overlap. Stall policy is
`RUN_cycle % 8 >= stall`, starting at cycle zero. Cycle oracle models individual
elastic stages (DC 1 or 2 stages, configured statistics depth), not a global
pipeline enable. Full-rate RUN cycles equal sample count plus DC latency plus
statistics latency. Default production statistics latency remains one.

Run from repository root:

```
python cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/run.py --build
python cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/run.py --dc-source cores/signal_processing/dsp_isp_library/dsp/dc/candidates/registered_output_v3/dc_stream.sv --dc-latency 2 --build
python cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/run.py --statistics-source cores/signal_processing/dsp_isp_library/dsp/statistics/candidates/sqrt_pipeline4/statistics_stream.sv --stats-latency 5 --build
```

The build runner freezes sources, independent reference models, hashes,
stimulus, reports, negative logs, netlist and bitstream in a fresh evidence
directory. It first tests real 115200 UART bit timing and all output bytes:
N=1/16/64 × stall=0/1/7, each 64 samples, plus a one-sample extreme packet.
Six invalid packets, truncated input, malformed stop, late busy byte and forced
watchdog/capture coincidence are checked. Controlled corruptions must be rejected.
Default DC latency comes from `dsp/dc/ip_manifest.json`, and its source SHA must
match. An explicit candidate requires `--dc-latency`.
An explicit statistics candidate requires `--stats-latency`. `--vector-json`
replays saved host input through real UART simulation with recomputed goldens.
Only after simulation passes does it use `synth_gowin -noalu -family gw2a`,
enforce ≤15000 LUT-class cells and ≤4 DSPs, route with the real 27MHz timing
constraint (no timing-ignore), check routed LUT/Fmax, run mapped-netlist
`check -assert`, audit complete synthesis/PNR logs, and pack SRAM image.
Structural audit rejects warnings except documented statistics array lowering
and ABC combinational partition/carry notes; logic-loop, inferred-latch and
missing-clock/constraint reports always fail. Saved builds can be audited without
resynthesis using `python cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/audit_build.py <build>`.
Pin map: H11 clock, T13 UART input, M11 output mirrored to A11/FX2 D0.

Physical runner (only one owner may execute; not run by harness author):

```
python cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/run_board.py --build <evidence-directory> --output <fresh-artifact-directory> --port COM24
```

It uses exclusive repository `.boardlock`, SRAM-only `program_probe.ps1`, checks
frozen source/image/resource/timing identity, recomputes expectations with frozen
host models, waits for positive live FX2 transfer evidence before injection, and
requires complete fresh logic-analyzer UART reports. Serial reads are diagnostic.
Each case has a fresh random tag and sample tail. `--vector-json` accepts saved
objects with config, signed16 words and stall; expected data is always recomputed.
