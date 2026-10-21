# Synthesizable buffer selftest

`rtl/buffer_dma_selftest.v` supplies two hardware packet generators and two
hardware checkers around the real frame_buffer_reference. It is not a physical
board pin top. start is accepted only with start_ready; seed and stalls_enable
are sampled. Every accepted start clears the entire buffer/CSR/monitor state
for one clock before running. Do not submit CSR requests across that clear;
software must treat each run as a new reset epoch.

Default FRAME_COUNT=32 per producer, SLOT_WORDS=256, TIMEOUT=2000000 clocks.
FRAME_COUNT must be even 2..65534; SLOT_WORDS must be a power of two >=16 and
within the buffer's supported range. Length=(frame_id modulo16)+1 full words,
destination=source XOR frame_id bit0. Data is seed XOR (source*0x17351) XOR
((frame_id*0x103397)+(word_offset*0x71A3)), modulo 32 bits. This controlled
pattern is for functional tests, not random-input security qualification.

The checker validates every word, full keep, last, destination/source, frame
length, frame ID sequence separately per source/destination, and base bounds.
Seeded nonzero LFSR state injects producer gaps and independent consumer stalls;
seed=0 maps to LFSR state1 but retains zero for data generation. Valid remains
asserted with stable payload until accepted. A fixed seed/mode repeats the trace.

done and error remain held until another accepted start or reset. checked_words,
check_errors and run_cycles clear per start. error is sticky on payload/metadata
mismatch, writer errors, abort/invalid allocation or watchdog expiry. check_errors
counts bad accepted output words, so watchdog/writer failure can set error with
check_errors=0. Terminal watchdog stops new stream handshakes; restart clears
all pending state. Timeout limits run clocks, excluding the clear cycle.

The CSR port exposes the full telemetry map (csr_map.md). Selftest control and
checker counters are separate top ports pending a board-control wrapper.
probe bits7..0: done,error,out1_valid,out1_ready,out0_valid,out0_ready,
in0_valid,in0_ready. This fixed page is intended for initial board diagnostics;
the configurable probe-page shell is a separate integration step.

Run `python cores/storage/buffer_dma/tools/test_selftest.py` after env.ps1.
Evidence selftest_20261020T164308156793Z: four runs, 2176 accepted words total,
Python independent per-word/routing/key-set checks; exactly one injected data
corruption detected. Runs1/4 have identical full traces and cycle counts after
restart; run2 disables stalls. Separate forced-stall test verifies watchdog at
exactly64 clocks with zero received words and an error. All pass. These are
simulation checks, not physical 25K acceptance or sustained board throughput.

Timing repair: writer reference products now use incrementing frame/word terms
instead of recomputing constant multiplies per word. Reader reference terms
advance separately per source/destination,with accepted actual/expected values
registered before comparison. The mathematical pattern and ordering are unchanged.
Completion drains the comparison-valid stage; watchdog/error semantics remain.
Regression selftest_20261020T170735387519Z verifies all2176words,one injected
error,replay/restart and watchdog after this change; control/UART regression
control_20261020T170744890799Z also passes. The old resource report above predates
this repair and BSRAM descriptor mapping. Updated physical timing is pending.

Default GW5A synthesis PASS: selftest_synth_20261021T004327729.
8416 LUT1..4 (259/1708/2504/3945),2063 ALU,728 MUX2_LUT5,5025 FF,
34 RAM16SDP4 distributed RAM,2 SPX9 synthesis cells,zero DSP. Includes full
buffer,monitors,slot lifetime,CSR snapshot and generator/checker; not physical
resource accounting. There are225 internal port bits, so a narrow physical
wrapper is still needed before placement/routing. No Fmax/board claim.
