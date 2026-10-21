# Current validation boundaries

- BLC: blc_20261020T165939975888Z,RAW8/10/12 each384078pixels,independent raw
  correction/metadata/clip counts; isolated128pixel II1 and stalled reset PASS.
- BLC isolated synthesis: blc_synth_20261021T010610071,RAW10,120LUT1..4,
  99ALU,202FF,20MUX2_LUT5,zero DSP/BSRAM,no P&R/Fmax.
- RAW/BLC/Bayer: frontend_20261020T170452403607Z,RAW8/10/12 each380685RGB
  pixels,independent full-size bilinear golden PASS.
- Separate color: color_20261020T171340367961Z,384173pixels exact integer
  gain/matrix/LUT oracle and isolatedII1 PASS. That source revision predates
  addition of the passive drained output; combined tests below cover current
  color data/config/metadata behavior without claiming new isolatedII evidence.
- Combined RAW/BLC/Bayer/AWB/CCM/Gamma: isp_20261020T171830899126Z,
  RAW8/10/12 each380685final RGB pixels and all frame markers/IDs PASS.
- Fatal drain/recovery: recovery_20261020T172223864482Z,PASS malformedEOL,
  downstream blocked after initial output,held output cannot be revoked,error
  response waits for metadata drain,then reset/reconfigure and clean5x5 frame;
  all18output RGB values/IDs/markers checked.

Exact commands (source scripts/env.ps1 first):

```powershell
python cores/image_processing/isp_stream/tools/test_blc.py
python cores/image_processing/isp_stream/tools/test_frontend.py
python cores/image_processing/isp_stream/tools/test_color_chain.py
python cores/image_processing/isp_stream/tools/test_isp.py
python cores/image_processing/isp_stream/tools/test_isp_recovery.py
```

Evidence paths are under artifacts/isp_stream_25k. Each runner records complete
source hashes,compiler/run logs and immutable raw output where applicable.
Pixel equality is exact for the specified integer formulas,not a perceptual
error metric or a claim of equivalence to an external camera ISP.

Combined-core synthesis started core_synth_20261021T012235399 in execsession88077;
consult current log/terminal result. No P&R/physical core qualification yet.
The work-order Sobel/statistics integration,bypass/config coverage for the final
chain,realtime30fps virtual source,CSR/LA and25K physical acceptance remain OPEN.

Combined RAW10/MAX_WIDTH640 synthesis completed PASS:
core_synth_20261021T012235399,synth_gowin -family gw5a -noiopads.
5246LUT1..4(57/480/2284/2425),1057ALU,188MUX2_LUT5,2391FF,
6SDPX9B+2SPX9 synthesis memory cells,zeroDSP. The463portsbits are internal
interfaces(no I/O buffers requested),not a physical pin top. No RAM16SDP4
cells in this netlist. This is not physical BSRAM accounting,Fmax or board
acceptance. Previous pending-synthesis note is superseded by this completion.

Statistics integration completion:
- `statistics_20261020T173108154399Z`: standalone widths48/8 PASS384016pixels
  each; independent sums/counts/tags, snapshot stalls and saturation.
- `isp_statistics_20261020T173832627433Z`: RAW8/10/12 PASS380685pixels each,
  seven exact snapshots each, including full320x240/640x480 source frames.
- `stats_recovery_20261020T174054518375Z`: PASS18pixels, malformed statistics
  suppressed, clean statistics checked, snapshot held30cycles after response,
  next command blocked until statistics handshake.
Commands: `test_statistics.py`, `test_isp_statistics.py`,
`test_isp_stats_recovery.py` in tools/. See STATISTICS.md for completion/error
semantics. These supersede the earlier pending statistics integration note;
Sobel,all-stage bypass,realtime30fps,CSR/probes,P&R and25K acceptance stay OPEN.

Standalone grayscale Sobel wrapper: `sobel_20261020T174452907145Z` PASS380669
pixels, four source sizes including320x240/640x480, independent full-image
convolution/metadata golden, center bypass, frame-latched configuration,
invalid dimension recovery and randomized backpressure. Command:
`python cores/image_processing/isp_stream/tools/test_sobel.py`. See SOBEL.md. This does
not close full RAW-to-Sobel integration or sustained/physical acceptance.

RAW-to-Sobel integration now implemented: see SOBEL_PIPELINE.md.
`isp_sobel_20261020T174734732567Z` terminalPASS RAW8/10/12 each377317 final
pixels/seven RGB snapshots. Subsequently corrected LUT ready during a held
top-level dimension rejection; directed current-source test
`sobel_recovery_20261020T175202234373Z` PASS covers this gate plus incomplete
Gamma rejection,fatal/successful output drain and snapshot hold/recovery.
Current full rerun `isp_sobel_20261020T175240510760Z` session94931 terminalPASS
RAW8/10/12 each377317pixels/seven snapshots. `sobel_20261020T175204225742Z` PASS380669 standalone pixels
after passive drained output addition. No sustained30fps or25K claim.

Virtual RAW source: `virtual_source_20261020T175554791992Z` PASS RAW8/10/12,
all raster samples/markers, frame config latch/restart, held pixels, invalid
configuration, exact command cadence at period200 and1666667, command/pixel
stalls and seven intentional frame deadline misses. Includes three320x240
and two640x480 frames per width. Command `test_virtual_raw_source.py`.
Source-only cadence does not prove ISP throughput. Full actual-source/ISP
test `test_realtime.py`: `realtime_20261020T175818964103Z` terminalPASS,
session13698 completed. Actual RAW10 source->ISP/Sobel at50MHzsimulation,
three320x240/two640x480frames,exact1666667clockcadence,zero deadline misses,
829200finalpixels/five RGBsnapshots match independentPython. Physical25K and
routed50MHz remainOPEN. See VIRTUAL_SOURCE.md.

Atomic ISP configuration CSR: `config_20261020T180222223057Z` PASS,
canonical sys_atomic_config reused unchanged,16word shadow/active readback,
safe deferred/immediate whole-config apply,held CSR/config responses,
exactly-once commits and invalid accesses. `python cores/image_processing/isp_stream/tools/test_config.py`.
See CONFIG_REGISTERS.md;source/ISP control integration and metric/probe CSR
remainOPEN. No synthesis/resource claim for the new adapter.

Runtime integration `test_control.py`:
`control_20261020T180930042929Z` PASS CSR/source/fullISP,27exact outputs,
host-Python CRC and RGB-statistics golden,heldCSR/output,live-traffic snapshot
retention,all4registered probe pages,early Gamma error,768LUT writes and restart.
The early-error source deadlock from the first integration test was fixed;
failure evidence retained. Current source-only regression
`virtual_source_20261020T180856909397Z` PASS RAW8/10/12 and actual-chain
`realtime_20261020T180857788673Z` terminalPASS same829200pixels/30fpssimulation.
`test_uart.py`: `uart_20261020T181126001154Z` PASS actual bit-serial UART
configuration/run/CRC/snapshot/page controls on the new11-pin board top.
See CONTROL.md. Board build `board_20261020T181007022100Z` session73270 still
live in synthesis;no physical PPA/download/25K claim pending terminal result.

Host implementation `isp_host.py`/`run_uart.py` and simulation-derived fixtures:
`host_20261020T181920534896Z` PASS reused UART codec/fragmentation/CRC/status,
config staging,identityLUT,preset golden values,snapshot coherence,corruption
rejection and mode/CRC/RGB accounting. `test_host.py` uses synthetic transport;
physical_measurement=false. `run_uart.py --help` verified. See HOST.md for
supported preset,build hash checks and limits. No physical UART invocation.

Remaining bypass local components: `bayer_modes_20261020T182321831886Z`
PASS RAW8/10/12 each380739pixels,normal four patterns/cropped-center bypass,
320/640frames and error recovery. `bayer_latency_20261020T182450903497Z`
PASS80pixels parallel normal/bypass cycle-equivalent handshakes/markers.
`mode_color_20261020T182613732556Z` PASS64pixels allAWB/CCMidentity modes through
actual canonical color stages with independent golden. See BYPASS_COMPONENTS.md.
These modules are not yet integrated into CSR/fullchain/currentboard image;
flags3/6/7 remain rejected by existing ISP config. No new PPA/physical claim.

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

Terminal follow-up:ISP71786 route/packPASS,board_20261020T184939354706Z:
96.721153MHz vs50MHz constraint,16762LUT4,2636ALU,7261DFF,16BSRAM,11IOB,
zeroDSP/PLL. Frozeninput+imagehashverified;SHA256
f6a42edd215e9d1e3bc94bedfd0fc4235f9eeed341d778af3292b71c25f7dc57.
Fullbypass/Gammareuse currentRTL image,notdownloaded. LUT4mapping successful;
this does not independently prove why earlier wideLUT placement failed.
CNN8765 terminalFAIL:RAM16SDP4 noBELs (control.engine.biases.0.9).
Preserved artifact. build_board.py now -nolutram to avoidunsupporteddistributed
RAM;no functionalRTLchange. A new frozenbuild started;poll its ownhandle.
