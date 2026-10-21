# Current validation

Memory exchange regression: artifacts/buffer_dma_25k/memory_20261020T161025769194Z.
PASS: two writers/two readers concurrently exchange 64 test-owned 16-word blocks,
1024 complete readback words, 2048 memory transactions in 3103 simulated cycles.
Independent Python byte/word golden and stream CRC32: source0=67CA9259,
source1=2026641C. Per-channel request/completion/stall counters checked.

Random backend and response backpressure, held request/response stability,
partial/zero byte writes, unaligned/out-of-range/high-bit rejection, no address
alias, reset-persistent RAM, reset of a buffered response and abortion of an
unaccepted backend write all pass. Test ownership prevents buffer hazards;
it does not prove an RTL frame scheduler exists.

The 8192 aggregate read+write payload bytes /3103 cycles is a simulation traffic
measurement (2.6400 byte/cycle), not board bandwidth. It includes both directions
and is not useful-data read-only throughput. No physical clock/Fmax is inferred.

Isolated GW5A synthesis: artifacts/buffer_dma_25k/synth_20261021T000943351.
PASS: reference DEPTH256, 882 LUT1..4,316 ALU,630 FF,1 SPX9 synthesis cell,
0 DSP. SPX9 is not a routed physical BSRAM count. Wide internal reference ports
are not board pin assignments. No P&R, Fmax, physical DMA or SDRAM claim.

Overall IP-02 is OPEN. Only the memory/arbiter foundation is simulation-tested
and synthesis-tested. L3/L5, frame descriptors/rings, RTL ping-pong ownership
and stream block mover remain unaccepted.

New ownership stage: descriptors_20261020T161532629851Z PASS depths2/4/8/32
with5802/5991/5995/6019 ordered descriptors; full replacement, wrap, stalls,
reset/prefetch invalidation. Slots fixed/shared modes PASS respectively in
slots_20261020T162244725220Z and slots_20261020T162246630710Z. Each64 frames,
544 complete words,272 words per consumer, CRC E3AE5E67/653C99DC. RTL owns
slots and descriptor publication/release; payload transactions remain TB-driven.
Tests cover all4 slots under pressure, early done guard, allocation response
stalls, invalid lengths, writer abort, reader error and partial/queued reset.
Isolated GW5A default fixed manager synthesis PASS:399 LUT1..4,150 ALU,514 FF,
34 RAM16SDP4 distributed RAM cells,0 DSP/BSRAM cells; no P&R/Fmax. These count
only the controller/descriptor queues, not payload RAM or memory arbiter.
See frame_descriptor.md. Block mover and physical acceptance remain OPEN.

Word DMA module: PASS both directions, 127 words each; evidence artifacts/buffer_dma_25k/word_dma_20261020T162814789558Z. Command: python cores/storage/buffer_dma/tools/test_word_dma.py. See word_dma.md for scope and limits. No synthesis or board execution.

Autonomous frame_buffer_reference: python cores/storage/buffer_dma/tools/test_frame_buffer.py PASS both allocation modes, each 64 frames / 544 words, independent Python golden CRC E3AE5E67 / 653C99DC. Evidence artifacts/buffer_dma_25k/frame_buffer_20261020T163019983869Z. Synth evidence frame_buffer_synth_20261021T003049230: 1537 LUT1..4 + 675 ALU + 34 RAM16SDP4, 1498 FF, 2 SPX9, 0 DSP; no physical PPA. See frame_buffer_reference.md.

Stream metrics integration PASS: test_frame_buffer.py, evidence frame_buffer_20261020T163230837440Z, both modes 64 frames/544 words each. Hardware cumulative/final-frame CRC verified with Python zlib on all four channels. Independent monitor test tb_frame_stream_monitor PASS standard CRC CBF43926, byte masks, exact stalls/duration, reset; evidence monitor_20261021T003254896. Prior synthesis predates monitor hardware; current resource impact unmeasured.

Slot telemetry integration: python cores/storage/buffer_dma/tools/test_frame_buffer.py
PASS both modes, evidence frame_buffer_20261020T163433254741Z; exact independent
allocation-to-read-completion timestamps, min/max/sum/last, allocation stalls,
elapsed cycles and peak occupancy checked. python cores/storage/buffer_dma/tools/test_slots.py
PASS, evidence slots_20261020T163435974680Z. Current full-subsystem synthesis:
frame_buffer_synth_20261021T003504334, synth_gowin -family gw5a,
4267 LUT1..4 +1520 ALU +511 MUX2_LUT5 +34 RAM16SDP4, 2977 FF, 2 SPX9,
zero DSP. This includes monitors and slot timing; no routing/physical resource
or Fmax claim. Wide internal ports still require a physical wrapper.

Coherent telemetry CSR: frame_buffer_20261020T163653168562Z PASS both DMA modes,
integrated capture/readback and response stalls. Independent CSR test evidence
csr_snapshot_20261021T003720599 PASS WORDS=1/51/60, two generations each, all words
against changing live values, malformed accesses, stalls and reset. Commands:
python cores/storage/buffer_dma/tools/test_frame_buffer.py; iverilog -g2012 -s
tb_csr_metrics_snapshot -P tb_csr_metrics_snapshot.WORDS=51 -o work/csr.vvp
cores/storage/buffer_dma/rtl/csr_metrics_snapshot.v
cores/system/stream_bus_library/rtl/sys_register_snapshot.v
cores/storage/buffer_dma/tb/tb_csr_metrics_snapshot.v; vvp work/csr.vvp.
No synthesis this step; previous resource figures exclude the CSR snapshot bank.

Full CSR export and host decoding: frame_buffer_20261020T164020805862Z PASS both
allocation modes, 64 frames/544 payload words each, all 51 snapshot registers
read through CSR and checked stable against captured values; ID verified before
and after reads. Snapshot/decoded JSON saved for each mode, source hashes include
decoder. Commands: test_frame_buffer.py; decode_metrics.py --self-test; CLI decode
fixed1_snapshot.json -> cli_decoded.json PASS. Self-test covers byte/ID wrap,
coherence, epoch mismatch, invalid clock, malformed schema, long/zero intervals,
elapsed inconsistency and impossible bandwidth. No new RTL or synthesis this
step (testbench and host tools only); CSR resource impact remains unmeasured.

Synthesizable dual-generator/checker: test_selftest.py PASS, evidence
selftest_20261020T164308156793Z. Four runs /2176 checked words with independent
Python golden, exactly one injected mismatch, identical seeded replay after
restart. Separate watchdog harness PASS 64-clock forced-consumer-stall expiry.
Post-integration regressions: test_word_dma.py PASS both directions,
word_dma_20261020T164516829312Z; test_frame_buffer.py PASS both modes plus full
CSR export, frame_buffer_20261020T164518621539Z. No board download this step.

Selftest synthesis completed PASS: selftest_synth_20261021T004327729,8416 LUT1..4 +2063 ALU +728 MUX2_LUT5 +34 RAM16SDP4,5025 FF,2 SPX9,0 DSP. No routing/Fmax/physical board evidence.

Control/board wrapper simulation: test_control.py PASS, control_20261020T164916960321Z.
Direct CSR verifies stable routed responses under stalls, configuration guards,
run/restart and prior-snapshot invalidation. Full serial top verifies UART8N1,
command/reply CRC,seed,start/completion,checked words,snapshot counts and RO errors.
No hardware download. Route/pack build started board_20261020T164928239302Z;
consult its authoritative summary for terminal result. Physical25K acceptance
and hard runtime JTAG remain open; current connected20K is untouched.

First narrow25K route FAILED: board_20261020T164928239302Z, RAM16SDP4 queue
placement unsupported. Preserve failure; packed resource estimate alone did not
prove routeability. Forced manager descriptor rings to synchronous block RAM.
Post-change test_slots.py and test_control.py PASS; slots_20261020T165633859740Z,
control_20261020T165639846902Z. Second build board_20261020T165642947154Z remains
live in exec session18749. No25K download or new hardware acceptance.

Second build board_20261020T165642947154Z FAILED50MHz timing after successful
placement/routing,31.65MHz Fmax. Physical utilization log:11272LUT4,5280DFF,
10BSRAM,11IOB,0DSP; timing failure means this is not an accepted implementation.
Critical path crosses selftest expected-pattern arithmetic to sticky error.
Changed generator/checker reference products to incremental terms and registered
comparison. test_selftest.py PASS (2176words,one injectederror,watchdog,restart),
selftest_20261020T170735387519Z; test_control.py PASS direct/serial control,
control_20261020T170744890799Z. Third build board_20261020T170749474314Z is live
in session94223. Clock target remains50MHz; no hardware download.

Third build board_20261020T170749474314Z FAIL timing,43.23MHz routed Fmax at50MHz
requested. Expected-pattern timing fix improved31.65->43.23MHz; next critical path
is timestamp subtraction combined with latency sum. Added one-clock registered
delta before min/max/sum updates (physical latency endpoints unchanged).
test_frame_buffer.py PASS exact independent timestamps,bothallocationmodes,CSR
and allpayload/CRC; frame_buffer_20261020T171542841254Z. test_control.py PASS,
control_20261020T171544969679Z. Fourth build board_20261020T171548136931Z remains
live in execsession90691. No target-clock reduction or board download.

Fourth narrow25K build ACCEPTED for build/timing,not physicalboard:
board_20261020T171548136931Z synthesis/placement/routing/pack allPASS,final
pnr_report.json Fmax56.67970275878906MHz meets50MHz. Final routed JSON resources:
9306LUT4,2462ALU,5798DFF,10BSRAM,11IOB,643MUX2_LUT5,2MUX2_LUT6,0DSP/PLL.
The earlier pack-stage9092LUT4 figure is superseded by final routed9306.
Packedbuffer_dma.fs SHA256:
8d756518bb3aef061aacdf25d4f3c21ae3a2a4563d109996ec822e38a3b2926b.
All source/CST/build-script hashes and image hash revalidated against current
files,PASS. Physical PPA saved ppa.json and PPA_BOARD_25K.csv. No download;
UART/LA/stability/runtimehardJTAG physical acceptance remainsOPEN.
