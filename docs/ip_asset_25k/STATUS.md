# IP-ASSET-2026-001 V3 execution

Source work order: `C:/Users/29668/Downloads/FPGA_IP_ASSET_WORK_ORDER_25K_V3_20261020.md`.
Full scope IP-00 through IP-10 remains open; IP-11 is reserved, not a 25K gate.

Latest execution: loaded stimulus RAM is integrated at CSR 0x40..0x64 through
source 0 packet fabric and repacker. Three datasets / 290 words (1160 bytes)
match independent Python golden; original three four-source cases retain
440 complete trace words. Evidence replay_20261020T154344672941Z; six component
suites PASS in components_20261020T154317477064Z. New 25K top route/pack PASS:
board_20261020T154348294344Z, 3564 LUT4, 1442 FF, 10 physical BSRAM, 0 DSP,
93.24MHz routed Fmax (requested 50MHz). This image is not downloaded.
Current connected board is user-confirmed Primer 20K, ID0x081B, CMSIS-DAP.
20K pinmap and simultaneous JTAG ID read + LA capture PASS separately in
tang20k_la_calibration_20261020T153612484609Z. No 25K qualification inferred.
Hard-JTAG user-data transport still OPEN; see JTAG_RUNTIME_STATUS.md.
Following older entries are preserved development history.


| Item | Current evidence / remaining work |
|---|---|
| IP-00 | Initial 72-core canonical source/hash index generated. Remaining inventory, licenses, interfaces, dependency graphs and release eligibility audit pending. |
| IP-04-LA pinmap | All eight channels physically confirmed with forward/reverse signatures; see `../../artifacts/tang25k_la_calibration_20261020T151850219242Z/README.md`. This does not pass protocol/load acceptance. |
| IP-04 | Runtime JTAG data/config injection without redownload, probe pages, same-run data readback and stream/protocol LA acceptance pending. Existing ROM-in-bitstream replay alone does not satisfy this gate. |
| IP-01,02,03 | Reuse audit, development and full specified acceptance pending. |
| IP-05,06,07,08,09,10 | Development and specified acceptance pending; physical peripheral claims conditional on actual connected equipment. |

Verified current LA mapping CH0..CH7: G5,F5,G8,G7,H7,H8,J5,H5.
Calibration is 2 MS/s simultaneous digital capture, not full-speed 50 MHz timing proof.
Input voltage rating remains unverified; do not infer analyzer electrical specifications from USB ID.

Preserve four historical CE=1 mismatches: bcd8_encode, event_counter32,
leb128_decode4, round_shift_even32. Preserve UART B3 injection limitation.
Third-party DVI and vendor primitives are not original authored IP.

Probe RTL added at `cores/system/ip_test_shell/rtl/logic_probe8.v`;
1024 page/reset/isolation simulation cases PASS. Not yet synthesized or board qualified.
Catalog now records declarations, dependency lists and acceptance-source hash linkage;
see `catalog_audit.json` for measured counts and `DEPENDENCIES.md` for integration requirements.
All 72 canonical sources match historical evidence hashes: 16 directly in
ACCEPTANCE.json and 56 through its linked simulation source manifest. This
establishes source linkage, not unrestricted board/full-speed qualification.

IP-01 width adapter now supports all 16 ordered 8/16/24/32 combinations by
reusing the canonical byte serializer. Independent golden plus randomized
stall regression passed 128 packets per pair (2048 packets total).
Default 32->24 synthesis passed: 146 LUT1..4 total, 13 ALU, 118 DFFCE,
0 DSP/BSRAM. Routing, Fmax, integrated four-source fabric and board acceptance
remain pending. See test-shell VALIDATION.md and PPA_25K.csv.

Four-source packet composition now implemented and simulated across three
clock ratios/seeds, each 256 packets/7660 bytes with randomized backpressure.
All byte/order/last/keep/stall and trailing-output checks PASS; zero drops.
Integrated module synthesis: 329 LUT1..4, 98 ALU, 223 DFFCE, 1 SDPX9B,
0 DSP. No P&R/physical acceptance yet. Video SOF/EOL and CSR remain pending.
CSR endpoint now exists and passes 27 directed transactions plus eight
back-to-back pipeline cycles; fabric/transport wiring still pending.
Three clock-ratio fault tests also pass atomic oversize discard,
exact capacity, stalled-output reset and clean new-packet recovery.
Digital reset coverage does not replace reset-release CDC/STA qualification.
Latest evidence: fabric_20261020T144201086607Z and
components_20261020T144423892985Z under artifacts/ip_test_shell_25k.
AXI-Lite-to-CSR bridge implemented; 35 writes/68 reads pass independent AW/W
ordering, concurrent traffic, partial writes, error responses and backend/B/R
stalls. Latest component evidence: components_20261020T144844750640Z.
Fabric runner, existing interconnect integration and physical transport remain open.
Runner and CSR core now integrated. Three runtime cases read back 440 complete
trace words / 1304 payload bytes; CRC matches independent zlib golden. Invalid
length and permanent-stall timeout tests pass. Core synthesis: 1246 LUT1..4,
946 ALU, 674 FF, 2 SDPX9B, 0 DSP. Current source is generated data, not host-loaded
stimulus. Physical hard-JTAG runtime loading, routing and LA acceptance remain open.
Evidence: replay_20261020T145434162081Z under artifacts/ip_test_shell_25k.
Current JTAG chain re-detected GW5A-25 ID 0x1281b successfully; no SRAM download this step.
Latest board step: UART/CSR top routed at 50MHz (reported Fmax 100.78MHz),
2356 physical LUT4, 912 FF, 4 physical BSRAM, 0 DSP. SRAM download succeeded;
current SRAM now runs test_shell_top. D2XX UART ID read received zero bytes.
L3 and runtime hard-JTAG acceptance remain NOT PASSED. See test-shell
BOARD_STATUS.md and physical_20261020T150149746040Z failure evidence.
Follow-up actual UART TX acceptance: 95 externally decoded 0x55 frames and
eight D2XX beacon bytes, source/bitstream-bound 2MS/s simultaneous 8CH capture.
User confirmed RX wiring. USB recovered after diagnostic driver hang; GPIO-mode
diagnostic disabled. Latest probe capture is invalid (all high despite live
UART). Current SRAM is isolated UART diagnostic. See LA_TESTPLAN.md for evidence.

Runtime JTAG investigation: local apycula chipdb has no fse_create_jtag;
upstream master function currently guards support to GW2A-18C only, not GW5A.
This is a toolchain support gap, not proof that the GW5A hardware lacks user
scan. Do not substitute a soft GPIO protocol and label it hard JTAG acceptance.
Local Win32_SerialPort enumeration currently exposes only Bluetooth COM3/COM4;
the earlier UART physical limitation must be re-investigated against current USB drivers.

Next: audit source-bound acceptance and dependency manifests, complete IP-00,
then implement the runtime-configurable IP-04/IP-01 reference design.

Commands this step: `python scripts/build_ip_asset_catalog.py`.
Commands added: `python cores/system/ip_test_shell/tools/test_width_adapter.py`,
Icarus probe regression and Yosys GW5A isolated width-adapter synthesis.
Changes isolated to new test-shell RTL/docs and asset catalog tooling; no hybrid RTL edited.

Current update: new wiring verified by forward/reverse frequency signatures in
artifacts/tang25k_la_calibration_20261020T151850219242Z (all eight PASS).
Current SRAM: uart_diagnostic_top, board_20261020T152034213074Z; NOR untouched.
Latest valid capture uart_la_20261020T152118136448Z: 95 TX 0x55 frames,
host received eight 0x55 bytes; B3 RX high throughout host transmission.
Earlier all-high captures used superseded probe constraints and are excluded.

IP-04 host-loaded memory progress: csr_capture_replay wraps canonical RAM unchanged.
Three datasets/24 words plus guards, stalls, reset and timeout recovery PASS;
components_20261020T152714530662Z. Isolated synthesis 296 LUT1..4, 216 ALU,
199 FF, 2 SDPX9B cells, 0 DSP; no P&R/physical block count/Fmax.
Separate aperture not yet integrated into board decoder/fabric or hard JTAG.
See cores/system/ip_test_shell/CAPTURE_REPLAY.md.

IP-04 scan mailbox progress: 72-bit CRC8 transport-neutral user-scan mailbox, toggle CDC, synchronized reset release, busy guards and snapshot responses implemented. scan_20261020T155253230058Z: three asynchronous ratios/156 complete transactions plus three real-fabric loaded datasets/290 words PASS independent host codec/Python golden. Isolated synthesis482 LUT1..4/276FF/14ALU/0DSP/0BSRAM. Hard device primitive, physical JTAG host backend and timing/CDC qualification remain open. Current connected20K is still calibration image; no new download.

IP-01 video contract progress: explicit RGB888 line packet codec added.
video_codec_20261020T160148949646Z PASS: direct and actual fabric paths each
384007 pixels /723 lines (320x240 and640x480 full frames plus boundaries),
SOF/EOL/frame ID and pixel golden exact, zero fabric drops. Codec II1 only
verified separately with128 continuous pixels. Packetizer141LUT/100FF/96ALU,
depacketizer13LUT/44FF isolated GW5A synth; no physical video/Fmax/frame-rate
qualification. Source0 only; frame/source arbitration and RAW remain open.

IP-02 foundation added at cores/storage/buffer_dma: synchronous byte-masked
mem_port plus four-client response-reserved RR arbiter and metrics.
memory_20261020T161025769194Z PASS: two writers/two readers,64 test-owned
blocks/1024 complete words, independent CRC67CA9259/2026641C; contention,
byte strobes,address errors,no alias,reset/response recovery tested.
Isolated GW5A reference synth PASS882 LUT1..4/316ALU/630FF/1SPX9 cell/0DSP,
no P&R/Fmax/physical block count. Frame ownership in this test is TB only;
RTL descriptor/ring/ping-pong/block mover and board IP-02 acceptance remain open.

IP-02 ownership advance: frame_descriptor_ring + frame_slot_manager added.
Four ring depths pass exact capacity/wrap/stalls/reset. Fixed ping-pong and
shared-pool RTL ownership each pass64 frames/544 words through actual BRAM,
independent Python metadata/publication-order/data golden, CRC E3AE5E67/653C99DC.
Evidence slots_20261020T162244725220Z / slots_20261020T162246630710Z.
399 LUT1..4 +34 RAM16SDP4 +150ALU/514FF isolated manager synth,0DSP/BSRAM cells,
no routed count/Fmax. Payload word transfers are still TB-driven; autonomous
RTL block mover/stream integration and physical IP-02 acceptance remain open.

### IP-02 acknowledged word DMA (2026-10-21)
Added rtl/frame_word_dma.v, tb/tb_frame_word_dma.v, tools/test_word_dma.py and word_dma.md under cores/storage/buffer_dma. Command: python cores/storage/buffer_dma/tools/test_word_dma.py (OSS environment). PASS read/write, 127 checked words each, stalled requests/output/completion, invalid descriptors, backend errors and malformed keep/last. Evidence: artifacts/buffer_dma_25k/word_dma_20261020T162814789558Z. No synthesis/resource measurement. This is an autonomous single-descriptor engine; four-slot/two-writer/two-reader integration and 25K physical acceptance remain OPEN.

### IP-02 autonomous stream-buffer integration (2026-10-21)
Changed: buffer_dma_25k rtl/frame_buffer_reference.v, tb/tb_frame_buffer_reference.v, tools/test_frame_buffer.py, frame_buffer_reference.md and status/spec docs. Commands: test_frame_buffer.py (both modes PASS 64 frames/544 words each), yosys synth_gowin -family gw5a -top frame_buffer_reference (PASS). Simulation evidence frame_buffer_20261020T163019983869Z; synth frame_buffer_synth_20261021T003049230. Resources: 1537 LUT1..4 plus 675 ALU/34 distributed RAM, 1498 FF, 2 SPX9, no DSP. No P&R/Fmax/physical board claim. Remaining IP-02 includes internal CRC/latency/bandwidth/overflow instrumentation, CSR, narrow board wrapper and 25K acceptance. Current physical board is still 20K; this does not replace 25K acceptance.

### IP-02 stream telemetry (2026-10-21)
Changed frame_stream_monitor.v, frame_buffer_reference.v, tb_frame_stream_monitor.v, tb_frame_buffer_reference.v, test_frame_buffer.py and docs. Commands: test_frame_buffer.py PASS both modes; iverilog/vvp tb_frame_stream_monitor PASS known CRC and exact stalls/frame-duration. Evidence frame_buffer_20261020T163230837440Z and monitor_20261021T003254896. No synthesis this step; old PPA excludes monitors. Remaining: end-to-end slot latency/bandwidth/overflow policy, CSR, narrow physical wrapper/P&R and 25K acceptance. Passive backpressure counters do not imply data overflow.

### IP-02 slot lifetime telemetry (2026-10-21)
Changed frame_slot_manager.v, frame_buffer_reference.v, both integration/manager
TBs, frame_descriptor.md, frame_buffer_reference.md and validation/changelog.
Commands test_frame_buffer.py and test_slots.py PASS. Evidence
frame_buffer_20261020T163433254741Z, slots_20261020T163435974680Z.
Slot lifetime measured allocation-request handshake through successful read
completion; independent testbench checks last/min/max/sum and exact wait/time
counters. Failed reads/writes excluded. Peak occupied=4, no overflow/drop claim.
Current synthesis frame_buffer_synth_20261021T003504334 PASS: 4267 LUT1..4,
1520 ALU, 511 MUX2_LUT5, 34 distributed RAM cells, 2977 FF, 2 SPX9, 0 DSP.
No P&R/Fmax/board claim. Remaining: coherent CSR snapshot/readback, bandwidth
reporting, explicit overflow/protocol policy tests, narrow board wrapper and
25K physical acceptance. Current 20K calibration does not qualify 25K.

### IP-02 coherent telemetry CSR (2026-10-21)
Changed rtl/csr_metrics_snapshot.v, rtl/frame_buffer_reference.v,
tb/tb_csr_metrics_snapshot.v, tb/tb_frame_buffer_reference.v,
tools/test_frame_buffer.py and csr_map.md/docs. Canonical sys_register_snapshot
reused unchanged. test_frame_buffer.py PASS both modes and CSR readback; evidence
frame_buffer_20261020T163653168562Z. Independent iverilog/vvp snapshot tests
WORDS=1/51/60 PASS all words across two generations, live changes, malformed
accesses, response stalls and reset; csr_snapshot_20261021T003720599.
No synth/P&R/board in this step; previous resource counts exclude CSR storage.
Remaining: host bandwidth/telemetry decoder, narrow physical wrapper and target
P&R, runtime JTAG physical binding, 25K sustained controlled acceptance. Overall
work order IP-00..10 remains ACTIVE and far from complete.

### IP-02 host telemetry evidence (2026-10-21)
Changed tools/decode_metrics.py, tools/TELEMETRY.md, tools/test_frame_buffer.py,
tb/tb_frame_buffer_reference.v and validation docs. test_frame_buffer.py PASS
both modes: full 51-word CSR dump, snapshot ID bracketing, decoded accounting and
CRC match. Evidence frame_buffer_20261020T164020805862Z. decode_metrics.py
--self-test and CLI decoding PASS. Validates counter/ID wrap, epoch/coherence,
positive bounded intervals, elapsed-clock agreement and plausible byte deltas.
No RTL/synth/board change this step. Current data are explicitly SIMULATION,
not board bandwidth; physical runtime JTAG transport and 25K gates remain open.
Next: narrow synthesizable stimulus/checker + physical wrapper, P&R and actual
25K controlled sustained capture/readback; current connected board remains20K.

### IP-02 synthesizable stimulus and checker (2026-10-21)
Added rtl/buffer_dma_selftest.v, tb/tb_buffer_dma_selftest.v,
tools/test_selftest.py, SELFTEST.md; updated integration/changelog/validation.
Four independently checked RTL runs PASS,2176 words total, exactly one injected
corruption detected; seed replay identical after restart. Watchdog forced-stall
case PASS at64 cycles. Evidence selftest_20261020T164308156793Z. Word DMA and
whole-buffer/CSR regressions PASS: word_dma_20261020T164516829312Z,
frame_buffer_20261020T164518621539Z. Selftest GW5A synthesis launched in
selftest_synth_20261021T004327729 (consult actual directory/log for authoritative
result; not yet qualified here). Narrow board/control wrapper, P&R and physical
25K runtime-readback/continuous tests remain OPEN. Current connected20K has not
been programmed by this step. Overall work order remains ACTIVE.


Selftest synthesis completion: selftest_synth_20261021T004327729 PASS.8416 LUT1..4,2063 ALU,728 MUX2_LUT5,5025 FF,34 distributed RAM cells,2 SPX9,0 DSP. Includes CSR/monitors and tester; no P&R/Fmax or board qualification. Prior pending-synthesis note is superseded by this completion record.

### IP-02 narrow board wrapper/control (2026-10-21)
Added buffer_dma_control.v,examples/25k/buffer_dma_top.v and calibrated25K CST,
control/UART TBs,test_control.py,build_board.py,run_uart.py,test_uart_codec.py,
BOARD_CONTROL.md; updated dependency/integration docs. test_control.py PASS
both direct CSR and full bit-serial POR/UART/selftest/snapshot chain; evidence
control_20261020T164916960321Z. Host UART known-CRC/partial-read/error fixtures
and py_compile PASS; run_uart.py has NOT run on physical hardware.
25K build board_20261020T164928239302Z remains live in exec session97386;
yosys PID10608 verified running during AUTONAME. Poll that SAME session; do not
restart solely because observation yields no output. No board programmed.
Actual connectedboard20K remains on its earlier calibration image. Mandatory
25K physical runtime JTAG and sustained LA/data acceptance remain OPEN.

### Route repair and IP-03 streaming foundation (2026-10-21)
Previous board build board_20261020T164928239302Z terminal FAIL at placement:
RAM16SDP4 descriptor queues lack placeable GW5A BELs. Changed only slot manager
ring RAM_STYLE to block; test_slots.py and test_control.py PASS, evidence
slots_20261020T165633859740Z and control_20261020T165639846902Z. New build
board_20261020T165642947154Z is live in exec session18749 (yosys PID24216),
verified running AUTONAME. Poll same session; do not restart while alive.

Inspected actual IP-03 reuse sources; existing full-frame BLC has256 dimension
limit and serialized replay. Added cores/image_processing/isp_stream/REUSE_AUDIT.md,
reuse_sources.json,rtl/raw_black_level_stream.v, two TBs,tools/test_blc.py and
RAW_CONTRACT.md. New manual four-plane streaming path has no frame RAM and
atomically commits config on acceptedSOF. Canonical old BLC/AWB/CCM/Gamma remain
unchanged. test_blc.py PASS RAW8/10/12,each384078pixels,full320x240/640x480,
all patterns,clip counts,metadata,stalls,bypass and pending config. Isolated
128pixel continuous test II1 and stalled-reset PASS. Evidence
artifacts/isp_stream_25k/blc_20261020T165939975888Z. No BLC synth/P&R/board yet;
complete ISP chain and continuous25K acceptance remain OPEN. Overall goal ACTIVE.

### Timing repair + composed RAW frontend (2026-10-21)
Second IP-02 board build board_20261020T165642947154Z terminalFAIL50MHz timing,
31.65MHz routed Fmax. DistributedRAM placement problem is resolved by block
queues; critical path now selftest pattern/checker. Changed buffer_dma_selftest.v
incremental frame/word terms and registered expected/actual comparison; unchanged
functional pattern verified by test_selftest.py PASS (2176words,oneinjectederror,
restart/replay/watchdog),selftest_20261020T170735387519Z. test_control.py PASS,
control_20261020T170744890799Z. Third build board_20261020T170749474314Z live in
execsession94223; poll same handle. No bitstream downloaded;50MHz target retained.

IP-03 added rtl/raw_rgb_frontend.v,tb/tb_raw_rgb_frontend.v,tools/test_frontend.py,
FRONTEND.md. Composes BLC with unchanged canonical window/Bayer kernels; gates
input at configured frame size,atomic command,sampledframeID,onepixel bordercrop,
response/error recovery. test_frontend.py PASS RAW8/10/12 each380685pixels with
independent matrix/bilinear golden,full320x240/640x480,allpatternswapped pins,
stalls,allmarkers,extra input rejection,invaliddimensionand3x3recovery. Evidence
frontend_20261020T170452403607Z. IsolatedRAW10BLC synthesis PASS
blc_synth_20261021T010610071:120LUT1..4,99ALU,202FF,20MUX2_LUT5,0DSP/BSRAM.
No frontend P&R/Fmax/board or AWB/CCM/Gamma/Sobel full-chain claim. Goal ACTIVE.

### IP-03 AWB/CCM/Gamma RGB subchain (2026-10-21)
Added rtl/rgb_color_chain.v,tb/tb_rgb_color_chain.v,tools/test_color_chain.py,
COLOR_CHAIN.md. Canonical elastic AWB/CCM/synchronousGamma reused unchanged;
frame command sequencer loads12matrix terms and commits allstages before input,
metadata FIFO aligns frameID/EOF with coreSOF/EOL under backpressure. ExactPython
integer golden PASS384173pixels,sixframes including320x240/640x480,negative
coefficients,bias,nonunitygain,saturation,LUTreload/off/on. IncompleteGamma table
rejected; command pins afteracceptance do not changeframe.128continuouspixels
prove isolatedcolorII1. Evidence color_20261020T171340367961Z. No synth/P&R/board
for colorchain; full RAW-to-color composition and Sobel/statistics still OPEN.

Third IP-02 board build board_20261020T170749474314Z still live in session94223;
synthesis passed and actual route progressing (not blocked). Preserve/poll same
handle. No25K image downloaded; current20K remains unchanged.

### IP-02 timing pipeline, fourth build (2026-10-21)
Third build board_20261020T170749474314Z terminalFAIL50MHz;43.23MHz routed Fmax.
Criticalpath now frame_slot_manager timestamp subtraction plus latency_sum.
Changed frame_slot_manager.v to register delta and update min/max/sum nextclock;
measurement endpoints/values unchanged,telemetry visible oneclocklater (documented).
test_frame_buffer.py PASS exact timestamps/allwords/CRC/CSR,bothmodes,evidence
frame_buffer_20261020T171542841254Z. test_control.py PASS direct/serial,
control_20261020T171544969679Z. Fourth board build board_20261020T171548136931Z
live in execsession90691; poll samehandle. Allpriorfailureevidence preserved.
No physical25K acceptance and current20K not reprogrammed. Goal ACTIVE.

### IP-03 complete RAW-to-color functional composition (2026-10-21)
Added rtl/isp_stream_core.v,tb/tb_isp_stream_core.v,tools/test_isp.py,
tb/tb_isp_error_recovery.v,tools/test_isp_recovery.py,ISP_CORE.md,VALIDATION.md,
LICENSE_DEPENDENCIES.md. Added passive drained output to colorchain and updated
its TB port. Unified framecommand atomically binds RAW/BLC/color settings;
normalresponse waits for finalRGBEOF. Fatalerror blocks newadmission,drains
acceptedcolorpixels and resets children only after errorresponse consumed.
test_isp.py PASS RAW8/10/12 each380685finalpixels/fullmetadata exactgolden,
isp_20261020T171830899126Z. test_isp_recovery.py PASS malformedEOL,stalled fatal
drain and cleanframe recovery,18checkedpixels,recovery_20261020T172223864482Z.
No new physical qualification. Isolated fullcore synth running in session88077,
core_synth_20261021T012235399; poll same handle. Sobel/statistics/realtime source,
CSR/LA,actual PPA and25K sustained acceptance remain OPEN.

IP-02 fourthbuild board_20261020T171548136931Z still live in session90691;
synthesis complete,actualroute progressing. Pre-route estimate not acceptance;
await terminalreport before claiming50MHz. Goal remains ACTIVE.

FullISP synthesis completion:core_synth_20261021T012235399 PASS.5246LUT1..4,1057ALU,188MUX2_LUT5,2391FF,6SDPX9B+2SPX9 synthesis cells,0DSP. No physical PPA/Fmax or25K qualification. Session88077 terminalsuccess. IP-02 route remains in session90691; poll that samehandle.

### IP-02 route/pack success (2026-10-21)
Session90691 terminalSUCCESS. Fourthbuild board_20261020T171548136931Z PASS
synth/P&R/pack;finalFmax56.6797MHz meets50MHz. Final pnRJSON9306LUT4,2462ALU,
5798DFF,10BSRAM,11IOB,0DSP/PLL. Pre-route9092LUT4 is not finalresourcecount.
Current source/CST/build-script hashes and packedimage SHA256 revalidatedPASS.
Imagehash8d756518bb3aef061aacdf25d4f3c21ae3a2a4563d109996ec822e38a3b2926b.
Added bound ppa.json and PPA_BOARD_25K.csv;failureevidence retained. No board
programming. Async user query asks whether25Kcanbereconnected;last hardware20K.
Physical controlled UART/LA,sustainedflow and hardruntimeJTAG gates remainOPEN.
Software/ISP development continues;goalACTIVE,not blocked or complete.

### 20K recalibration and IP-03 statistics integration (2026-10-21)
Previous goal turn made progress: new physical20K calibration evidence
`tang20k_la_calibration_20261020T173637486672Z` PASS forward/reverse and live
LA+CMSIS-DAP IDCODE coexistence. CH0..7=T6,P6,T7,R8,T8,P8,P9,T9;
2MS/s,2million coexistence samples,ID0x081B. SRAM calibration image only;
no NOR modification and no25K qualification.
Added rgb_frame_statistics.v and isp_stream_with_statistics.v with standalone,
fullchain and malformed-frame recovery testbenches/runners. Fixed testbench
rng declaration order (initial compile failure retained). Standalone evidence
statistics_20261020T173108154399Z PASS widths48/8,384016pixels each,exact sums,
counts/tags and saturation. stats_recovery_20261020T174054518375Z PASS18pixels,
malformed snapshot suppressed,clean snapshot checked,held30cycles afterresponse,
commandblocked until snapshot consumption. STATISTICS.md and reuse/license
records updated. Full RAW8/10/12 golden run is currently in session79283:
isp_statistics_20261020T173832627433Z; RAW8 and10 each380685pixels/7snapshots
PASS,RAW12 still live. Poll same handle before claiming terminalPASS.
Commands: test_statistics.py (earlier evidence),test_isp_statistics.py,
test_isp_stats_recovery.py after env.ps1. No statistics synthesis/PPA yet.
Sobel,perstagebypass,CSR/probes,realtime30fps and physical25K gates remainOPEN.
Goal ACTIVE;20K mapping does not replace required25K acceptance.

Session79283 terminalSUCCESS: isp_statistics_20261020T173832627433Z PASS
RAW8/10/12 each380685pixels and7exact snapshots. Terminalsummary independently
checked. STATISTICS.md/VALIDATION.md updated. No PPA/physical claim;goalACTIVE.

### IP-03 grayscale Sobel streaming stage (2026-10-21)
Previous turn made progress: full RAW8/10/12 statistics golden terminalPASS.
Added rtl/gray_sobel_stream.v,tb/tb_gray_sobel_stream.v,tools/test_sobel.py,
SOBEL.md;updated VALIDATION.md and canonical reuse hashes. Reuses unchanged
synchronous dual-row window and three-stage elastic Sobel. Fixed onepixelborder
crop in both Sobel and centerbypass modes;framecommand latches dimensions,
frameID andmode;EOF metadataFIFO;response waits final outputacceptance.
test_sobel.py PASS380669pixels,independentPython convolution andallmetadata,
7x6/320x240/640x480/3x3,randomstalls,heldoutput,responsehold,configpinchanges,
invaliddimensionrecovery. Evidence sobel_20261020T174452907145Z bound to current
sourcehashes. Initial failures preserved: asynchronous TB wait observed delta
transient when previous error1 changed to success; corrected TB to synchronous
response sampling,without goldenchanges. No synthesis/resource/Fmax claim.
Full RAW/RGB-to-Sobel composition,perstagebypass,CSR/probes,realtime30fps,
physical25K and remaining IP00..10 gates remainOPEN. GoalACTIVE.

### IP-03 complete RAW-to-Sobel pipeline (2026-10-21)
Previous turn made progress: standalone Sobel goldenPASS. Added
rtl/isp_sobel_pipeline.v,tb/tb_isp_sobel_pipeline.v,tb/tb_isp_sobel_recovery.v,
tools/test_isp_sobel.py,tools/test_isp_sobel_recovery.py,SOBEL_PIPELINE.md.
Added passive drained output to gray_sobel_stream and updated its TB.
RAW/BLC/Bayer/AWB/CCM/Gamma/RGBstats -> (R+2G+B)>>2 -> Sobel/centerbypass;
atomic command,rawdimensions>=5,finalsize W-4/H-4. Success waits lastSobelEOF;
fatal waits acceptedwindow/kernel tokens drain then resets partialframe.
isp_sobel_20261020T174734732567Z terminalPASS RAW8/10/12 each377317pixels,
7RGBsnapshots exactPythonGolden,320/640frames,allmetadata/configchanges/stalls.
New directed gate test exposed LUT-ready incorrectlyhigh during localreject;
FAILsobel_recovery_20261020T175142124662Z preserved. Fixed valid/ready gating.
Current recovery sobel_recovery_20261020T175202234373Z PASS:dimrejectLUTgate,
Gammaerror8/nooutput,malformedEOL/error2,heldoutputfatal+successdrain,9clean
outputs,RGBstats625each/25pixels/5lines,heldsnapshot30cycles/commandblocked.
Current standalone sobel_20261020T175204225742Z PASS380669pixels.
Current-source fullrerun session94931 live:
isp_sobel_20261020T175240510760Z;poll samehandle,do not assume terminalPASS.
Current-source GW5A-noiopads synth session63727 terminalSUCCESS:
sobel_synth_20261021T015223545;summary.json records exact netlistcells.
No physicalBSRAM/Fmax/IOtop or25K acceptance claim. Earlier synth artifacts
preserved. Docs VALIDATION.md/SOBEL_PIPELINE.md updated. All-stagebypass,
CSR/probes,realtime30fps,P&R,25K physical and remainingIP00..10 remainOPEN.
GoalACTIVE,not blocked or complete.

Session94931 terminalSUCCESS:current isp_sobel_20261020T175240510760Z PASS
RAW8/10/12 each377317pixels/7snapshots,current sourcehashbinding revalidated.

### IP-03 paced virtual RAW source (2026-10-21)
Previous turn made progress: RAW-to-Sobel RTL,integration/recovery evidence and
GW5A synthesis. Polled session94931 to terminalSUCCESS,current fullsource
isp_sobel_20261020T175240510760Z PASS RAW8/10/12 each377317pixels/7snapshots;
sourcehashes revalidated. Updated pending notes in docs.
Added rtl/virtual_raw_source.v,tb/tb_virtual_raw_source.v,
tools/test_virtual_raw_source.py,VIRTUAL_SOURCE.md. Finite seeded raster:
seed+23x+37y+57frame,incremental add,no framebuffer/multiplier;command/payload/
response sequencing;exact programmable cadence when downstream meets period;
completed/deadline/commandstall/pixelstall/cycle counters,config latch/restart.
Source-only virtual_source_20261020T175554791992Z terminalPASS RAW8/10/12,
allpixels/markers,7x5period200,5x3randomstalls/7forcedmisses,three320x240 and
 two640x480period1666667frames with zero misses/exactcommand cadence. Current
sourcehashbinding revalidated. This is NOT full ISP throughput/physical evidence.
Added tb/tb_isp_realtime.v and tools/test_realtime.py:actualsource->actualRAW10
ISP/Sobel,50MHzsimclock,period1666667,3frames320x240 then2frames640x480,
frameID alternates Sobel/centerbypass,independentPythonpixel/statistics golden.
Live session13698,realtime_20261020T175818964103Z;compilePASS,vvp confirmed
live. Poll samehandle before claiming throughputPASS;do not restart on silence.
No source synthesis/P&R or25K physical claim. All-stagebypass,CSR/probes,
P&R/25Kphysical andremaining IP00..10 stillOPEN. GoalACTIVE.

### IP-03 actual finite30fps simulation and atomic ISP CSR (2026-10-21)
Previous goal turn made progress:virtualRAWsource passed8/10/12 and actualchain
throughput process started. Polled same13698handle to terminalSUCCESS:
realtime_20261020T175818964103Z PASS actualRAW10 source->fullISP/Sobel,
50MHzsim,3frames320x240+2frames640x480,exact1666667commandcadence,zero misses/
commandstalls,829200finalpixels and5RGBsnapshots exactPythonGolden. Genuine
pixelstalls230394/614396,runclocks3486953/2281086. Current sourcehashes
revalidated. This is finite SIMULATION,not P&R/physical25K acceptance.
Added rtl/isp_config_registers.v,tb/tb_isp_config_registers.v,tools/test_config.py,
CONFIG_REGISTERS.md. Reuses unchanged sys_atomic_config WORDS16 (recordedhash).
CSR shadow/activebank,semantic validation,commitdeferuntilsafe,whole512bit
cfgcommand,waiting blockswrite/commit throughhandshake;heldresponse serialization.
config_20261020T180222223057Z terminalPASS all16words,deferred/immediateapply,
20cycleconfigstall,CSRstall7cycles,exactlyonce,crossbankreads,invalidflags/
alignment/strobes/addresses/read-onlywrites.Current sourcehashes revalidated.
Updated VIRTUAL_SOURCE.md/VALIDATION.md/LICENSE_DEPENDENCIES.md/reuse_sources.
Next:integrate config/source/ISP,LUTwrites,coherentmetrics/probepages;allstage
bypass,P&R50MHz and25Kphysical stillOPEN. No newsource/CSR PPAclaim. Remaining
IP00..10 scope staysintact.GoalACTIVE,not blocked or complete.

### IP-03 runtime-controlled ISP and UART board top (2026-10-21)
Previous turn made progress:atomicCSR and real-source30fps finite simulation.
Added rtl/isp_control.v,tb/tb_isp_control.v,tools/test_control.py,CONTROL.md.
Reuses canonical sys_atomic_config,sys_register_snapshot,logic_probe8,
frame_stream_monitor. Config drives actual source/ISP;GammaLUT CSR writes;
32wordcoherent metrics/CRC,lastRGBstats,2metricpages/4registeredprobepages.
First integration control_20261020T180809335809Z FAIL:prepayloadGammaerror
was valid while source still PIXELS,rsp_ready only after allRAW ->deadlock.
Fixed virtual_raw_source to accept explicit errorresponses in PIXELS and abort
that offeredframe. Ordinary stalls still hold;expliciterrorabort documented.
control_20261020T180930042929Z PASS CSRconfig/runs,27exactpixels/markers,
PythonCRC febcb7c1/b6c9cb0b,RGBstats,heldCSR/output,live-traffic frozen snapshot,
all4pages,Gammaerrorthen768LUTwritesandcleanrestart. Currenthashesrevalidated.
Added examples/25k/isp_top.v,isp.cst,tools/build_board.py,tb/tb_isp_uart.v,
tools/test_uart.py.11pin50MHzUARTsupplementarytop;noharduserJTAGclaim.
uart_20261020T181126001154Z PASS realbitserial config/run/CRC/snapshot/pages.
Updatedsource regression virtual_source_20261020T180856909397Z PASS8/10/12.
Updatedfullrealtime realtime_20261020T180857788673Z terminalPASS829200pixels,
5RGBsnapshots,50MHz/30fpsfinite simulation,exactcadence;session65573SUCCESS.
Hashbinding validated for allabove. Session84483 source regressionSUCCESS.
Boardbuild session73270 remainsLIVE:
board_20261020T181007022100Z;yosysprocess27676 confirmedlive at AUTONAME,
no terminal synthesis/P&R/pack report yet. Poll samehandle,do not restart on
quietlog. No physical resource/Fmax/download claim. Currentphysicalboard20K.
CONTROL/VALIDATION/VIRTUAL_SOURCE/LICENSE/reusehashes updated. Allstagebypass,
P&R/25Kphysical,hardruntimeJTAGandremainingIP00..10 gatesOPEN.GoalACTIVE.

### IP-03 host-side runtime acceptance tooling (2026-10-21)
Previous turn made progress:runtimeCSR/UART top tests passed;board build launched.
Polled same73270handle: synthesis terminalPASS,actualP&R nowlive (process40676),
board_20261020T181007022100Z. No Fmax/route/pack result yet. Preserve/poll.
Added tools/isp_host.py,tools/run_uart.py,tools/test_host.py,
fixtures/host_control.json,HOST.md. Reuses unchanged buffer_dma UartCsr codec;
stages16words/identityLUT;idle and appliedversion guards;coherent32word snapshots,
build image/sourcehash checks;independent RAW/Bayer/luma/Sobel integer golden,
cumulative/lastCRC and RGB/frame/count/mode acceptance. Preset constrained to
zeroBLC/unitygains/identityCCM/off-or-identityGamma. CLI defaultRAW10/50MHz.
host_20261020T181920534896Z terminalPASS:fragmentedserialcodec,badCRC/status,
config/selector/singlecommit,768LUTwrites,two simulation-derivedpayloadfixtures,
coherence/provenance/reservedbits/corruption rejection.CurrenthashbindingPASS.
Fixture timing fields explicitlysyntheticzero;physical_measurement=false.
run_uart.py --help PASS.No physicalUART invocation. Hostreportsloaded-imagehash
andhardJTAGverificationfalse;suppliedbuild hash is NOT hardwareimage readback.
UpdatedVALIDATION.md/HOST.md. P&R/50MHz/25Kphysical,allstagebypass,hardware
fingerprint/hardruntimeJTAG,andremainingIP00..10 gatesstayOPEN.GoalACTIVE.

### IP-03 local remaining bypass components (2026-10-21)
Previous goal turn made progress:host acceptance tools/fixtures PASS;boardP&Rlive.
Polled same73270handle;nextpnr40676 confirmedlive,placementiteration16. Packed
pre-route utilisation16010LUT4/7260DFF/16BSRAM is NOT finalresource/Fmax result.
No failure/terminalreport yet;keep samejob,do not restart due slow placement.
Added rtl/raw_bayer_mode_stream.v,tb/tb_raw_bayer_mode_stream.v,
tools/test_bayer_modes.py,tb/tb_bayer_mode_latency.v,tools/test_bayer_latency.py.
Reuses unchanged synchronouswindow+Bayerkernel,center-broadcast bypass with
samecrop/sameregister timing. bayer_modes_20261020T182321831886Z terminalPASS
RAW8/10/12 each380739pixels,allpatterns,320bypass/640normal,heldoutput/config,
invalidsize/malformedEOL/recovery. bayer_latency_20261020T182450903497Z PASS
80pixels,two actualinstances,cycle-equivalent ready/valid/markers/responses.
Added rtl/isp_mode_config.v,tb/tb_isp_mode_color.v,tools/test_mode_color.py.
AWB/CCMidentity selection preserving canonicalstages;mode_color_20261020T182613732556Z
PASS64pixels all4modes,nonunityoriginalgains,negativecoeff/bias/round/clip,
metadata/stalls/configpinsafteraccept. Currenthashbindingverified for all3.
BYPASS_COMPONENTS.md/VALIDATION.md updated. These are NOT integrated into
CSR/fullchain/boardbuild. Existing config still rejects flags3/6/7. Baseline
boardbuildsources unchanged; integration/hostflags/mixedmodes/P&R remainOPEN.
Boardbuild73270:board_20261020T181007022100Z stillLIVE atplacement;poll same.
No newresource/Fmax/25Kphysicalclaim.GoalACTIVE;allIP00..10scope intact.

### IP-03 integrated bypass modes and Gamma reuse (2026-10-21)
Integrated Bayer center bypass and AWB/CCM identities through the full chain,
atomic CSR low8flags,metric22 and host CLI/golden. Reserved-bit rejection moved
intentionally from newly supported bit3 to reserved bit8. Canonical cores unchanged.
Fixed consecutive Gamma-enabled frames by reusing active LUT without redundant
commit; newly written partial tables reject explicitly.
PASS evidence: config_20261020T183056126132Z,
mode_color_20261020T183123228744Z,control_20261020T183124013475Z,
gamma_reuse_20261020T183212405107Z,sobel_recovery_20261020T183213195202Z,
uart_20261020T183214106830Z,all_modes_20261020T183333608166Z (64modes/576pixels),
host_20261020T183553965028Z (10fixtures),
isp_sobel_20261020T183426653724Z (RAW8/10/12 each377317pixels/7snapshots),
realtime_20261020T183426663011Z (829200pixels/5snapshots/50MHz30fps simulation).
Commands: test_config.py,test_mode_color.py,test_control.py,test_gamma_reuse.py,
test_sobel_recovery.py,test_uart.py,test_all_modes.py,test_host.py,
test_isp_sobel.py,test_realtime.py under cores/image_processing/isp_stream/tools.
Changed RTL: raw_rgb_frontend,isp_stream_core,isp_stream_with_statistics,
isp_sobel_pipeline,isp_control,isp_config_registers,rgb_color_chain; associated
TB/source-list runners and host tools/fixtures/docs. New all_modes/gamma_reuse tests.
Old baseline board_20261020T181007022100Z inputs archived with manifest;
nextpnr40676 confirmed live. Extended board_20261020T183704608918Z yosys21248
confirmed live; build_board.py now freezes all inputs and builds from snapshot.
No terminal P&R/resource/Fmax or physical claim. Neither image downloaded.
Current board is20K; required25K physical and hard runtime user-JTAG remain open.
IP00..10 scope preserved; goal active. Previous calibration-only turn made no
new goal implementation progress; this turn completed long-test evidence and docs.

Evidence audit: all10 summaries above terminalPASS; every recorded source hash
matches current files. Both frozen build manifests verified (30/32 inputs),
zero mismatches. Old route log advanced to168000iterations; not terminal.

### IP-03 quantitative error report and baseline route completion (2026-10-21)
Previous turn progressed documentation and completed long regression evidence.
Added tools/report_numeric_error.py and NUMERIC_ERROR.md. Verifier checks source
and retained-payload hashes, reconstructs golden pixels and emits max/mean errors
and metadata mismatch counts. Both commands (--kind all_modes/realtime) PASS:
numeric_all_modes_20261020T184242465012Z:576pixels,max/mean0,metadata0;
numeric_realtime_20261020T184242465012Z:829200pixels,max/mean0,metadata0.
Comparator corruption/length rejection checks PASS. Oracles reused explicitly;
no independent second-oracle or physical claim.
Reran test_color_chain.py on current Gamma wrapper:color_20261020T184159222421Z
PASS384173RGBpixels/6frames/isolatedII1;current-source hashes verified.
Old baseline session73270 terminal exit0,route/packPASS:
board_20261020T181007022100Z final63.959064MHz vs50MHz constraint;
17114LUT4,2590ALU,7260DFF,16BSRAM,11IOB,0DSP/PLL.
Bitstream SHA256 be2fe0342e51f9f02cfb2f01edb56da88ecb0d53e1d993268f4adf5a0434b2ab;
verified image hash and source hashes against archived inputs (not current RTL).
This old feature baseline lacks current bypass/Gamma extension;not downloaded.
Extended session46715 synthesisPASS,route live (nextpnr48772). No terminal
extended resource/Fmax yet.25K physical/hard-user-JTAG and all remaining IP gates
remain open; goal active. No existing baseline/failure artifacts removed.

### IP-03 configurable host acceptance and failed placement retry (2026-10-21)
Previous turn progressed numeric reports and baseline route evidence.
Changed tools/isp_host.py and run_uart.py: configurable blacklevels/target,
Q8.8gains,signed16CCM/bias with range checks,packing and complete integer golden;
allbypass behavior applied numerically. Added test_host_parameters.py.
test_host.py PASS host_20261020T184437729451Z (10originalfixtures);
test_host_parameters.py PASS host_parameters_20261020T184506340923Z:
64retained actualRTL payloads/observedCSR CRC+RGB,576pixels,packing/staging,
wrongconfig and invalidranges rejection. --help PASS. No physicalUART invocation.
Extended build session46715 terminalFAIL:board_20261020T183704608918Z
heap unabletofindlegalplacement (packed16318LUT4,7261DFF,16BSRAM;not finalPPA).
Preserved failure. Added route_frozen.py to verify/copy frozen inputs/netlist
and retry without resynthesis/RTLchanges. SA attempt board_sa_20261020T184547368791Z
terminalFAIL:process terminated after initialplacement without diagnostic.
Preserved logs. Heap seed2 with --placer-heap-no-ctrl-set now running
session92908,board_retry_20261020T184606844008Z. This changes placement policy,
not netlist/function. No extendedfrequency/resource/downloadclaim.
HOST.md updated. Physical25K/harduserJTAG and remainingIP00..10 gatesOPEN.

### IP-04 scan host transaction driver; IP-03 second heap failure (2026-10-21)
Previous turn progressed configurable ISP host acceptance and routing retries.
Added ip_test_shell_25k/tools/scan_bus.py,test_scan_bus.py;SCAN_PROTOCOL.md updated.
Physicalbackend remains absent. Driver supplies transport-neutral access() for
future harduserinstruction Capture/Shift72/Update callback;fresh tag from current
mailbox response,stale capture filtering,bounded polling,error decoding,
uncertain-completion poison/no automaticwrite retry.
Command python cores/system/ip_test_shell/tools/test_scan_bus.py terminalPASS
scan_bus_20261020T184825730157Z:261 transactions/tagwrap/packing/delayedreplies,
CSRerror,badCRC,rejection,timeout,invalidfields/bounds. Physicalverified=false.
No RTL or resource change in this turn.
IP-03 frozen-netlist retry92908 terminalFAIL:
board_retry_20261020T184606844008Z heap seed2/noctrlset still unabletofindlegal
placement. Original+SA+retry failures preserved. No running build remains.
Next action analyze netlist/placement constraint or synthesis mapping,not
restart a live process. Currentfeature physical/PPA gates remainOPEN.
Mandatory25K harduserJTAG backend+hardware stillOPEN;fullIP00..10 goalACTIVE.

### IP-03 placement mapping experiment and full-chain mode latency (2026-10-21)
Previous turn progressed abstract scan host driver and recorded terminal placement failure.
Compared archived JSONs: passing baseline has0MUX2_LUT6,extendedfailure has1,
in gamma_enable control. This is a placement-constraint hypothesis,not proven rootcause.
Added build_board.py --nowidelut (supportedYosys option) to retain allISPfeatures
while using only LUT4 mapping. New frozen build board_20261020T184939354706Z
session71786 yosys1892 verifiedlive; synthesis pending,not restarted.
Added tb/tb_isp_mode_latency.v,tools/test_mode_latency.py. Wrapper reuses actual
64mode CSR scenario and forces sinkready1 solely for comparable latency.
Command test_mode_latency.py terminalPASS mode_latency_20261020T185105095734Z:
all64 modes/576 exactpixels+metadata; firstinput->firstoutput82clocks,
lastinput->lastoutput19clocks,inputspan95/outputspan32 for everymode.
Scope fixed7x7,no sinkstalls; not command-admission latency,fullchainII1 or
physicalfrequency. Data/metadata remain checked with independent Python golden.
No functionalRTL modified. All earlier failure artifacts preserved.
25Kphysical/harduserJTAG/currentfeaturePPA and remainingIP00..10 gatesOPEN.

### IP-05 complete-network golden/converter start; IP-03 verified synthesis wait (2026-10-21)
Previous turn progressed64mode latency evidence and LUT4mapping build.
Polled same71786handle;yosys1892 confirmedlive,still final synthesis AUTONAME.
No restart/no terminal resource/frequency claim.
Created cores/acceleration/cnn_infer_25k/SPEC.md,tools/model.py,export_model.py,test_model.py.
Complete defined model:signed28x28x1->3x3conv4/ReLU/quant7/pool2->14x14x4
->3x3conv8/ReLU/quant7/pool2->7x7x8->dense10/Top3. HWC/OIHW layouts,
signedbias/unshiftedproduct/rangebounds/tietiebreak explicit;4244weightbytes.
Deterministic functionalfixture,not trainedclassifier/no accuracyclaim.
Reuseaudit:ips_int8_mac_array perproductshift2+perupdatesaturation is numerically
incompatible;cannot silentlysubstitute. Existingcanonical modules untouched.
Commands export_model.py --output artifacts/cnn_infer_25k/model_20261020_initial
and test_model.py PASS. Export hasmodel+memories+three inputcases+alllayer
acc/quant/pool/scores/Top3+hashmanifest. Signedmemoryroundtrip andallhashesPASS.
model_test_20261020T185352312587Z PASS independent flattenedpatch convolution,
inputscanpooling andseparateFC accumulation vs primarygolden,threefullinputs,
zero-modelTop3ties,invalidweight/shape/accumulatorboundrejection.
Softwareonly:rtl_verified=false,physical_measurement=false. No resourceimpact.
RTL synchronousmemory/weightscheduling/MAC/pool/dense/readback/PPA/25Kboard
remainOPEN. IP03 not declaredcomplete;harduserJTAG andallIP00..10 scope intact.

### IP-05 signed dot RTL and synthesis (2026-10-21)
Previous turn developed complete CNN model/converter and softwaregoldens.
Added rtl/int8_dot_stream.v,tb/tb_int8_dot_stream.v,tools/test_dot.py,DOT.md;
SPEC updated. Signed8rawproducts+signed32bias/acc,II1 input,exacttermcount,
lastmarker checks,heldresponse,explicitlength/framing/overflowerrors,resetabort.
LegacyunsignedPE and perproductshifted ips MAC remain untouched;newnarrow
boundary implements selected model arithmetic rather than changing oldcontracts.
Command test_dot.py PASS dot_20261020T185543965235Z:47responses,
392continuousbeats/II1,randomsigned,gaps,biaslatch,heldresponse,invalidlength,
early/missinglast,positive/negativeoverflow,reset/recovery.
Isolated Yosys synth_gowin -family gw5a -top int8_dot_stream PASS
 dot_synth_20261020T185605388105Z:292LUT1..4,95ALU,119FF,8MUX2_LUT5,
zeroDSP/BSRAM. NoP&R/Fmax/fullCNNclaim. Synchronousmemory/layers/pool/dense,
wholemodelRTL/perlayercomparison/25Kphysical remainOPEN.
IP03 same71786session:synthesisterminalPASS,routing46588verifiedlive.
board_20261020T184939354706Z packed16400LUT4/16BSRAM,zeroMUX5/6/7/8;
notfinalPPA. Wide-LUT hypothesis not yet proven. No restart/download.
AllIP00..10/harduserJTAG/physicalgates remainOPEN;goalACTIVE.

### IP-05 complete CNN RTL/per-layer simulation and isolated synthesis (2026-10-21)
Previous turn implemented/validated scalar dot. Added rtl/cnn_serial_engine.v,
tb/tb_cnn_serial_engine.v,tools/test_engine.py,synth_engine.py,ENGINE.md;
SPECupdated. Complete2conv/ReLU/quant/pool+dense10+Top3 with one reused dot,
registeredtensor/weight/biasreads,784Binput/pools+3136Bquant+4244Bweights,
sequentialloader/completeness,heldperlayertaps/completion/earlyoverflowabort.
Initialfulltest engine_20261020T185947349537Z FAIL pool1:10bit uncontextualized
fmapwrite address wrappedat1024. Failure/debug artifacts preserved; explicit16bit
writeaddresses fixedit withoutchanginggolden. engine_20261020T190116719398Z PASS.
Then replacedvariable-divisor addressmath withconstantbranches;
CURRENT test_engine.py PASS engine_20261020T190201402467Z:
3fullinputs,31791 exactacc/quant/pool/scores/Top3values,oneweightsload/reuse,
randomtapstalls,helddone,loaderinvalid/incomplete/staleinput,earlyoverflow.
Cycles317779/317880/317970 include tapstalls,exclude hostload;CE1simulation,
notboardFmax/throughput. Sourcehashes+retainedtap hashverifiedcurrent.
synth_engine.py terminalPASS engine_synth_20261020T190239082611Z:
1419LUT1..4,785FF,783ALU,77MUX2_LUT5,16RAM16SDP4,2DPB+4DPX9B,
zeroDSP. BSRAMmacrocount not yet finalphysicalusage;noP&R.
RAMmapping out-of-range warnings requireinspection beforephysicalimplementation
claim;logsretained. RuntimeboardCSR/JTAG/readback,PPA/frequency/physicalOPEN.
IP03 same71786/nextpnr46588 confirmedlive actualrouting(~71000iterations).
Do not restart;no currentfeatureterminalPPAyet. FullIP00..10goalACTIVE.

### IP-05 actual CSR loading/full-layer readback and board build (2026-10-21)
Previous turn progressed complete CNN RTL and isolatedsynthesis.
Added tools/audit_ram_mapping.py,RAM_MAPPING.md. NarrowDPB warnings audited:
4bitactiveports,unusedhighoutputs,readBwriteenableGND;ram_audit_20261020_initial
PASS. Negativemutations liveunknownwrite/highoutputconsumer rejected. This is
warning-cone/staticmapping evidence,not fullprimitive/physicalproof.
Added rtl/cnn_control.v,tb/tb_cnn_control.v,tools/test_control.py,CSR.md.
ActualCSR loader withACK-basedcursor,heldresponses,start/done/errors,synchronous
10597word traceRAM captures everylayer;successonlyreadaccess;buildID readout.
test_control.py PASS control_20261020T190709765497Z:3fullruns/sameweights,
31791exactreadbackwords,heldCSR,invalid/busy/partial/unalignedaccesses,
failedloadcursorretention/buildID;source+payloadhashescurrentverified.
Added examples/25k/cnn_top.v,cnn.cst,tools/build_board.py. UnchangedUARTtransport
supplementarybinding,11verified25Kpins,registeredprobes;not harduserJTAG.
Build freezes allinputs,embeds64bitsource/configfingerprint,recordsfullimagehash
separately;nohardwareattestation orloadedimagehashclaim.
Board build8765 live:board_20261020T190825980172Z. No terminalPPA/Fmax/download.
IP03 same71786 stilllive actualrouting near106000iterations;do not restart.
Currentphysicalboard20K;required25K/JTAGphysicalgates andremainingIP00..10 OPEN.

Terminal follow-up:ISP71786 route/packPASS,board_20261020T184939354706Z:
96.721153MHz vs50MHz constraint,16762LUT4,2636ALU,7261DFF,16BSRAM,11IOB,
zeroDSP/PLL. Frozeninput+imagehashverified;SHA256
f6a42edd215e9d1e3bc94bedfd0fc4235f9eeed341d778af3292b71c25f7dc57.
Fullbypass/Gammareuse currentRTL image,notdownloaded. LUT4mapping successful;
this does not independently prove why earlier wideLUT placement failed.
CNN8765 terminalFAIL:RAM16SDP4 noBELs (control.engine.biases.0.9).
Preserved artifact. build_board.py now -nolutram to avoidunsupporteddistributed
RAM;no functionalRTLchange. A new frozenbuild started;poll its ownhandle.
CNN new build session11963:board_20261020T190955731593Z,stillrunning;
no terminalresource/Fmax/downloadclaim.

### IP-05 host workflow,bit-serial full inference and final board PPA (2026-10-21)
Previous turn progressedCSR fullreadback and RAMmappingaudit.
CNN11963 terminalroute/packPASS board_20261020T190955731593Z:
71.751449MHz vs50MHz,2839LUT4,1138ALU,1090DFF,30BSRAM,163MUX2_LUT5,
11IOB,zeroDSP/PLL. -nolutram avoidsunsupportedRAM16SDP4. Fingerprint
7b07213c07e31a2f,packedSHA256
8152f7b03c00fcc50049bb1e9ff4e82365ca187cc9605f44707db7c765e31609.
Hostvalidate_build andallsource/snapshot/imagehashchecksPASS. Notdownloaded.
Added tools/cnn_host.py,run_uart.py,test_host.py,HOST.md;SPEC/ENGINEupdated.
Model/inputmanifest/rangevalidation,loadedfingerprintbinding,loadweightsonce,
3fullinputs,all10597valuesperinput,coherentheldcompletion,partialcapture/logs,
noACK/retryonfailure. ExistingUartCsr reusedunchanged.
test_host.py PASS host_20261020T191325051805Z:31791actualRTLpayloadwords,
fragmentedwirecodec,fingerprint/corruptnumeric/count/timeoutrejections.
run_uart.py --help PASS;actualbuildvalidatorPASS. No physicalUARTinvocation.
Added tb/tb_cnn_uart.v,tools/test_uart.py. terminalPASS
uart_20261020T191404769960Z:entire4244weights+22biases+784inputbytes loaded
through real bit-serialUARTtop,nohierarchicalmemoryshortcut;completeinference,
10scores+Top3exactPythonmatching,fingerprint/readbackstate/errorACKchecks.
Accelerated8clockUARTbits explicitlysimulationonly;notphysical115200evidence.
Host+UARTevidence sourcehashes currentverified.
Boardnetlist narrowDPB warningaudit PASS ram_audit_board_20261020_initial
usingaudit_ram_mapping.py --top cnn_top;no usedhighbit/liveunknownwrite.
ActualCSR simulation cycles314065 eachinput (=6.2813ms nominal50MHzcompute,
notmeasuredboardlatency/endtoendrate). PhysicalgatesremainOPEN.
Asked userasynchronously whether25KJTAG/LA nowconnected;currentrecordstill20K.
Noanswerassumed. HardJTAG25Kbackend/LAphysical andallremainingIP00..10 OPEN.

### IP-06 four-channel lock-in datapath and quantified error regression (2026-10-21)
Previous turn completed CNNhost/serialsimulation/finalPPA;25Kconnectionreplypending.
Read IP06requirements/reused dds_nco.v+cordic.v unchanged. Created
cores/signal_processing/lockin/rtl/lockin4.v,tb/tb_lockin4.v,tools/gen_vectors.py,
test_lockin.py,synth.py,vectors/,SPEC.md. Four simultaneoussigned16lanes,
atomicphase/gain/offset/runconfig,tworeusedDDS quadratureROMs,calibrationclip,
48bitboxcarIQ/power2decimation,sharedCORDICamplitude/phase,first/lasttimestamps,
heldresults,explicitdesync/cadence/clip/configerrors. Maxinput1vector/2clocks;
nofull-rateADC/analogclaim. Timestampinputsnotwallclockqualification.
Initialtests191836341340Z harnessFAIL(pathbackslashes+heldsnapshotwidth),
191848583100Z numericFAIL lowamplitudeerror13>12. Preservedallfailures.
AddedCORDICinputnormalization+reverseamplitudescale;thresholdsunchanged.
CURRENT test_lockin.py PASS lockin_20261020T191949590621Z:
3frequencies/4lanes/12combinations,amplitudes64..28000,allquadrants,
exactIQ/timestamps,gaps/heldoutput,offsetcalibration/configlatch,clipping,
channel/cadencealarm,invalidcommand/reset/recovery. Maxamperror8counts,
maxphaseerror0.002869766rad. CSV+JSON explicitlydigitalRTLsimulation,
notphysicalmeasurements. CurrentsourcehashauditPASS.
Firstisolatedsynth synth_20261020T192021399838Z FAIL unuseddefaultDDSROMfile;
newfrozen synth.py -defer elaboratesactualparameterizedROMpaths.
Session37299 synth_20261020T192050098558Z live;pollsamehandle. NoPPA/Fmaxclaimyet.
VirtualADC/livecommontimestamp,CSR/control/board/JTAG/LAphysicalremainOPEN.
FullIP00..10goalACTIVE;noearlierphysicalgatewaived.

### IP-06 fixed-clock virtual ADC and live timestamp/lock-in integration (2026-10-21)
Previous turn developed lockin4/exactIQ/amplitudephaseerrors and startedsynthesis.
Added rtl/virtual_adc4.v,tb/tb_live_adc_lockin.v,tools/test_live.py,VIRTUAL_ADC.md.
Reuses sys_timestamp64 unchanged;4synchronouscosROMreads,atomicamplitude/phase/
frequency/period,scheduledticksdonotwaitforready,timestampcapturedatactual
simulatedsampleevent,onevectorheldbuffer,explicitoverflow/dropcounts,
finitecompletionafterdrain/invalidcommand. Ownerabortofincompletecoreblock
stillrequired next;nooverflowedmeasurementacceptedassuccess.
Initial live_20261020T192444063062Z and live_20261020T192503764298Z FAIL
testbenchACKdidnotspanposedge afterwait(done);all failuresretained.
CorrectedonlyACKtiming;CURRENT test_live.py PASS
live_20261020T192530361459Z:768fourlanevectors,3frequencies/periods4,16,37,
exactsynthsamples/IQ/clock-derivedtimestamps,12errorrows,maxamp8counts,
maxphase0.002869766rad. Blockedsource16generated/1accepted/15dropped,
heldoutput/overflow/finitecompletion/invalidperiodPASS.SourcehashauditcurrentPASS.
Theseare digitalclockedsimulations,notphysicalADC/boardmeasurements.
Same37299 isolatedcore synth_20261020T192050098558Z stillLIVE:
yosys53184/ABC11320 confirmedCPUadvancing(~320sABC),atABC9mapping.
No restart/terminalPPA/Fmaxclaim. This frozenbuilddoesnotinclude newADCmodule.
25Kconnectionreplypending;CSR/replayabort/board/hardJTAG/LAphysical remainOPEN.
FullIP00..10goalACTIVE.

### Primer20K LA recheck (2026-10-21)
User confirmed current board20K. IDCODE0x081B verified; fresh forward/reverse SRAM program +2MS/s400000sample captures PASS all8channels. CH0..7=T6,P6,T7,R8,T8,P8,P9,T9. Evidence:artifacts/tang20k_la_recheck_20261020T1932309757938Z. No NOR write/RTL changes/new synthesis; current SRAM reverse calibration. Broader25K physical gates remain open.

### IP-06 bounded replay, recovery, atomic admission (2026-10-21)
Previous goal turn progressed: fresh20K forward/reverse LA physical evidence.
Verified isolated synth_20261020T192050098558Z terminalPASS summary/design.json;
no live yosys/abc process. LUT1=82,LUT2=1718,LUT3=6872,LUT4=5037,
ALU1925,DFFCE2261,SPX9=2,MUX2_LUT5=519; no routedFmax/full-systemPPA claim.
Earlier replay owner/sourceabort implementation now documented in REPLAY.md.
Latest replay_20261020T193515986879Z PASS:5clean exactIQ runs,5expliciterrors,
zero failed data,heldresults,postfault recovery,timestamp continuity/globalreset.
Sourceabort regression live_20261020T192957227460Z previouslyPASS768vectors.
Added rtl/lockin_config.v,tb/tb_lockin_config.v,tools/test_config.py;
canonical sys_atomic_config unchanged. config_20261020T193514150817Z PASS
sameedgewritecommit,bytemasks,stalledcommand,queuedcommit,pendingwriteisolation,
exactlyoncelaunch/reset. Command:python cores/signal_processing/lockin/tools/test_config.py;
python cores/signal_processing/lockin/tools/test_replay.py (env.ps1 loaded).
No new synthesis for config/replay. CSR decoder/fieldmap/boardtop/host/P&R
and25KhardJTAG/physicalerror-tableacceptance remainOPEN. Currentphysicalboard20K.
FullIP00..10goalACTIVE;no physical requirement substituted by simulation.

### IP-06 real CSR operation/control (2026-10-21)
Previous turn progressed atomicconfig/replay/synth evidence. Added
rtl/lockin_control.v,tb/tb_lockin_control.v,tools/test_control.py,CSR.md.
Transport-neutral one-outstanding CSR,bytewrites,16wordcanonicalatomicbank,
queuedcommit/onceperversion launch,heldresult/explicitACK,buildID,errorguards,
4laneIQ/amp/phase,counters,64bittimestamps. No underlying DSP/sharedRTL edits.
Initial manual compile control_20261020T1936433417361Z
failed PowerShell wildcard passed literally; retained. Python explicit source
runner fixes harness. control_20261020T193706850165Z firstPASS IQ/queue/guards.
CURRENT control_20261020T193751291194Z PASS2successfulruns/1timeout,
8independent exactIQpairs,8amplitudephase readbacks withinexisting12count/.06rad
limits,first/last1020clockspan and monotonic epoch,heldCSRresponse/results,
pendingwrite/commitreject,invalidaddress/read/ACK,version3/noextra launch.
Command:. ./scripts/env.ps1;python cores/signal_processing/lockin/tools/test_control.py.
Resource impact not synthesized; isolatedcore priorPPA is not fulltopPPA.
Boardtop/build/host/hardJTAG/25Kphysical remainOPEN. Physicalboard20Kconfirmed.
FullIP00..10goalACTIVE;no completion claim.


### IP-06 25K board binding/build and numerical host (2026-10-21)
Previous goal turn progressed actualCSR control and8exactIQ/polarreadbacks.
Added examples/25k/lockin_top.v,lockin.cst,tools/build_board.py,
tb/tb_lockin_uart.v,tools/test_uart.py,INTEGRATION.md,HOST.md.
Unchanged sharedUART/transport,50MHzE2,C3TX/B3RX,25K8probe pinmap.
UART bitserial simulation PASS uart_20261020T193915198789Z:
real serial config/queue/results,8exactIQpairs,polar/timestamps/timeoutguards.
UART8clockbits acceleratedsimulation only;no physical serial claim.
Build board_20261020T193929762414Z live session48611: frozen source/ROMs,
derivedfingerprint,read_verilog-defer,synthnolutram,50MHzroute requested.
Latest authoritative yosys41096/ABC34644 live,ABC CPU109s atABC9mapping;
no restart/no fulltopPPA/Fmax claim. Poll same48611.
Added tools/lockin_host.py,run_uart.py,test_host.py. Host verifies buildimage/
sourcehash/fingerprint,16wordatomicconfig,exactIQ/amp/phase,coherentheldresults,
version/counters/timestamp,finitepolls,savebeforeACK,noautomaticretry.
Modified CSR TB logs actual numeric words for host fixture.
control_20261020T194046823233Z PASS;latest test_host reruns actualRTLfixture.
host_20261020T194149336568Z PASS actualRTLwords,10negativecases(noACKonfailure).
run_uart.py --help PASS;no physical invocation. Host3freq/12lanetable on25K
stillrequires actualcompletedbuildandhardware. HardJTAGruntime remainsOPEN.
Newtop/source frozen build neverdownloaded. Physicalboard20K peruser.
FullIP00..10goalACTIVE;IP06routedbuild/physical andIP07..10 remain required.

### IP-06 release evidence and IP-07 reuse baseline (2026-10-21)
Previous turn progressed25Ktop/UARTsimulation/host acceptance/buildlaunch.
Added IP06 VALIDATION.md,LICENSE_DEPENDENCIES.md,CHANGELOG.md,PPA_25K.csv;
explicitly distinguishes isolated mapping/fulltop inprogress,openlicense,
25KhardJTAG/L3/analog gates. No distribution grant/release claim.
Regressions:config_20261020T194350676278Z PASS;
replay_20261020T194352030144Z PASS5clean/5failure;
live_20261020T194353639738Z PASS768vectors/12errorrows.
Commands test_config.py,test_replay.py,test_live.py (env.ps1).
Same build board_20261020T193929762414Z/session48611 remainsLIVE;
yosys41096 andABC34644 confirmed,ABC CPU236s then continued. No restart.
No fulltopPPA/Fmax yet. Pollsame48611; current source/ROM frozen inbuild.
While build runs,started IP07canonicalreuseaudit only: added
cores/communication/ethernet_udp/tools/test_baseline.py andREUSE_AUDIT.md.
Frozen unchangedav_rmii_rx/av_udp/av_async_fifo/tb_av_udp.
Command python cores/communication/ethernet_udp/tools/test_baseline.py PASS
reuse_baseline_20261020T194452803866Z:7168bytes,13TXframes,ARP/FCS/IPv4,
asyncFIFO/duplicate/futuresequence/creditexhaustion/retry/debugCRC.
This is20KcanonicalRTLsimulation,NOT25Ksubsystem/PHY/throughputacceptance.
NV01protocol is application-specific;genericUDPstreamTX/packetcontract,
25Kcontrolledreplay/control/P&R/physicaladapter remainOPEN. av_phyofficialSMI
provenance andlicense require audit,notclaimedportable/original.
FullIP00..10goalACTIVE. Current physicalboard20K;25KgatesremainOPEN.
Finalpollsame48611 stilllive:ABChelper exited;yosys41096 CPU20.75s,logadvancedto13.43AUTONAME afterHILOMAP. Notterminal/noPNRlogyet. Continuepollsamehandle.

### IP-07 FCS-qualified packet stream adapter (2026-10-21)
Previous goal turn progressed IP06releaseevidence/IP07canonicalbaseline.
Added rtl/rmii_frame_stream.v,tb/tb_rmii_frame_stream.v,
tools/test_frame_stream.py,FRAME_STREAM.md underethernet_udp_25k.
Canonical av_rmii_rx/sys_timestamp64 unchanged. Bytevalidreadykeeplastuser,
wholeframeFCSqualified,preamble/FCSremoved,heldbankuntilacceptedlast,
sequence/dequeuetimestampmetadata,deliveredbyte/framecounter,overflow/recovery.
Timestamp explicitlydequeue-notwirearrival;common50MHz,nohiddenCDC.
Firstframe_stream_20261020T194711531337Z compileFAIL reservedSVsequence;
renamedframe_seq only. Preservedfailure/currentgoldensunchanged.
CURRENT frame_stream_20261020T194725426502Z PASS2016exactorderedbytes/6frames,
60..1514streambytes,randomstalls/heldmetadata,lastboundary,badFCSdrop,
twobankexhaustion/overflow andcleanrecovery. Commandtest_frame_stream.py.
No synthesis/resourceclaim. GenericUDPpayloadparser/TX,checksummetrics,
25Kcontrolledreplay/CSR/P&R/PHY remainOPEN;RX_ER limitation documented.
IP06samebuild/session48611stillLIVE:y osys41096 (actualyosys.exe),
CPU135.36s finalcheck,13.43AUTONAMEafterABCmapping;noPNRlog/terminalyet.
Do not restart quietbuild. Pollsame48611. FullIP00..10goalACTIVE.

### IP-07 generic IPv4/UDP payload receive (2026-10-21)
Previous turn progressed FCSqualifiedframeadapter andindependent2016bytecheck.
Added rtl/udp_payload_rx.v,tb/tb_udp_payload_rx.v,tools/test_udp_rx.py,UDP_RX.md.
StorewholeEthernetframe,synchronous2048bytebuffer,validatebeforeoutput,
localMAC/IP/portfilter,nooptions/fragments/VLAN,IPv4headerchecksum,
UDPpseudoheader+oddpadchecksum(IPv4zeroallowed),exactlength/metadata/keepguards,
emptykeep0last1packet,sourceIP/port,heldoutput,prioritizederrorcounters.
Command:. ./scripts/env.ps1;python cores/communication/ethernet_udp/tools/test_udp_rx.py.
udp_rx_20261020T195018003771Z PASS7good/7rejected,independentPythonencoder,
exactpayload/boundaries,0/1/2/7/63/1472/33bytes,nonzero/zeroUDPchecksum,
IPv4/UDPcorrupt,wrongport/MAC,fragment,length,truncated,seededgaps/stalls.
No synthesis/resourceclaim. NotyetcombinedRMIIpipeline;TX/sequenceCRC/control/
25Kbuild/physicalremainOPEN. Missinglast requiresownertimeout;documented.
IP06same48611stillLIVE:yosys41096CPU302.20s,13.43AUTONAME;ABCgone,
noPNRlog/terminal. Do notrestart forquietlog;pollsamehandle.
FullIP00..10goalACTIVE;no physical/releasegatewaived.

### IP-07 end-to-end RMII-to-UDP receiver integration (2026-10-21)
Previous goalturn progressedgenericUDPstoreforwardreceiver.
Added rtl/rmii_udp_receiver.v,tb/tb_rmii_udp_rx.v,tools/test_rmii_udp.py;
updated UDP_RX.md. Actualwrapper canonicalRMII->FCSframe->genericUDPpayload.
Initial195207220349Z compileFAIL forwardwiredeclaration;195216475776Z
benchFAIL fixed7000clockwaitinsufficientfor1514byteinput+1472byteoutput;
195229655222Z benchFAIL idleracebeforeCRSpublish. Allfailuresretained.
Correctedonlydriver:waittwoclocksforpublicationthenrealbank/ownerdrain;
RTL/goldensunchanged. Initial195237721828Z PASS7good/7rejected.
AddedbadEthernetFCSnegative:195259222003Z PASS7good/8rejected.
CURRENT rmii_udp_rx_20261020T195401264490Z actualwrapperPASS:
7goodexactpayloads(empty/odd/even/1472maximum/zeroUDPchecksum),6UDP/IP/header
rejects,2Ethernetlength/FCSrejects;13FCSgood/2bad/0overflow,seededoutputstalls,
stablemetadata/sourceaddress,lastboundaries. No line-rate/burstthroughputclaim.
Command python cores/communication/ethernet_udp/tools/test_rmii_udp.py (env.ps1).
No synthesis/resourceimpactmeasured;genericTX/control/replay/P&R/25Kphysicalopen.
IP06buildsame48611live:yosys41096CPU457.48s,logadvanced13.44.2hierarchy
(afterAUTONAME). No restart/no finalPPAyet. FullIP00..10goalACTIVE.

### IP-07 generic UDP transmit frame packetizer (2026-10-21)
Previous goal turn progressed actualRMII-to-UDPwrapperregression.
Added rtl/udp_frame_tx.v,tb/tb_udp_frame_tx.v,tools/test_udp_tx.py,UDP_TX.md.
DescriptorlatchesdstMAC/IP,ports,length/IPid/user;0..1472payload,syncbuffer,
IPv4/UDPpseudoheaderchecksum,oddpad/complementzero->ffff,minEthernetpadding,
readyvalidkeeplastuser,heldcompletion/explicitinvalidlength/keep/boundaryerrors.
Malformedsourcesdrainthroughlast;missinglastrequiresownertimeout,documented.
Command:. ./scripts/env.ps1;python cores/communication/ethernet_udp/tools/test_udp_tx.py.
udp_tx_20261020T195626047247Z PASS6exactframes(payload0/1/2/7/63/1472),
independentPythonnetworkencoder,IP/UDPchecksums/pad,4errorcompletions,
seededinputgaps/outputstalls,latchedcommand/heldcompletion. NoRTLgoldenrewrite.
No synthesis/resourceimpactmeasured. RMIIserializer/FCS/IFG andfullreplay/control/
sequenceCRC/P&R/25KphysicalremainOPEN. No wirethroughput/PHYclaim.
IP06same48611LIVE:yosys41096CPU547.70s at13.44.2hierarchy;
noABC/nextpnr/terminalyet. Preservejob/pollsamehandle,dontrestartquietwork.
FullIP00..10goalACTIVE;physicalboard20K,25KhardJTAG/physicalgatesOPEN.

### IP-07 RMII wire transmitter; IP06 placement failure/retry (2026-10-21)
Previous turn progressed genericUDPpacketizer with6exactframechecks.
Added rtl/rmii_frame_tx.v,rmii_udp_transmitter.v,tb/tb_rmii_udp_tx.v,
tools/test_rmii_tx.py,RMII_TX.md. Wholeframebuffer,uninterrupted50MHzRMII,
7x55/D5,lowdibitfirst,EthernetFCS,48clockIFG,heldwirecompletion/counters.
Integratedcompletionwaits actualwireFCS+IFG,notpacketizerend.
udp_rmii initialdirectchain testPASS rmii_udp_tx_20261020T195842238553Z;
CURRENTactualwrapper rmii_udp_tx_20261020T195916105200Z PASS6exactwireframes,
independentIPv4/UDPencoder+zlibCRC,FCS/preamble/pad/IFG,4packetizererrors,
inputgaps/latchedconfig/heldcompletion. Serializerstandaloneerrorsnotyettested.
Commandtest_rmii_tx.py;no synthesis/resourceclaimforIP07.
IP06session48611terminalFAIL125: synthesisPASS,placementUnablefindlegalcells.
Failure board_20261020T193929762414Z preserved:21237LUT1..4,
2679ALU,5294DFFCE+15DFFPE+80DFFRE,2SPX9,1389MUX5/89MUX6/10MUX7.
No routedFmax/download;PPAcsvupdatedfailure. Do notclaimbudgetclosure.
Added --nowidelut option tobuild_board.py(noRTLchange),startedfresh
board_20261020T195941640556Z/session20865 nowLIVE. Preserve/pollsame20865.
Allfeaturesretained;nomappingrootcauseassertion,newrouteoutcomeunknown.
FullIP00..10goalACTIVE;25KhardJTAG/physical/remainingIP07..10OPEN.

### IP-07 full digital UDP/RMII loopback (2026-10-21)
Previous goalturn progressedRMIIserializer/wrapperwiregolden/IP06retrylaunch.
Added tb/tb_udp_loopback.v,tools/test_loopback.py,SPEC.md. Actual
rmii_udp_transmitter RMIIpins wiredto actual rmii_udp_receiver;noFCS/IP/UDPbypass.
Command:. ./scripts/env.ps1;python cores/communication/ethernet_udp/tools/test_loopback.py.
loopback_20261020T200130895532Z PASS7goodpackets/1578exactapplicationbytes,
0/1/2/7/63/1472payloadsplus33byteposterrorrecovery,4malformedTXcompletions,
seededrxstalls,sourceIP/port/sequence,timestampmonotonic,packetboundaries,
receivergood7/allerror0/transmitted7. Onepacketownedatatime;no linratethroughputclaim.
No synthesis/resourceimpactforIP07. Replayowner/CRCsequence/timeout/control/
25Kbuild/physical/PHY remainOPEN. SPECmapscurrentmodulesandopenrequirements.
IP06same20865buildboard_20261020T195941640556ZstillLIVE:
yosys17460CPU38.98s,ABChelperexited,13.43AUTONAME. Preserve/pollsame20865.
Prior48611placementFAILpreserved. FullIP00..10goalACTIVE.

### IP-07 synthesizable bounded sequence/CRC replay (2026-10-21)
Previous goalturn progressed actualTX/RXloopback1578byteevidence.
Added rtl/udp_replay.v,tb/tb_udp_replay.v,tools/test_replay.py,REPLAY.md;
updatedSPEC. ActualUDP/RMII/FCS/IPdatapath,dynamicpacketcount/length/seed,
sequenceprefix/bytecompare/cumulativeCRC,seededrxstalls,wholewirecompletion,
finiteglobaltimeout,FCSfault/blockedsink,abort/coreclear,heldownercounters/result.
Countersdefinedprecisely:tx_packetspairedcompletion,tx_bytesinputsubmitted,
failedpartialsnotthroughputsuccess. RawCRCregisterscomplementforzlib.
First replay_20261020T200407852250Z PASS3clean/4errors.
CURRENT replay_20261020T200439035646Z PASS4independentexactCRCsuccesses,
4errors,FCSinjection/blockedsink/exact5clocktimeout/invalidcommand,
mutatedcommandpins(noeffect),globalresetduringload,postfaultcleanrecovery,
heldresults. Commandpython cores/communication/ethernet_udp/tools/test_replay.py.
No synthesis/resourceclaim. Somepayload/transmitterterminalbranchesuntested;
CSR/25Kbuild/JTAG/physicalremainOPEN,documented.
IP06same20865LIVE:y osys17460actualyosys.exeCPU208.05s at13.43AUTONAME.
No restart/noPNRclaim. Pollsame20865. FullIP00..10goalACTIVE.

### IP-07 atomic CSR and coherent replay acceptance (2026-10-21)
Previous goalturn progressed synthesizable sequenceCRC/timeoutreplay.
Added rtl/udp_control.v,tb/tb_udp_control.v,tools/test_control.py,CSR.md;
updatedSPEC. Canonicalsys_atomic_config8wordsunchanged,byte-maskedshadow,
appliedversiononcepercommand,onequeuedcommitwhilebusy,heldresultACK,
latchedrunID/buildfingerprint,complementedTX/RXCRC,packet/byte/cyclecounters,
8bitprobe,errorguards/responsebackpressure. No sharedcanonicalRTL edits.
Command:. ./scripts/env.ps1;python cores/communication/ethernet_udp/tools/test_control.py.
control_20261020T200657537879Z PASS2realCSR/RMIIrunreadbacks,
independentcounter/CRCgoldens,queuedconfig/partialbytemasks/frozenactive,
pendingwritecommitreject/heldresultcoherence/invalidcommand/ACK/version3.
No synthesis/resourceimpactfornewIP07control. Boardbinding/transport/build/
25KJTAG/physical remainOPEN. FullIP00..10goalACTIVE.
IP06same20865stillLIVE,no terminaloutput;pollsamehandle,retainpriorplacementFAIL.

### IP-07 serial board binding/build and host acceptance (2026-10-21)
Previous goalturn progressedatomicCSR/realcounterCRCreadback.
Added examples/25k/udp_top.v,udp.cst,tb/tb_udp_uart.v,tools/test_uart.py,
build_board.py,udp_host.py,test_host.py,INTEGRATION.md;updatedSPEC.
UnchangedsharedUART/transport,50MHzE2,C3TX/B3RX,25K8probepinmap.
UART8clockbitactualserialsimulationPASS uart_20261020T200838231691Z:
2exactcounterCRCrunreadbacks/queuedcommit/invalidcommand/ACK;notphysical.
Byte-strobemasking belongs toCSRtest only,notserialwire;runnerprintcorrected.
Frozen completeboardbuild board_20261020T200904372694Z/session23848 LIVE:
synthesisPASS,actualPNRplacerprogress atrefinementiter25. -nolutram-nowidelut,
allfeaturesretained. No routedFmax/image/downloadclaimyet. Pollsame23848.
Hostboundedconfig/identity/poll/numericCRC/counter/version/coherence/savebeforeACK;
16MiBhostacceptanceprofile,RTLlimitsunchanged. host_20261020T201012296195Z PASS
actualCSRRTLfixture+10corruption/identity/timeoutguards,noACKonfailure.
PhysicalCLI/buildvalidator/hardJTAGbackendstillOPEN,notimpliedbyhostunitpass.
IP06same20865stillLIVE:yosys17460CPU465.70s at13.44.2hierarchyafterAUTONAME.
Preserve/pollsame20865. No terminalPPAforIP06retryyet.
FullIP00..10goalACTIVE,25Kphysical/IP08..10/releaseauditremainOPEN.

### IP07 route/pack PASS, UART acceptance CLI; IP06 retry failed (2026-10-21)
Previous goalturn progressedIP07boardbinding/buildandhosttests.
Session23848terminalPASS:board_20261020T200904372694Z full25K50MHzroute/pack.
Finalpnr_report106.678047MHz;5278LUT4,1782ALU,2971DFF,5BSRAM,11IOB,
0PLL/DSP. Earlier5823LUT4wasplacementstage,NOTfinal. PPA_25K.csvexportsfinal.
Fingerprint07162472fe1a28f3,packedSHA25600417c03f79a50b9aa6882044f592fb012199129cc7e00c10ad02eb14991dd7d.
Allsource_snapshot hashes/currentinputs/image validated;notdownloaded.
Added udp_host.validate_build,tools/run_uart.py,VALIDATION.md;updatedINTEGRATION.
CLI3finiteinternalRMIIprofiles,validatesbuild/source/image/fingerprint,
savespartial/fullcaptures/hosthashes/rawwirelog,noautoACKonfailedverification.
run_uart.py --help PASS;actualbuildvalidatorPASS;nohardwareinvocation.
host_20261020T201241009469Z PASSactualRTLfixture+10negativeguards.
Commandstest_host.py/run_uart.py--help/actualvalidate_build+snapshothashaudit.
IP06session20865terminalFAIL125:board_20261020T195941640556Z synthesisPASS,
placementFAILunablelegalcells. ActualPNR24626/23040LUT4(106%),2828ALU,
5389DFF,2BSRAM. No resourceclosure/Fmax/download. PPAcsvupdatedfailure.
Nowidelutdidnotfit;bothfailurespreserved. NextmustreduceLUTarithmeticsize
orusequalifiedGW5ADSPmapping,noretrywithoutmeaningfulchange.
No livejobsfrom23848/20865. FullIP00..10goalACTIVE;hardJTAG/25KphysicalOPEN.

### IP06 exact resource optimization and third full build (2026-10-21)
Previous goalturn progressedIP07routepack/CLI andprovedIP06secondplacementFAIL.
Modified lockin4.v averagingonly:fixedfractional15bitdropthen33bitvariableshift;
48bitaccumulators,cyclecadence,goldens/tolerancesunchanged.
Added tb/average_equivalence.v; SATall48bit/all16shiftcodes PASS
average_proof_20261020T2015088869463Z. Isolatedmapping112LUT3+5ALUbefore,
92LUT3+2LUT2+4LUT4after(average_mapping_20261020T201533551709Z).
Notenoughalone. ActualGW5AsynthhasnoautomaticDSPinference;nohardDSPclaim.
Measured17x17signedBooth843->585LUT1..4,ALU34->33:
booth_mapping_20261020T201611834080Z. Scriptswork/measure_lockin_average.py,
measure_lockin_booth.py preserveexperiments. No fulltopresourcepredictionclaim.
Added tools/test_booth.py:initial201655703977Z FAILmissing$fa simulation;
fixedharnesstechmap,booth_test_20261020T201711034135Z PASS5081Pythonproducts.
RegressionsPASS lockin_201509477616/live_201511693961/replay_201536830422/
control_201538185573/uart_201539248207 (all20261020Tprefix).
Modified build_board.py exactBoothloweringbefore synth; priorlocaltestpassed.
Started board_20261020T201758272933Z session70147 LIVE,nofinalPPAyet.
Pollsame70147. Priorjobs20865/48611areterminalFAIL,norestartthosehandles.
Added RESOURCE_OPTIMIZATION.md/PPApendingrow. No hardwaredownload.
FullIP00..10goalACTIVE;physical25K/hardJTAG/IP08..10/releasegatesOPEN.

### IP07 serializer fault coverage and release dependency records (2026-10-21)
Previous goalturn progressedIP06exactarithoptimization/thirdbuildlaunch.
Added tb/tb_rmii_tx_errors.v,tools/test_rmii_tx_errors.py;
rmii_tx_errors_20261020T202002347627Z PASS2independentexactwireframes,
5rejects(short/oversize/keep/metadatachange/drain),heldcompletion,
resetduringloading/recovery/counters/noinvalidwireoutput.
Command:. ./scripts/env.ps1;python cores/communication/ethernet_udp/tools/test_rmii_tx_errors.py.
NoRTL/buildsourcechanged,existing25Kimagehashstillapplies;noresourceimpact.
Added LICENSE_DEPENDENCIES.md,CHANGELOG.md;updatedRMII_TX/SPEC tocurrent
implementedmilestonesandopenphysical/licensegates. Requiredreleasefilenames
nowpresent,butlicense/L3/L5acceptancenotclaimed.
IP06same70147LIVE:yosys43388CPU105.63s,20.42AUTONAME,
no terminalPPAyet. Preserve/pollsame70147,do not restartquietbuild.
FullIP00..10goalACTIVE;physical25K/hardJTAG/IP08..10/releasegatesOPEN.

### IP08 two-layer elastic OSD and cadence (2026-10-21)
Previous goalturn progressedIP07standaloneserializerfaultcoverage/releasefiles.
ReadworkorderIP08/canonicalvideo_timing_generator/cip_image_osd/frame_switch4/
img_mf_rgb_blend_pipe. Addedvideo_compositor_25k/rtl/dual_osd_stream.v,
tb/tb_dual_osd_stream.v,tools/test_dual_osd.py,SPEC.md.
Reusesunchangedcanonicalblend twice,orderedlayer0then1,exactalpha/colorkey,
layer1configcarriedinlayer0elastictag,metadata/errors/heldoutputs.
First dual_osd_20261020T202254784241Z PASS1024exactPythonpixels/metadata.
CURRENT dual_osd_20261020T202325056047Z PASSadds128continuousnostallpixels,
assertedII1afterfill;remainingseededgaps/stalls,alpha0/1/255/256/invalid,
layerenable/keyhits/highbitframeID/errorblack/metadataheldallmatch.
Commandpython cores/image_processing/video_compositor/tools/test_dual_osd.py.
No synth/resourceclaim. Multi-outputtiming/atomicframeupdates/CRC/routing/
25Kbuild/physicaldisplay/hardJTAG remainOPEN. FullIP00..10goalACTIVE.
IP06same70147LIVE:synthesisPASS,nowPNRnextpnr48316CPU29.13s,
actualplacement/routinglog authoritative;nofinalPPAyet. Pollsame70147.
Finalaudit:70147 PNR terminalFAIL legalplacement despite reduced19220LUT4/3098ALU/5381DFF/2BSRAM (83%LUTonly). Thirdbuildnotclosed. Preservefailure;nextmayretry frozen19220LUTnetlist withalternateplacerorimprovepacking;do notclaimsynthPASSasroutePASS.

### IP06 terminal retry audit; IP08 frame-safe configuration (2026-10-21)
Previous goal turn revalidated existing 20K calibration evidence; no new
development or hardware measurement in that turn. This turn makes RTL progress.
Inspected route_sa_20261020T202457966111Z summary/pnr.log: frozen third
netlist, SA seed2, terminal FAIL 3221225477 (Windows access violation),
last log initial placement 1000/27705 cells. No routed Fmax/image/download.
No nextpnr/yosys processes live at inspection. PPA_25K.csv now records both
third-build placement failure and alternate placer crash; synthesis cell
columns are not final packed utilization. Do not retry unchanged quietly.
Added video_compositor_25k/rtl/frame_atomic_config.v, its tb and
tools/test_frame_config.py; updated SPEC. Reuses unchanged sys_atomic_config.
Frame ownership and stalled first-pixel lock prevent mid-frame application;
pending commit gates the next frame for one cycle; partial writes and
same-edge write/commit supported. Generic payload must carry all metadata;
one instance per output; no CDC or board integration claimed.
Initial frame_config_20261020T202745051899Z and 202756647519Z FAIL:
test stimulus retained prior byte strobe; corrected wi2 full-write stimulus.
Current frame_config_20261020T202818097111Z PASS directed boundary,
head/tail stalls, held valid/config, queued commit, byte write, single-pixel,
malformed framing and reset. Preserved failures.
dual_osd_20261020T202819999281Z PASS 1024 independent golden pixels,
metadata, errors and II1 section after the new gate was added (separate tests).
Commands: . ./scripts/env.ps1; python cores/image_processing/video_compositor/tools/test_frame_config.py;
python cores/image_processing/video_compositor/tools/test_dual_osd.py.
No synthesis this turn; no resource impact measured. Multi-output integration,
timing/CRC, full25K physical/hardJTAG/license and remaining IP00..10 stay OPEN.

### IP08 independent parallel raster timing (2026-10-21)
Previous goal turn made RTL progress: frame-safe configuration gate and
regressions, with terminal IP06 failure audit. This turn adds
cores/image_processing/video_compositor/rtl/multi_output_timing.v,
tb/tb_multi_output_timing.v, tools/test_multi_timing.py and updates SPEC.
Reuses unchanged canonical video_timing_generator three times by default.
Independent per-output start/stop/abort, pixel_tick, latched timing/polarity,
32-bit frame count and 64-bit active/total tick counts; counters reset per start.
Canonical stop/abort completes at total frame boundary, not immediate blanking.
Command: . ./scripts/env.ps1; python cores/image_processing/video_compositor/tools/test_multi_timing.py.
multi_timing_20261020T202950172672Z PASS: 8743 exact raster/sync/counter
ticks against independent Python oracle, three resolutions and divisors1/2/3;
single-output stop/restart, abort, invalid timing, recovery do not disturb others.
Five successful run epochs checked; invalid epoch emits no pixels.
No synthesis/resource measurement or physical display claim. Timing wrapper
not yet integrated with OSD/source/routing/CRC/config or board control.
Next: actual composed pixels and per-frame CRC under concurrent outputs,
then coherent CSR/replay,25K build and physical gates. Full objective ACTIVE.

### IP08 parallel real OSD pixel/CRC paths (2026-10-21)
Previous goal turn progressed independent three-output timing/counters with
8743 exact oracle ticks. This turn adds rtl/video_frame_crc.v,
tb/tb_parallel_osd_crc.v, tb/tb_video_crc_errors.v,
tools/test_parallel_crc.py under video_compositor_25k; SPEC updated.
Three actual unchanged dual_osd_stream instances connect to passive CRC
monitors under independently seeded input gaps/output stalls.
CRC-32 ISO-HDLC over B,G,R bytes; captures accepted pixels only, SOF init,
LAST result pulse. Frame/length/pixel errors reported; no line/timeout claim.
First parallel_crc_20261020T203130860713Z PASS768pixels/24frameCRCs.
Current parallel_crc_20261020T203201059976Z PASS additionally7 exact
error/recovery results: missing/nestedSOF,IDchange,count,pixelerror,
stalledLAST,reset. Independent Python arithmetic and zlib golden used.
Command: . ./scripts/env.ps1; python cores/image_processing/video_compositor/tools/test_parallel_crc.py.
No synthesis/resources or board measurement this turn. These parallel elastic
streams are not yet integrated with raster timing/frame config/CSR/scanout.
Next is integrated source/routing/atomic layer config and raster data path,
not claiming separate timing and stream tests prove a physical display.
Full IP00..10 objective ACTIVE;25K physical/hardJTAG/license gates remain OPEN.

### IP08 integrated three digital scanouts (2026-10-21)
Previous turn progressed three actual elastic OSD/CRC paths and negative
monitor tests. This turn adds video_compositor_25k/rtl/raster_osd_output.v,
tb/tb_raster_osd.v,tools/test_raster_osd.py; SPEC updated.
Actual canonical timer+8word atomic_config+dualOSD+CRC in each lane, internal
solid/coordinate/gray reference sources, independent timing/ticks. Config
applies idle or last total-raster tick; all pixels snapshot their controls.
HS/VS/DE/version travel with pixel through six stages; blank output black.
No backpressure on scanout; overflow sticky and restart waits pipeline drain.
Command: . ./scripts/env.ps1; python cores/image_processing/video_compositor/tools/test_raster_osd.py.
raster_osd_20261020T203413908326Z PASS:2622 exact raster pixels/sync/markers/
versions/errors,51 zlib frame CRCs,6clock latency on all outputs,midframe
lane0 config commit visible frame3 only,three independent frame-boundary stops.
Source timings width4/5/6,height3 with blanking,divisors1/2/3; not fullresolution
throughput evidence. No synthesis/resource/physical claims this turn.
Remaining IP08: external stream routing,coherentCSR/replay/host,25Kbuild,
conditional physical display,hardJTAG/LA/license/release. FullgoalACTIVE.

### IP08 external elastic video routing (2026-10-21)
Previous turn progressed three complete reference scanout paths; this turn
adds video_compositor_25k/rtl/video_route4.v,tb/tb_video_route4.v,
tools/test_video_route.py; SPEC updated. Uses unchanged sys_frame_switch4
plus four frame_atomic_config instances. RGB/error traverse canonical data;
source-index tag selects full frame32/user16/SOF/EOL stable sideband from
the matching input, valid only because canonical switch has no beat buffering.
Per-source config word0 dest, commit after accepted frameLAST. No CDC or
unstallable-scanout buffer claimed. Preserves full metadata rather than truncate.
Command: . ./scripts/env.ps1; python cores/image_processing/video_compositor/tools/test_video_route.py.
video_route_20261020T203614464611Z PASS336pixels/32frames,contention,
random input gaps/output stalls,per-source midframe rerouting,nointerleaving.
Current video_route_20261020T203629296192Z PASS additionally RTL assertions
for held valid/all output metadata during backpressure. Exact Python oracle
checks each source order and destination changes starting its second frame.
No synthesis/resource/physical claims this turn. External-source buffering
to fixed raster,coherent CSR/replay/host,25Kbuild and physical gates remain.
Full IP00..10 objective ACTIVE; IP06 resource placement failure still OPEN.

### IP08 coherent per-output result ownership (2026-10-21)
Previous goal turn progressed external frame-safe route4; this turn adds
rtl/video_results_csr.v,tb/tb_video_results_csr.v,tools/test_results_csr.py,
RESULTS_CSR.md under video_compositor_25k and updates SPEC.
Three held snapshots: frame,CRC,pixels,error,version,captured serial,timestamp;
explicit ACK mask,occupied status and live drop counters. No overwrite while
host owns a record; simultaneous ACK/new result replaces without a drop.
Single outstanding CSR,held response,invalid/misaligned/partial ACK rejection.
Added raster_osd_output crc_version latched with accepted LAST; updated actual
scanout test and Python oracle to check frame/result version alignment.
Commands:. ./scripts/env.ps1;python cores/image_processing/video_compositor/tools/test_results_csr.py;
python cores/image_processing/video_compositor/tools/test_raster_osd.py.
First results_csr_20261020T203811212354Z FAIL TB reset-release delta-cycle
request-ready check; fixed test setup delay, preserved failure.
results_csr_20261020T203838457865Z PASS snapshots/coherence/overrun/ACKcollision/
heldresponse/errors/reset. raster_osd_20261020T203820852758Z PASS original
integration; latest raster_osd_20261020T203856310025Z PASS2622pixels/51CRCs
including exact associated CRC configuration versions.
No synthesis/resource/physical result this turn. Producer-to-mailbox/control
top wiring,external buffer,25Kbuild/physical/license/release gates remainOPEN.
Full IP00..10 goalACTIVE; no new hardware assumption or download.

### IP08 complete runtime scanout CSR integration (2026-10-21)
Previous turn progressed result mailbox CSR and CRC version alignment.
This turn adds video_compositor_25k/rtl/video_control.v,
tb/tb_video_control.v,tools/test_control.py,CONTROL_CSR.md; SPEC updated.
raster_osd_output now exports source_frame for finite-run boundary ownership.
Three real scanouts+resultmailboxes share10bit CSR; independent runtime
timings,dividers,finite targets,layerwrite/commit,start/stop/abort; rejects
timing updates while busy and start before committed layer version.
Automatic stop during final source frame ensures finite count without relying
on delayed CRC to stop. Ready waits pixel drain; first unACKed frame retained,
later results count drops,explicitACK before repeat run. No silent resets.
Command:. ./scripts/env.ps1;python cores/image_processing/video_compositor/tools/test_control.py.
control_20261020T204159595099Z PASS actual CSR requests/held responses into
three real pipelines:3frames/lane then1frame/lane,12producedframes,
6exact zlib/readback snapshots inclversion,2drops/lane,ACK/re-run without
reset,midframe layer commit,busy timing rejection and uncommitted-start error.
No synthesis/resources/download this turn. Next supplementary UART banked
address bridge/board binding,host and25Kbuild. External buffer/display,
hardJTAG/LA/license and remaining IP00..10 gates remain OPEN; goalACTIVE.

### IP08 supplementary banked UART and first25K build (2026-10-21)
Previous turn progressed full runtime scanout CSR integration. This turn adds
video_compositor_25k/rtl/video_uart_control.v,examples/25k/video_top.v,
video.cst,tb/tb_video_uart.v,tools/test_uart.py,tools/build_board.py.
UARTFC selects10bitCSRbank0..3; invalidbank rejects without change.
Unchanged canonical UART/framing; three real scanouts and held resultCSR.
Probe outputs registered1clock; same25K pinsG5,F5,G8,G7,H7,H8,J5,H5.
Added INTEGRATION/VALIDATION/LICENSE_DEPENDENCIES/CHANGELOG/PPA files with
open physical/license gates; no displayPHY or harduserJTAG claimed.
Command:. ./scripts/env.ps1;python cores/image_processing/video_compositor/tools/test_uart.py.
uart_20261020T204400456257Z PASS realbitserial8clock/bit boardtop,
4exactgoldenCRC/version snapshots,bankread/invalidbank,ACK/re-run.
Then python cores/image_processing/video_compositor/tools/build_board.py launched
board_20261020T204424990768Z,execsession61048 LIVE. Frozen sources/cst/build
hashes;targetGW5A-LV25MG121NES50MHz,nolutram/nowidelut. No download.
Latest inspection yosys35576LIVE CPU51.28s,13.43AUTONAME;no final resource/Fmax.
Poll same61048; do not restart a quiet synthesis. PPA row pending.
Full IP00..10 objectiveACTIVE;host/externalbuffer/25Kphysical/hardJTAG/license
and other unfinished IPs remain OPEN. Current hardware still confirmed20K.

### IP08 bounded host acceptance and same-build PNR (2026-10-21)
Previous turn progressed banked UART and launched first25Kbuild. This turn
polled SAME61048 repeatedly,never restarted. Synth35576terminalPASS;
now nextpnr48940LIVE CPU5.77s at inspection,originalartifact
board_20261020T204424990768Z. Synthesis6402LUT4/5520LUT3/2872LUT2/22LUT1,
2781ALU,7294DFF,0BSRAM/DSP;these are NOT final packed resources/Fmax.
Added video_compositor_25k/tools/video_host.py,test_host.py,run_uart.py,
HOST.md; VALIDATIONupdated. BankedCSRadapter,canonical bounded profiles,
independent exact blending/zlibgolden,loadedfingerprint/current+frozen
build/imagehash validation,finitepolls,coherentheldreadbacks,savebeforeACK.
No automaticACK/retry onfailedvalidation. Preservespartialcaptures/rawwirelogs.
Command:. ./scripts/env.ps1;python cores/image_processing/video_compositor/tools/test_host.py;
python cores/image_processing/video_compositor/tools/run_uart.py --help.
host_20261020T204810174143Z PASS actual UART RTL numerical fixture,
10negativecases,noACKonfailure,bankmapping. Auxiliarytimestamp/serial in
hostmock synthetic;separately covered by CSRRTL. Large320/640profiles only
prepared,notboardmeasurements. Physicalrunner NOTinvoked.
Buildsession61048 remainsLIVE PNR;pollsamehandle. FullIP00..10goalACTIVE;
25K/hardJTAG/LA/display/externalbuffer/license/release gates remainOPEN.

### IP08 first build terminal failure; measured exact Booth retry (2026-10-21)
Previous goal turn progressed bounded host checks and same-build PNR polling.
This turn polled same61048: terminal FAIL125. board_20261020T204424990768Z
unable legal placement,packed17664LUT4/2848ALU/7294DFF/0BSRAM/DSP/PLL/11IOB.
No routedFmax/packedimage/download. Preserved fullartifact;PPA/VALIDATION updated.
Added tools/measure_multipliers.py: initial multipliers_20261020T205059506049Z
FAIL Yosys command separator whitespace; fixed and preserved.
multipliers_20261020T205111632965Z PASS 5100 independent Python16x16/8x9
unsigned products through actual Booth/techmap logic; isolated mapping
LUT1..4sum813->695,ALU49->47. Not a fulltop equivalence/resource prediction.
Expanded tb_video_control invalid zero-width/noCRC,repair,abort10frame run
after firstframe,and clean restart. control_20261020T205143931427Z PASS;
updated test_control report to separate12normal/2errorrecoveryframes.
Commands:. ./scripts/env.ps1;python cores/image_processing/video_compositor/tools/measure_multipliers.py;
python cores/image_processing/video_compositor/tools/test_control.py.
After these local tests,modified build_board.py exact proc/flatten/opt/wreduce/
Booth before GW5Asynth. Launched board_20261020T205207679560Z session23357LIVE;
original firstbuild remains terminal. No unmodified quietbuild restart.
Final local report rerun control_20261020T205241682841Z PASS with corrected
12normal/2recovery accounting. Same secondbuild yosys14976LIVE CPU26.88s.
Next poll SAME23357,inspect final PPA;do notclaim isolated saving closes routing.
FullIP00..10goalACTIVE;IP06placement/externalbuffer/physical25K/hardJTAG/
LA/license/release remainOPEN. Currentboardconfirmed20K,notprogrammed.

### IP09 real complementary PWM protection start (2026-10-21)
Previous goal turn progressed IP08 error recovery and measured Booth rebuild.
This turn polled SAME23357; no restart. Synth14976 wasLIVE CPU151.58s,
hierarchy stage afterAUTONAME,artifactboard_20261020T205207679560Z.
Reviewed production_accel_25k canonical Clarke/Park/inversePark/SVPWM sector,
wave2 pwm_gen and located QEI/PID candidates. Explicit MULT12X12/packedformats
need numerical/interface audit before FOC integration; no standalone-kernel
passes substituted for a motorloop.
Added cores/control/motor_foc/rtl/pwm3_protection.v,
tb/tb_pwm3_protection.v,tools/test_pwm.py,SPEC.md. Unchanged canonical
wave2pwm_gen drives3lanes in test; new output stage hasDclock complementary
deadtime,zeroDstickyerror,asynchronousfaultgate+latch,disabledexplicitclear
after2sampledreleaseclocks. No powerstage certification or physical timingclaim.
Initial directcompile pwm3_20261020T2055054209647Z PASS retained.
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/test_pwm.py.
pwm_protection_20261020T205613940271Z PASS325cycles,D2/D3exacttiming,
nonoverlap,subclockfaultshutdown/latch,enabledclearrejection,config/recovery.
No synthesis/resources for IP09. Current/speed/position closedloop,SVPWMduty,
QEI/CSR/host/25K/LA/release stillOPEN. FullIP00..10goalACTIVE; sameIP08build
must be polled toterminal before any retry. Other physical/licensegatesOPEN.

### IP09 canonical Clarke/Park elastic chain; IP08 second terminal failure (2026-10-21)
Previous goal turn progressed PWM protection and verified wait on IP08build.
This turn SAME23357 terminalFAIL125:board_20261020T205207679560Z synthesis
PASS,PNR unablelegalplacement at17458LUT4/2794ALU/7290DFF/0BSRAM/DSP/PLL/11IOB.
NoFmax/image/download;PPA/VALIDATION updated,2failures preserved,no livebuild.
Read canonical Clarke/Park specs,table/model;added motor_foc_25k/rtl/current_transform.v,
tb/tb_current_transform.v,tools/test_transform.py,SPEC updated.
Uses unchanged canonical acc_clarke_s12+acc_park_s12+explicit simulationonly
MULT12X12 model. Own aligned angle/sampleID/sensor metadata storage across
backpressure;two-stageII1 pipeline,no regulator/PWMconnection claimed.
Independent math-generated trigtable verified against256sourcewords;
four-product Park golden differs structurally from canonical3productimplementation.
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/test_transform.py.
transform_20261020T205848043640Z PASS1024full signed records,all256angles,
128continuousII1,179sensorplausibilityfaults,randomgaps/stalls,heldmetadata.
No synthesis/resource impact measured. Next regulator/inversePark/SVPWM/plant
integration;IP08 needs meaningful larger resource/packing closure,not blindretry.
Useful lead: production_accel canonical MULT12X12 explicit primitive and model
exist (automatic GW5A inference still unsupported). Inspect isolated primitive
mapping/semantics before any IP06 DSP substitution; no new support claim yet.
FullIP00..10goalACTIVE;25Kphysical/hardJTAG/license/externalbuffer/openIPs remain.

### IP09 dual current PI with actual RTL numerical feedback (2026-10-21)
Previous goal turn progressed canonical Clarke/Park chain and terminal IP08
second placement failure. This turn read PID candidates/specs and chose
unchanged acc_ipi_pid_s12 conditional-integration implementation for twoaxes.
Added motor_foc_25k/rtl/dq_current_pi.v,tb/tb_dq_current_pi.v,
tools/test_current_pi.py;SPEC updated. Signed13 ref-minus-measured explicitly
clips to signed12;sharedruntimekp/ki/shift,restart/freeze,atomic d/q handshake,
sampleID,committedintegrals/diagnostics. KD0,actuatorhalfscale[-1024,1023].
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/test_current_pi.py.
current_pi_20261020T210408205055Z PASS1024exactstate records with actual RTL
output-fed firstorderplant i+=(u-2*i+disturbance)>>4;independent Pythonoracle.
Step/disturbance/reversal/recovery/restart settledwindow errors0counts
(required<=3),23antiwindupsamples,integratorfreeze,randomsinkstalls,
both error-clipping endpoints. Normalized surrogate,no physicalmotorunits.
Not yet phaseFOC/inversePark/SVPWM/PWM/protection coupling orspeed/position.
No synthesis/resource measurement or boarddownload. IP08bothbuildsterminal,
IP06placement stillOPEN;no unpolled livebuilds. FullIP00..10goalACTIVE.

### IP09 inverse Park and actual space-vector duty generation (2026-10-21)
Previous goal turn progressed actual dq PI numericalplant. This turn adds
motor_foc_25k/rtl/svpwm_duty.v,rtl/voltage_modulator.v,
tb/tb_voltage_modulator.v,tools/test_modulator.py;SPEC updated.
Uses unchanged canonical inversePark then new min/max common-mode SVPWM
duty generation (not treating sector decoder as complete modulator).
Signedphase projection sqrt3~1774/1024,commonoffset,linear-rangeclipping,
rounded period scaling;invalidperiod error+zeroduties,overmod flag+clippedduties.
Two elasticstages,alignedperiod/ID/rotationflags,II1/stableoutputunderstall.
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/test_modulator.py.
modulator_20261020T210618317919Z PASS1024exact records/all256angles,
invalidperiods/extremes/overmod/II1/stalls. Latest
modulator_20261020T210659856151Z PASS additionally numerical average
line-voltage reconstruction against floatingpoint rotation/inverseClarke
on non-overmodulatedcases;quantisationbound2048/period+4counts.
No synthesis/resource/physical evidence this turn. Still must connect
currenttransform+PI+inversemodulation+atomicPWMcarrier+protection and plant,
speed/position/QEI/CSR/25K/LA/release. No real switching/motorpass claimed.
BothIP08 builds and IP06placement failure remainterminal;goalIP00..10ACTIVE.

### IP09 atomic three-phase carrier plus real protection (2026-10-21)
Previous goal turn progressed inversePark/common-mode modulation. This turn
adds motor_foc_25k/rtl/pwm3_atomic.v,tb/tb_pwm3_atomic.v,
tools/test_atomic_pwm.py;SPEC updated. Onecompletecommand pending slot;
period,duties,deadtime,ID applytogether only idle/carrierboundary.
Uses actual pwm3_protection;invalid commands reject/count/latchshutdown,
retainactiveconfig,require explicitdisabledclear. Endpointduty0/period valid.
Canonical pwm_gen unchanged; separate writes cannot supply requiredatomicity,
so carrier is new narrowRTL,not silentcanonicalreplacement.
Initial direct atomic_pwm_20261020T2108439435748Z PASS.
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/test_atomic_pwm.py.
atomic_pwm_20261020T210918791583Z PASS18exact completecarriers/377cycles,
threeparameter sets,period16->20/dead2->3/midcarrierqueue/endpointduties,
invalidcommand/fault/recovery;Pythoncountsrawduties andchecksboundaryownership.
No synthesis/resource/physicalclaim. Next connect actualmodulatoroutput to
carrier and full phasecurrent/PI/plant withfaultownership. OtherIP09modes/QEI/
CSR/25K/LA/release and IP08/IP06placement remainOPEN;fullgoalACTIVE.

### IP09 complete phase-current to applied protected PWM feedback (2026-10-21)
Previous goal turn progressed atomiccarrier/protection. This turn adds
motor_foc_25k/rtl/foc_current_step.v,tb/tb_foc_current_step.v,
tools/test_foc.py;SPEC updated. Serialized owner snapshots allcontext,
chainsactualClarke/Park+dualPI+inversePark/SVPWM+carrier/protection,
returnsheldcompletion only matchingIDactuallyapplied. Diagnostics preserve
PI/range/clippingflags. Fatalpaths tripgates/flusharithmetic includingPIstate.
First foc_20261020T211248003658Z FAIL TBplant signeddivision:unsignedperiod
converted negativevoltagenumerator unsigned. Fixed denominator signedcast;
no golden/RTL arithmetic relaxed. Failure retained.
foc_20261020T211307107498Z PASS512fullstates+plant/faultownership.
Latest foc_20261020T211352684173Z PASS additionally exactdiagnosticwords.
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/test_foc.py.
Actual applied-duties feed normalized stationaryalphabeta firstorderplant;
independentmodel exactphaseADC/Clarke/Park/PI/inverseSVPWMstates.
Settledstep/angle/disturbance/reversal/restart maxerrors0/1/0/0/0counts
(limit5). Testsbroken-shunttrip,externalfaultwhileowned,flush/recovery,
invalidconfig,gate nonoverlap/fault suppression,heldresults.
No switchingloss/physicalmotor claim or synthesis/resource measure.
RemainingIP09outerloops/QEI/watchdog/CSR/replay/host/25K/LA/release;
IP08/IP06resourceclosure and IP10/fullgoal stillOPEN;IP00..10goalACTIVE.

### IP09 synchronized canonical QEI and velocity ownership (2026-10-21)
Previous goal turn progressed complete appliedPWM/phaseplant feedback. This
turn read canonical qei_dec/wdt_win/PID interfaces and adds
motor_foc_25k/rtl/encoder_feedback.v,tb/tb_encoder_feedback.v,
tools/test_encoder.py;SPEC updated. Two-stage rawA/B/index synchronizers,
unchanged canonicalx4 QEI,illegalGraydiagnostics,coherentposition/delta/time/
sequence snapshots. Index reset rebases speed baseline;partialintervals invalid.
Canonicalindexheader overstates droppedstep:actualRTL countscoincidentlegal
step whenindex_reset0,drop/reset onlywhen1;wrapper/testdocumentactualsemantics.
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/test_encoder.py.
encoder_20261020T211626812910Z PASS1000exactcycle records/91snapshots,
independentGray/synchronizer/model,forward/reverse,indexmodes,wrap,
invalidtwo-bitjumps/clear. Velocitycounts/window,notRPM;noedge-rate/MTBFclaim.
No synthesis/resources/physicalmeasurement. Outerloops,encodertrip/watchdog
coupling,CSR/replay/25K/LA/release stillOPEN. No livebuilds restarted.
FullIP00..10goalACTIVE;IP06/IP08placement and other acceptancegates unchanged.

### IP09 actual outer current/speed/position command modes (2026-10-21)
Previous goal turn progressed synchronizedQEI/velocity snapshots. This turn
adds motor_foc_25k/rtl/motor_outer_loop.v,tb/tb_motor_outer_loop.v,
tools/test_outer.py;SPEC updated. Reuses unchanged dsp20kpid_core zeroDSP
with Kp4,Ki1/4,Kd0,integralclamp2047,actuator256. Mode0directq,1speedPI,
2positionP->speedPI;position subtraction33bits,speed/errorbounds,explicit
invalidmode/velocity errors,registeredreset on entering outerPI mode,
heldID/results and actualintegratorrestart echo.
outer_20261020T211858579595Z FAIL initialKi1/8 speedsettled3>2counts.
Preserved;changed actualRTL gainKi1/4 and matchingmodel,thresholds unchanged.
outer_20261020T211916919663Z PASS;latest
outer_20261020T211943537842Z PASS after accurate current-bypass restart echo
and parameter bounds.1024exact fullstate/normalizedmechanicalplant records,
settled errors1/1/6/1/0 vslimits2/2/10/10/2,modechanges,load,reverse,restart,
heldresponses,invalidmode/baseline,extreme signed velocity errorclipping.
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/test_outer.py.
No synthesis/resource/physicalclaim;not yetjointQEI/outer/phaseFOCplant.
Nextmode/sensor/watchdog ownership integration,CSR/replay/25K/LA/release.
IP06/IP08placement and other openIP gates remain;fullIP00..10goalACTIVE.

### IP09 first-fault safety and watchdog recovery (2026-10-21)
Previous goal turn: progress,20K LA mapping physically reconfirmed; does not
satisfy required25K hardware acceptance. Current work verifies motor_safety.v,
tb/tb_motor_safety.v,tools/test_safety.py and updates motor SPEC.
Canonicalwdt_win+actualprotectedPWM simulation fivefault baseline PASS
safety_20261020T212527152781Z; earlier reset-release TB failure retained.
Added single-clock disabled clear outside watchdog monitor beat and fixed
stale watchdog re-latching while clear pending. Rawwatchdog still inhibits
gates until cleared; live external/encoder/control faults remain effective.
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/test_safety.py.
safety_20261020T212621936223Z PASS sixfault episodes,firstcause/time/count,
heartbeat aggregation,timeout/early,gate suppression,clear/recovery.
Pre-fix substitution test artifacts/check_safety_prefix.py proves added
regression FAIL on oldRTL; fixedRTL PASS,log preserved in same evidence dir.
No synthesis/resource measurement or board claim. JointQEI/outer/FOC,
CSR/replay/host,25Kphysical/hardJTAG/release and IP06/IP08 placement remain
open;IP10 and fullIP00..10 objective remain ACTIVE.

### IP09 integrated QEI/outer/FOC/safety ownership (2026-10-21)
Previous goal turn made progress fixing/reproducing pulse-clear recovery.
Added rtl/motor_controller.v,tb/tb_motor_controller.v,tools/test_controller.py;
updated foc_current_step.v to export actual applied_update,its positional TB
and SPEC. One-owned-sample snapshots all context/QEI,serializes outer/FOC,
holds completion,feeds watchdog only carrier applied pulse. Outer errors
terminate without PWM submission and latch control fault;external/encoder/
watchdog inhibit actual carrier. No implicit electricalangle conversion.
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/test_controller.py.
controller_20261020T212840954643Z FAIL TBGraycycle produced-4 vs intended+4;
reversed stimulus direction,canonicalQEI/expected+4 unchanged.
controller_20261020T212857193310Z PASS three modes,QEI coherentposition/delta,
livecommandmutation afteracceptance,heldresults,exactappliedcount,
encoder/outer/control/externalfault shutdown and recovery.
Command:python cores/control/motor_foc/tools/test_foc.py.
foc_20261020T212843443207Z PASS512exact phase/appliedPWMplantstates,
settlederrors0/1/0/0/0. No synthesis/resources/physicalmeasurement.
Still needs jointmechanicalplant numerical acceptance,CSR/replay/host,
25K/hardJTAG/LA/release. IP06/IP08placement,IP10 and otherworkorder gates
remainopen;fullIP00..10goalACTIVE.

### IP09 integrated applied-PWM/electrical/mechanical/QEI plant (2026-10-21)
Previous turn progressed connectedcontrollerprotocol/fault ownership. Added
motor_foc_25k/tb/tb_motor_plant.v,tools/test_plant.py;parameterized outer
SPEED_KI_SHIFT default2 and integratedcontroller default6;updatedSPEC.
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/test_plant.py.
plant_20261020T213043032303Z FAILposition743>10 despite2048exactstates:
Ki1/4 standalonegain unstable with connectedcurrentloop/mechanicallag.
Preserved failure;actualintegratedRTL gainchanged Ki1/64 (Kp4,positiongain
shift3 retained),not thresholds. Standalone default/contract unchanged.
plant_20261020T213232350599Z PASS2048exactstates/fixed1024clockcadence,
actual applied-duty voltage->phasecurrent->mechanicalsurrogate->Grayedges->
QEI->outer->FOC. Settledspeed/load/reverse2/2/2(limit2),position2/reverse7
(limit10),restart0(limit2),2048appliedevents,no supervisorfault/deadlineoverrun.
Independentoracle hasheshelpercode/tables/sources. Average model theta0,
no backEMF/switching/deadtimevoltageloss or physicalmotor claim.
Additionalcommands:python cores/control/motor_foc/tools/test_outer.py;
python cores/control/motor_foc/tools/test_controller.py.
outer_20261020T213247545973Z PASSoriginal1024states;
controller_20261020T213247554189Z PASSthree modes/ownership/faultrecovery.
No synthesis/resources or physicalmeasurement thisturn. CSR/replay/host,
25K/hardJTAG/LA/release,IP06/IP08placement,IP10/othergatesremainopen.
FullIP00..10goalACTIVE;current20K is not25Kacceptance substitute.

### IP09 command/result CSR with explicit protection lifecycle (2026-10-21)
Previous turn progressed2048sample averagedjointplant qualification.
Added motor_foc_25k/rtl/motor_control_csr.v,tb/tb_motor_control_csr.v,
tools/test_csr.py,CONTROL_CSR.md;SPECupdated. Actualcontroller connection,
oneownedcommand,configurationlockedwhilebusy,immutable12wordresult,
explicitACK,hold/releaseclear/enable/disable,buildID/serial/time/livefault.
Extra capturecycle ensures newcontrollertrip reaches firstcause register.
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/test_csr.py.
csr_20261020T213515962508Z PASSinitial3numericalsnapshots;
csr_20261020T213541429585Z PASS additionally fourthinvalidmode terminal
error+firstcause5/noPWMsubmission.36goldenfields,heldCSRresponses,
busy/invalid/partial/unaligned/emptyaccessrejections,laterexternalfault
withoutalteringresult,explicitclear/recovery. No synthesis/resources/board.
Next finitehardware replay/host and25Ksynthesis;hardJTAGphysical,LA,
release/IP06-IP08placement/IP10/otherworkordergatesstillopen.
FullIP00..10goalACTIVE;current20Knot25Kacceptance substitute.

### IP09 transport-neutral host capture and error ownership (2026-10-21)
Previous turn progressed actual motorCSR/numericalsnapshot/faultlifecycle.
Added motor_foc_25k/tools/motor_host.py,tools/test_host.py,HOST.md;SPECupdated.
Canonical15wordcommands,strictsigned/rangeencoding,exactidentity/build,
boundedpolling,ID/serial/time/stablesnapshot/error/fault/duty validation,
incrementalsave,explicitACKonlyafterSAVED;defaultretainsresult,noimplicit
clear/enable/retry. Recorder persistence is caller contract,not simulateddisk
success claimed as physicalhost capture.
Command:python cores/control/motor_foc/tools/test_host.py.
host_20261020T213735240194Z PASSinitial18guards;
host_20261020T213751245977Z PASS3actualRTL numericalfixtures/36words,
19negativeguards,exactconfigurationmapping,save-beforeACK/defaultnoACK.
Fixture sourcehashes validated against current authoritativeCSR PASSinputs;
bus/build/serial/timestamp lifecycle in hosttest synthetic,explicit inreport.
No synthesis/resource/physicalmeasurement. Finitehardware replay,physical
hostadapter,25K/hardJTAG/LA/release and otherIPacceptancegates remainopen.
FullIP00..10goalACTIVE;this is progress towardhostdeliverable,notfullclosure.

### IP09 first GW5A core synthesis and async capture repair (2026-10-21)
Previous turn progressedhostcapture/19negativeguards. Addedtools/synth_core.py
with frozeninputs/tables/hashes,no simulationDSPmodel,noIOpads;PPA_25K.csv.
Actualsynthesis exposed PWM/supervisor multi-async-event inference failure.
Changedpwm3_protection.v toone combinedasyncfault/reset assertion;
motor_safety.v toone externalasyncset with synchronoussystemreset clear.
Rawfault wins/directly inhibitsgates;SPECdocumentsreset semantics.
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/synth_core.py.
synth_20261020T213924873254Z FAILmultipleedges;
synth_20261020T213958280835Z FAILpostcheck misclassified$scopeinfometadata;
fixedclassifier,fullfrozenrebuild synth_20261020T214131951101Z PASScheck-assert.
Core5833LUT1..4,1809ALU,2509DFF,14MULT12X12primitives,0BSRAM/PLL/IOB.
No finalDSPpacking/Fmax/route/image/downloadclaim.
Regressioncommands tools/test_safety.py,test_csr.py,test_pwm.py,
test_atomic_pwm.py,test_controller.py,test_host.py allPASS:
safety_20261020T213957256532Z,csr_20261020T213959144452Z,
pwm_protection_20261020T214020945531Z,atomic_pwm_20261020T214022856141Z,
controller_20261020T214023711832Z,host_20261020T214024605885Z.
Hostfixture repinned to newlyqualifiedsource-hashedCSRrun;HOSTupdated.
Finitehardware replay/boardwrapper/physicaladapter/25KhardJTAG/LA/release,
IP06/IP08placement andIP10/otherworkordergates remainopen. No livebuild now.
FullIP00..10goalACTIVE;20Khardwaredoesnotreplace25Kacceptance.

### IP09 first routed/packed25K digital image and UART binding (2026-10-21)
Previous turn progressed actualcore synthesis/async protection repair.
Addedexamples/25k/motor_top.v,motor.cst,tb/tb_motor_uart.v,
tools/test_uart.py,build_board.py,run_uart.py,INTEGRATION.md;
extendedmotor_host.py withfrozen/currentbuild/imageverification;PPA/SPECupdated.
Command:. ./scripts/env.ps1;python cores/control/motor_foc/tools/test_uart.py.
uart_20261020T214527771634Z PASS3bitserialcommands/36exactnumericalfields,
identity/buildID,owned-write/emptyreaderrors,ACK. UARTactualcanonicalmodules;
BIT_CYCLES8 simulation,notphysical115200evidence.8probe outputsregistered1clk.
Command:python cores/control/motor_foc/tools/build_board.py.
board_20261020T214445572169Z PASSsynthesis/route/pack,50MHzconstraint,
Fmax79.038887MHz,final7328LUT4/1850ALU/2563DFF/14MULT12X12/
0BSRAM/PLL/11IOB. BuildIDb04803d710238e94,imageSHA
1aaea87d72169756603a2b4c14cee9f5931ac13f5cf53421988563675f59f728.
validate_build PASScurrent/frozenhashes/fingerprint/suppliedimageSHA,
host_build_validation.json saved.No loadedSRAMhashclaim,neverdownloaded.
Commands:run_uart.py --help;test_host.py PASS
host_20261020T214623234783Z (3fixturecases/19negativeguards).
run_uartdisabled-onlydiagnostic,durablecapturebeforeoptionalACK,noautoenable.
Digitalbinding tiesrawQEI0/faultinactive;full-clockreplay/externalQEI/fault,
physicalUART/hardJTAG/25K/LA/license/release remainopen. Current20Kcannot
receive25Kimage. OtherIP06/IP08placement/IP10andfullworkordergatesunchanged.
No livebuild sessions remain;fullIP00..10goalACTIVE.

### Repository checkpoint / replay owner WIP (2026-10-21)
User requested a Git commit/push checkpoint. motor_replay_owner.v has been
started for fixed-cadence finite ownership,deadline/starvation/abort handling.
It is NOT integrated,regression-qualified,synthesized or accepted. It does not
replace the missing preloaded descriptor store/result buffer/replay top.
Previous board build does not include this new owner. Full goal remains ACTIVE.
Generated artifacts/toolchains/captures stay local under .gitignore; selected
small fixture evidence may be explicitly retained for offline host tests.
