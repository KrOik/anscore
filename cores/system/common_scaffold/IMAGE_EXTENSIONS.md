# Image and signal extension cores

## 2026-10-19 closeout verification

Full 141-project run completed: **141/141 project tests PASS**, **189/190 integration tests initially PASS**, 144 RTL bundle compilation PASS and all 738 inputs unchanged. The sole failed integration was a TLS exit35 while fetching the RAW white-balance reference, before functional comparison. An independent unchanged-command retry passed (4 Bayer patterns, 192 RTL outputs); the original failed run is preserved and is not reclassified as a single-run full PASS.

[Original full results](evidence/image_extensions_20261019T134947Z_5dfb2b1c/results.json), [isolated retry audit](evidence/raw_white_balance_reference_recovery_20261019T152435Z/recovery_audit.json), [storage/RAW resource audit](evidence/image_extensions_20261019T134947Z_5dfb2b1c/resource_audit.json), [board closeout](board/tang25k/extension_acceptance/CLOSEOUT_REPORT.md). Latest previously sealed checkpoint remains the 137-project incremental checkpoint below. MPU6050 and unfinished indexed BMP are excluded from delivery. JPEG board acceptance remains pending; five newly completed peripheral cores have internal-pin-fixture board evidence, with limitations documented in the closeout report.

Latest verified **incremental checkpoint: 137 projects, 177 integrations, 139 RTL sources, 710 frozen inputs**.

Three new project cases and seven new suites passed against the unchanged
134-project / 170-suite audited baseline. The integrated source bundle compiled;
input stability and three-layer provenance audits passed. All 202 production
source hashes remain unchanged. This is offline verification, not a fresh full
137-project regression or board acceptance.

| New core | Implemented capability | Isolated LUT-class / DSP / BRAM9 |
|---|---|---:|
| [RAW14 pack](image/raw14_codec/README.md) | V4L2 4-pixel/7-byte packing, frame markers and explicit resynchronization | 160 / 0 / 0 |
| [RAW14 unpack](image/raw14_codec/README.md) | Independent byte-to-pixel reconstruction, malformed-line recovery | 150 / 0 / 0 |
| [AXI4 NxM crossbar](stream_bus/axi_multi_crossbar/README.md) | Five channels, 2–4 masters/targets, 32/64-bit, round-robin and full-burst address validation | 1404 default, 5957 max / 0 / 0 |

RAW14 has one legal fixed-format configuration per module; no duplicate
synthesis profiles are counted. Independent bit-basis tests and exhaustive
pixel-value tests cover both directions. AXI peer tests include all five
channels, independent byte-address oracle, parallel targets and strict fairness.
AXI exclusive accesses explicitly return DECERR. Bare maximum AXI ports exceed
board I/O capacity: integrate internally behind a wrapper. Resource numbers
are isolated, not a combined fit or timing/board claim. Full independent AXI
synthesis/check logs are retained with this checkpoint.

[Results](evidence/image_extensions_incremental_20261019T131634Z_76839378/results.json),
[provenance](evidence/image_extensions_incremental_20261019T131634Z_76839378/ancestry_check.json),
[resources](evidence/image_extensions_incremental_20261019T131634Z_76839378/resource_audit.json),
[final seal](evidence/image_extensions_incremental_20261019T131634Z_76839378/final_readonly_check.json).
This batch has no temporary binary/cache leftovers; baseline134 retains its
two explicitly inventoried policy-blocked cleanup exceptions.

## Earlier 134-project checkpoint

Latest verified **incremental checkpoint: 134 projects, 170 integrations, 136 RTL sources, 694 frozen inputs**.

Seven new project cases and 24 new suites passed, with the unchanged audited
127-project / 146-suite full regression reused. The new source bundle compiled;
independent provenance, source freeze and resource audits passed. All 202
production source hashes remain unchanged. This is not a fresh 134-project
full run or a new board acceptance.

| New core | Implemented capability | Default isolated LUT-class / DSP / BRAM9 |
|---|---|---:|
| [TDM RX](peripherals/tdm_audio/README.md) | Native BCLK, configurable slots, complete-frame FIFO, framing/overflow accounting | 532 / 0 / 0 |
| [TDM TX](peripherals/tdm_audio/README.md) | Complete-frame serial transmission, DSP-A/B timing, whole-frame underrun zeros | 805 / 0 / 0 |
| [Pulse measurement](peripherals/pulse_measurement/README.md) | Filtered pin high/low/period capture, range/timeout/overflow and stable events | 878 / 0 / 0 |
| [OneWire ROM search](peripherals/onewire_rom_search/README.md) | Real open-drain Search ROM enumeration, 64-bit discrepancy tree and Dallas CRC8 | 754 / 0 / 0 |
| [Frequency counter](peripherals/frequency_counter/README.md) | Continuous reference-clock gates, qualified edges, overflow/range/drop accounting | 738 / 0 / 0 |
| [DS18B20 temperature](peripherals/ds18b20_temperature/README.md) | External-powered Match/Skip ROM conversion, polling, 9-byte scratchpad, signed temperature/CRC | 632 / 0 / 0 |
| [Frame-rate converter](image/video_frame_rate_converter/README.md) | Three synchronous frame banks, rational output cadence, complete-frame repeats/drops | 969 / 0 / 10 |

The 24 isolated synthesis profiles remain within 15K LUT-class, 4 DSP and
46 BRAM9 each; this does not imply all IPs fit together. FRC maximum legal
frame configurations use 36 BRAM9; full-resolution DDR storage and video PHYs
are outside these modules. Digital pin tests are not electrical/CDC MTBF signoff.

[Results](evidence/image_extensions_incremental_20261019T125108Z_21c72ffd/results.json),
[audit](evidence/image_extensions_incremental_20261019T125108Z_21c72ffd/checkpoint_audit.json),
[provenance](evidence/image_extensions_incremental_20261019T125108Z_21c72ffd/ancestry_check.json),
[resource/peer/cleanup seal](evidence/image_extensions_incremental_20261019T125108Z_21c72ffd/final_readonly_check.json).
The cleanup seal records policy-blocked products explicitly: the inherited
44,509-byte temporary directory and a 13,125-byte DS18B20 Python cache.
Large task temporary simulations and synthesis products were removed.

## Previous full checkpoint (retained history)

Latest verified **full regression**: **127 projects, 146 integrations, 129 RTL sources, 645 frozen inputs**.

All project cases, integration suites and the combined source compilation passed.
The independent checkpoint and provenance audits passed; all 202 production
source hashes are unchanged. [Full results](evidence/image_extensions_20261019T114945Z_47a81c66/results.json),
[checkpoint audit](evidence/image_extensions_20261019T114945Z_47a81c66/checkpoint_audit.json),
[provenance audit](evidence/image_extensions_20261019T114945Z_47a81c66/ancestry_check.json).

This run closes the existing DVP RX ring repair: logical FIFO capacity N now
uses N+1 physical entries so simultaneous pop/push never depends on same-address
RAM read/write semantics. Actual wraparound tests cover depths 2/3/7/1024/4096.
Default isolated resources are 587 LUT-class / 0 DSP / 6 BRAM9; depth 4096 uses
879 / 0 / 14. This repairs an existing core and does not add a project.

[Repair/resource/peer seal](evidence/image_extensions_20261019T114945Z_47a81c66/final_readonly_check.json)
is offline only: no new board, electrical, combined-device-fit or timing signoff.
A previously blocked 44,509-byte temporary directory remains explicitly recorded
as a cleanup exception; baseline artifacts and logs are preserved.

## Previous incremental checkpoint (retained history)

Latest verified incremental checkpoint: **127 projects, 145 integrations, 129 RTL sources, 644 frozen inputs**.

Four new cores and eleven new suites passed; the unchanged audited 123-project
closure was reused. This is not a fresh full-library or board run.

| New core | Implemented behavior | Default isolated LUT-class / DSP / BRAM9 |
|---|---|---:|
| [TMDS encoder](image/tmds_codec/README.md) | DVI video/control lane, running disparity and elastic output | 119 / 0 / 0 |
| [TMDS decoder](image/tmds_codec/README.md) | Strict symbol/disparity validation, explicit error and control-based resynchronization | 127 / 0 / 0 |
| [PS/2 host](peripherals/ps2_host/README.md) | Filtered open-collector bidirectional host, RX FIFO, TX handshake, timeouts and explicit errors | 817 / 0 / 0 |
| [LCD8080 engine](peripherals/lcd8080/README.md) | 8/16-bit command/data reads/writes, fixed physical bus phases, turnaround, burst, abort and timeout | 426 / 0 / 0 |

TMDS coverage includes all 256 bytes x 9 reachable disparity states, all 1024
symbols x 9 contexts, three-lane RGB round trips, and 30656 bit-exact outputs
against actual pinned ProjectF RTL fetched and compiled for the comparison.
The root timing-generator -> three TMDS lanes -> RGB/sync test checks a complete
VGA frame and a small raster with independent Python symbols and exact pipeline cadence.
PS/2 checks 268 received and 264 transmitted bytes, 46 protocol cases and numeric
limits; peer review reproduced and resolved lost device replies while TX DONE
was held and missing stop-bit contention detection. LCD checks both bus widths,
DCS window commands and 48 RGB565 pixels per profile, maximum timing counters,
and preserves exposed read responses through abort/timeout until host acceptance.

The DVP RX N+1 physical-ring repair is staged separately with five depths and
20632 exact pixels tested on temporary copies. It is not yet integrated and is
not counted as a new core; the original RX risk remains open until integration
and the required full regression. Prior 44509-byte policy-blocked C: cleanup
exception remains recorded; no new temporary binaries remain from this batch.
No serializer, PHY, routed timing or new board acceptance is claimed.

- [Results](evidence/image_extensions_incremental_20261019T114200Z_af7946ee/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T114200Z_af7946ee/checkpoint_audit.json)
- [Ancestry audit](evidence/image_extensions_incremental_20261019T114200Z_af7946ee/ancestry_check.json)
- [Resource audit](evidence/image_extensions_incremental_20261019T114200Z_af7946ee/resource_audit.json)
- [Final check with inherited cleanup exception](evidence/image_extensions_incremental_20261019T114200Z_af7946ee/final_readonly_check.json)

Previous checkpoint retained below:

Latest verified incremental checkpoint: **123 projects, 134 integrations, 125 RTL sources, 618 frozen inputs**.

Four new cores and thirteen new suites passed. Only unchanged audited tests were reused; this is not a fresh full-library or board run.

| New core | Behavior | Default isolated LUT-class / DSP / BRAM9 |
|---|---|---:|
| [Multi-master AXI-Lite crossbar](stream_bus/axil_multi_crossbar/README.md) | Per-target read/write round-robin, split AW/W capture, response ownership and DECERR | 805 / 0 / 0 |
| [Runtime video timing](image/video_scanout/README.md) | Captured porches/polarity and physical tick independent of host CE | 666 / 0 / 0 |
| [RGB scanout](image/video_scanout/README.md) | Synchronous FIFO prefill, fixed timing, explicit faults and frame-boundary stop | 1163 / 0 / 2 |
| [DVP TX](image/dvp_tx/README.md) | Gray8/RGB888-to-RGB565, endian/polarity and fixed byte tick | 1602 / 0 / 4 |

Checks cover 1440 concurrent crossbar transactions and exact round-robin fairness;
complete VGA/720p/1080p timing; actual FIFO-to-raster pixels; and DVP TX -> RX ->
AXI Video -> pixels with independent quantization oracle (24 frames, 15576 pixels).
Peer review resolved TX full-ring BRAM same-address access and scanout last-tick
fault extra-frame behavior, with ten dedicated fault-boundary checks.

Known follow-up: previous DVP RX full-ring simultaneous same-address read/write
still lacks primitive collision proof. Its physical-depth-plus-one repair is planned
and isolated-synthesized, not implemented or functionally validated. Existing RX
RTL simulation is not proof of that hardware property.
A 44,509-byte C: timing-test directory remains because automatic policy rejected
its precise cleanup. No new board, PHY, routed timing or image-quality claim.

- [Results](evidence/image_extensions_incremental_20261019T112535Z_ee01cda3/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T112535Z_ee01cda3/checkpoint_audit.json)
- [Ancestry audit](evidence/image_extensions_incremental_20261019T112535Z_ee01cda3/ancestry_check.json)
- [Resource audit](evidence/image_extensions_incremental_20261019T112535Z_ee01cda3/resource_audit.json)
- [Final check with cleanup exception](evidence/image_extensions_incremental_20261019T112535Z_ee01cda3/final_readonly_check.json)

Previous checkpoint retained below:

Latest completed checkpoint: **119 projects, 121 integrations, 121 RTL sources**,
**591 frozen inputs**. Four new video I/O cores and ten additional protocol,
boundary, throughput and real-chain suites pass.

- [Results](evidence/image_extensions_incremental_20261019T105514Z_e8ec8fdd/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T105514Z_e8ec8fdd/checkpoint_audit.json)
- [Ancestry audit](evidence/image_extensions_incremental_20261019T105514Z_e8ec8fdd/ancestry_check.json)
- [Resource audit](evidence/image_extensions_incremental_20261019T105514Z_e8ec8fdd/resource_audit.json)
- [Final source/report/cleanup check](evidence/image_extensions_incremental_20261019T105514Z_e8ec8fdd/final_readonly_check.json)

| New core | Implemented behavior | Default isolated LUT-class / DSP / BRAM9 |
|---|---|---:|
| [BT.656 TX](image/bt656_tx/README.md) | Complete SAV/active UYVY/EAV/blanking byte records, protected XY codes, configurable field and active-line windows | 914 / 0 / 0 |
| [Pixel stream to AXI Video](image/axi_video_bridge/README.md) | Pixel SOF/EOL/LAST to AXI TUSER/TLAST, elastic output, physical AXI handshakes remain active at CE=0 | 226 / 0 / 0 |
| [AXI Video to pixel stream](image/axi_video_bridge/README.md) | Two-stage elastic input, configured geometry and LAST reconstruction, no extra beat accepted after final pixel | 221 / 0 / 0 |
| [DVP camera RX](image/dvp_rx/README.md) | Gray8 and RGB565 byte capture, both byte orders/polarities, frame lock, synchronous FIFO, explicit malformed frame and overflow errors | 564 / 0 / 4 |

BT.656 independent byte oracles check full 625x1728 and 525x1716 records as
well as maximum width, field-line count and line-byte boundaries. F/V positions
are programmable; these tests do not certify normative broadcast timing tables.
The transmitter is an elastic byte formatter, without a fixed-rate physical PHY.
Real TX -> RX -> UYVY unpacker integration checks 21,064 complete record bytes,
11,624 active bytes and 2,906 canonical macros over three geometries.

The AXI bridges sustain one pixel per clock under CE=1 with no downstream stalls;
a 4,096-pixel test asserts consecutive handshakes. Main bridge tests cover 20
frames / 25,488 pixels, DATA_WIDTH 1/8/24/32/64 and a 4096-wide geometry.
AXI VALID/READY is checked on every physical clock, including CE=0. Abort drains
already exposed output tokens instead of retracting them.

DVP sensor sampling is never CE-gated and has no backpressure. Its finite FIFO
can overflow if the consumer cannot sustain the input rate. On error it discards
unexposed buffered pixels but preserves an exposed stalled pixel until consumption,
then asserts DONE; the first error remains latched. Reset can cancel all state.
Output pixels are provisional until a successful frame completion.
DVP tests cover 771,072 main pixels including QVGA/VGA continuous input, all
65,536 RGB565 values in both byte orders, 139,614 numerical-test pixels, eight
invalid profiles, 26 protocol reports and 16 healthy recovery frames. A wrapped
full-FIFO simultaneous read/write case checks old-data preservation.
Real DVP -> AXI Video -> pixel integration checks 24 frames / 15,576 pixels,
including continuous one-byte-per-clock input and CE/backpressure scenarios.

All eight isolated synthesis profiles fit the stated budgets. This is a
**verified incremental offline checkpoint**: four new cases and ten new suites
ran fresh; unchanged earlier closures are reused after hash/ancestry audit.
It is not a fresh full 119-project regression, combined-device fit, routed timing,
CDC/electrical validation or new board acceptance. The original acceptance48
board records remain separate. Temporary binaries and generated wave files are
cleaned; existing baseline artifacts and small audit logs are retained.

Previous completed checkpoint: **115 projects, 111 integrations, 117 RTL sources**,
**568 frozen inputs**. TIFF encoder, TIFF decoder and CSI-2 packet transmitter
are implemented, registered and pass their independent regressions and eight
additional special/integration suites.

- [Results](evidence/image_extensions_incremental_20261019T102856Z_94d43a1b/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T102856Z_94d43a1b/checkpoint_audit.json)
- [Ancestry audit](evidence/image_extensions_incremental_20261019T102856Z_94d43a1b/ancestry_check.json)
- [Resource audit](evidence/image_extensions_incremental_20261019T102856Z_94d43a1b/resource_audit.json)
- [Final source/report/cleanup check](evidence/image_extensions_incremental_20261019T102856Z_94d43a1b/final_readonly_check.json)

| New core | Implemented behavior | Default isolated LUT-class / DSP / BRAM9 |
|---|---|---:|
| [TIFF encoder](image/tiff_encoder/README.md) | Baseline uncompressed TIFF6 gray8, gray16 and RGB8; II/MM byte order; real IFD and multiple strips | 1476 / 0 / 0 |
| [TIFF decoder](image/tiff_decoder/README.md) | Buffered synchronous file RAM; actual IFD and SHORT/LONG strip-array parsing; both byte orders and three modes; WhiteIsZero; explicit malformed/unsupported-file errors | 5301 / 0 / 4 |
| [CSI-2 packet TX](image/csi2_packet_tx/README.md) | Four VC, supported legacy short and long packets, header ECC, reflected CRC16, word counts 0 through 65535; captured command and explicit errors | 256 / 0 / 0 |

Real TIFF encoder-to-decoder integration checks 24 frames / 13,656 pixels across
four geometries, three modes and both byte orders. Actual generated files are
also independently decoded by Pillow and tifffile. Real CSI-2 TX-to-RX integration
checks 36 packets / 5484 wire bytes / 5324 payload bytes in one session across
four virtual channels, with independent ECC/CRC, metadata and payload oracles.
Protocol suites cover CE, backpressure, reset/abort and error recovery. The TIFF
decoder requires a bounded complete file buffer; unsupported formats are rejected.
Outputs are provisional until successful completion; errors require discarding
the file or packet. CSI-2 implements the byte packet layer, without a D-PHY.

This is a **verified incremental offline checkpoint**. The new tests ran fresh;
unchanged earlier results are reused only after closure/hash and ancestry checks.
It is not a fresh full 115-project run, combined-device fit, routed timing result
or board acceptance of these three new cores. The separate acceptance48 board
results do not cover the new extension cores. All five isolated synthesis profiles
fit the stated resource limits. Temporary binaries and generated image files are
cleaned automatically; retained small logs and JSON records provide evidence.

Previous completed checkpoint: **112 projects, 103 integrations, 114 RTL sources**,
**549 frozen inputs**. Four new video transport/format cores and five additional
special/integration suites pass.

- [Results](evidence/image_extensions_incremental_20261019T100532Z_81593ba5/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T100532Z_81593ba5/checkpoint_audit.json)
- [Ancestry audit](evidence/image_extensions_incremental_20261019T100532Z_81593ba5/ancestry_check.json)
- [Resource audit](evidence/image_extensions_incremental_20261019T100532Z_81593ba5/resource_audit.json)
- [Final source/report/cleanup check](evidence/image_extensions_incremental_20261019T100532Z_81593ba5/final_readonly_check.json)

| New core | Implemented behavior | Default isolated LUT-class / DSP / BRAM9 |
|---|---|---:|
| [2D AXI4 DMA](memory/video_dma_2d/README.md) | Both stream-to-memory and memory-to-stream, per-row stride, partial byte tails, bounded INCR bursts and 4KB split, response errors and committed-transaction abort drain | 3823 / 0 / 0 |
| [BT.656 receiver](image/bt656_rx/README.md) | SAV/EAV strict XY protection, active UYVY extraction and field0-then-field1 raster markers | 385 / 0 / 0 |
| [YUV422 byte packer](image/yuv422_bytes/README.md) | Canonical {Y0,Y1,Cb,Cr} to YUYV/UYVY/YVYU/VYUY with frame/line markers | 262 / 0 / 0 |
| [YUV422 byte unpacker](image/yuv422_bytes/README.md) | All four byte layouts to canonical macros, config capture and marker/error checking | 348 / 0 / 0 |

DMA main tests run MAX_BURST1/16/256, each 33 commands/2185 healthy read
beats, plus two invalid static profiles. Independent byte RAM checks include
stride holes, partial WSTRB, 4097-byte rows across 4KB boundaries, response errors,
abort and subsequent recovery. Separate bad EOL/LAST and incorrect RLAST cases
have immediate healthy recovery; RLAST-fault peers still return all promised
beats. A peer that stops responding may require external reset. DMA AXI and
exposed read-output handshakes remain clock-active at CE=0; CE only throttles
command/write-input issue. The integration explicitly bridges this to the
CE-qualified byte codecs. bytes_done is progress, not a commit guarantee.

BT.656 passes 34 cases including complete 720x576 and 720x480 active output,
625/525 total line counts and 1728/1716-byte lines before final-EAV termination.
The fixtures use synthetic front-loaded blanking, not exact normative V/F
transition line numbers. Protocol tests include sixteen abort positions and
twenty-one healthy recoveries. There is no physical clock/CDC, arbitrary field
phase acquisition, deinterlacing or broadcast-timing certification claim.

YUV byte codecs each freshly execute sixteen cases/thirty-two frames; shared
protocol and twelve invalid-profile checks pass. They implement byte layout,
not chroma resampling or color conversion. Default16x12 and1920x1080 isolated
synthesis profiles pass; functional geometries include720x4 and1920x2, not a
claim of a full1080p-frame simulation or real-time throughput.

The real 2D-DMA write/read -> byte-packer -> byte-unpacker chain passes three
geometries/four layouts, twelve frames/184 canonical macros. All three 64KiB
RAM images are checked against independent Python byte arrays, including stride
holes; expected AXI address/burst counts and page constraints are asserted.
The real BT.656 -> UYVY unpacker passes three geometries, two fields each,
2906 macros/11624 active bytes, with independent XY table and field/line markers.
Both chains check CE and backpressure; they are positive functional integration,
with error/abort recovery covered separately in the respective core suites.

Eight isolated synthesis profiles are recomputed from actual log cell tables
and source-bound reports. No combined-chain synthesis is claimed. This layer
freshly runs four core and five additional suites. Thirteen ancestry layers
check949 observed files and202 unchanged production files. This is verified
incremental offline evidence, not a fresh full112-core run, extension board,
routed timing, full-resolution throughput or image-quality acceptance. Temporary
compile/dump directories are absent; baseline artifacts and logs are preserved.

## Previous checkpoint (108, verified incremental)

Latest completed checkpoint: **108 projects, 98 integrations, 110 RTL sources**,
**531 frozen inputs**. CSI-2 packet reception and three additional suites pass.

- [Results](evidence/image_extensions_incremental_20261019T095031Z_d452dd07/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T095031Z_d452dd07/checkpoint_audit.json)
- [Ancestry audit](evidence/image_extensions_incremental_20261019T095031Z_d452dd07/ancestry_check.json)
- [Resource audit](evidence/image_extensions_incremental_20261019T095031Z_d452dd07/resource_audit.json)
- [Final source/report check](evidence/image_extensions_incremental_20261019T095031Z_d452dd07/final_readonly_check.json)

[CSI-2 byte packet receiver](image/csi2_packet_rx/README.md) adds the packet
layer missing from the existing RAW10/12 payload unpacker: four legacy VCs,
24-data/6-ECC-bit single-error correction and double-error detection, reserved
ECC-bit checks, short FS/FE/LS/LE and generic short packets, 16-bit word count,
reflected CRC16 and per-VC frame/line sequence checks. It does not implement
D-PHY, lane alignment/deskew, extended VC or physical camera capture. An upstream
adapter must buffer non-backpressure-capable physical traffic. Long payload
is provisional until its successful packet report; errors require discarding
the whole packet, and image consumers may need whole-frame rollback.

The main suite passes 2705 sessions, 2963 packet reports and 26765 payload bytes,
including single/double header errors, CRC corruption, all opaque long DTs,
truncation and four-VC sequence cases. Protocol checks cover twelve abort phases,
thirteen CE-off reset targets and twenty-six healthy recovery sessions. Numeric
checks include a full 65535-byte packet, zero-length/zero-capacity profiles and
invalid parameters. The actual receiver-to-existing-RAW-unpacker chain passes
RAW10 and RAW12, each three frames/33 reports/72 pixels, with independent Python
wire packets, pixel/marker expectations, CE and backpressure. This chain is a
healthy single-VC integration, not error rollback or physical-link validation.

Isolated synthesis is 1077/1059/1084 conservative LUT-class cells at default4096,
maximum65535 and zero WC capacity; all profiles use 0 DSP and 0 BRAM. This layer
freshly runs one core and three additional suites. Twelve ancestry layers check
915 observed files and 202 unchanged production files. These are verified
incremental offline results, not a fresh full 108-core run or extension board,
routed timing, full-resolution video or image-quality acceptance. BMP and PNG
checkpoints remain below; the original 48-entry board acceptance is separate.

## Previous checkpoint (107, verified incremental)

Latest completed checkpoint: **107 projects, 95 integrations, 109 RTL sources**,
**524 frozen inputs**. BMP24 encoder and decoder plus six additional suites pass.

- [Results](evidence/image_extensions_incremental_20261019T094414Z_0a963272/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T094414Z_0a963272/checkpoint_audit.json)
- [Ancestry audit](evidence/image_extensions_incremental_20261019T094414Z_0a963272/ancestry_check.json)
- [Resource audit](evidence/image_extensions_incremental_20261019T094414Z_0a963272/resource_audit.json)
- [Final source/report check](evidence/image_extensions_incremental_20261019T094414Z_0a963272/final_readonly_check.json)

[BMP encoder](image/bmp_encoder/README.md) and
[BMP decoder](image/bmp_decoder/README.md) implement complete BMP24 BI_RGB,
BGR conversion, all four row-padding cases and top-down/bottom-up layouts.
The decoder supports validated pixel offsets and trailing file data, and
normalizes output to top-down raster order using synchronous frame RAM.
Unsupported formats, malformed markers, truncation and geometry errors are
explicitly rejected. Both cores cover 256x256 in functional simulation;
this maximum geometry is not claimed to fit the board memory budget.

The actual double-RTL chain passes 24 frames/1064 RGB pixels, external Pillow
decoding and independent pixel-byte/padding oracle, CE and backpressure.
Its error-propagating wrapper passes four healthy frames/768 pixels and three
error/recovery cases. Combined isolated synthesis is 5894 conservative
LUT-class, 0 DSP, 4 BRAM9 (16x12). Isolated encoder profiles use 648/641 LUT,
0 DSP, 2/6 BRAM9 at 16x12/64x32. Isolated decoder uses 5475/5492 LUT,
0 DSP, 12/24 BRAM9 at 64x64/128x64. No compression is provided by BMP24.
This layer freshly runs two core and six special/integration suites; eleven
ancestry layers check 897 observed files and 202 unchanged production files.
This is verified incremental offline evidence, not a fresh full 107-core run,
board acceptance, routed timing or full-resolution video-quality signoff.

## Previous checkpoint (105, verified incremental)

Latest completed checkpoint: **105 projects, 89 integrations, 107 RTL sources**,
**511 frozen inputs**. Two new PNG cores and ten additional suites pass.

- [Results](evidence/image_extensions_incremental_20261019T091505Z_33ad97ff/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T091505Z_33ad97ff/checkpoint_audit.json)
- [Ancestry audit](evidence/image_extensions_incremental_20261019T091505Z_33ad97ff/ancestry_check.json)
- [Resource audit](evidence/image_extensions_incremental_20261019T091505Z_33ad97ff/resource_audit.json)
- [Final source/report check](evidence/image_extensions_incremental_20261019T091505Z_33ad97ff/final_readonly_check.json)

[PNG encoder](image/png_encoder/README.md) emits complete gray8/RGB8 files,
CRC32/Adler32, filter None and stored DEFLATE (no compression-ratio benefit).
[PNG decoder](image/png_decoder/README.md) supports noninterlaced gray8/RGB8,
all five filters and stored/fixed/dynamic DEFLATE with 32KB history.
Unsupported formats and capacity overflow return explicit errors. Pixels are
provisional until successful DONE; discard the entire frame on error.

Actual encoder-to-decoder and external-PNG-to-decoder-to-encoder RTL chains
pass, including Pillow decoding of RTL-generated bytes. The combined chain
passes error propagation/recovery and isolated synthesis: 6489 conservative
LUT-class cells, 0 DSP, 42 BRAM9 units (16x12/4096-byte profile). Each block RAM
primitive counts as two BRAM9, including SPX9. This layer freshly executes two
core suites and ten additional suites. Ten-layer ancestry checks 869 observed
files and 202 unchanged production files. This is verified incremental offline
evidence, not a fresh full 105-core run or extension board/timing/video signoff.

## Previous checkpoint (103, verified incremental)

Latest completed checkpoint: **103 projects, 79 integrations, 105 RTL sources**,
**494 frozen inputs**. The new persistent rectangle-query core, its protocol
and numeric suites, and the actual RAW-calibration chain pass.

- [Results](evidence/image_extensions_incremental_20261019T085543Z_c7f0bb6c/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T085543Z_c7f0bb6c/checkpoint_audit.json)
- [Recursive ancestry audit](evidence/image_extensions_incremental_20261019T085543Z_c7f0bb6c/ancestry_check.json)
- [Resource audit](evidence/image_extensions_incremental_20261019T085543Z_c7f0bb6c/resource_audit.json)

The repository already contained streaming integral and squared-integral
generators. [Persistent integral queries](image/integral_image/README.md) add
whole-frame synchronous sum/squared-sum tables with zero boundaries, RAW12,
and repeated arbitrary half-open rectangle queries. This is not a claim that
integral images were previously absent. Twenty-eight frames/9324 queries
compare every table point and pixel rectangle against exact integer and actual
OpenCV integral2 arrays. Large-profile bounds and malformed-frame/reset/abort
recovery are separately covered. Default isolated synthesis uses 1633
conservative LUT-class cells, 0 DSP and 10 conservative BRAM9 units; a 64x32
profile uses 1940 LUT-class/24 BRAM9. Larger legal simulation geometries are
not claimed to fit the board memory budget.

The actual RAW12 black-level -> persistent integral RTL chain passes four
frames/252 pixels and 340 rectangle queries, including twelve invalid queries,
empty rectangles, full-frame and single-pixel sums/squared sums. CE, backpressure,
frame isolation and output markers are checked. This layer freshly executes
one core suite and three special/integration suites. Nine-layer incremental
ancestry checks 833 observed files and 202 unchanged production files; this
is not a fresh full 103-core run or extension board/timing acceptance.

## Previous checkpoint (102, verified incremental)

Latest completed checkpoint: **102 projects, 76 integrations, 104 RTL sources**,
**486 frozen inputs**. Three new RAW calibration cores and eight new
special/integration suites pass; source-bundle compilation and input stability pass.

- [Results](evidence/image_extensions_incremental_20261019T083828Z_e4fbfb90/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T083828Z_e4fbfb90/checkpoint_audit.json)
- [Recursive ancestry audit](evidence/image_extensions_incremental_20261019T083828Z_e4fbfb90/ancestry_check.json)
- [Source-bound resource audit](evidence/image_extensions_incremental_20261019T083828Z_e4fbfb90/resource_audit.json)
- [Independent RTL review](evidence/image_extensions_incremental_20261019T083828Z_e4fbfb90/peer_review.json)

Verified incremental execution extends 99/68 to 102/76. This layer freshly
runs three core suites and eight additional suites; it is not a fresh full
102-case run. Eight-layer ancestry checks 814 observed files and all 202
unchanged production files. These extension results are offline functional
verification; extension board and routed timing acceptance remain unproven.

| New core | Implemented behavior and tested scope | Isolated conservative LUT-class / DSP |
|---|---|---:|
| [RAW black level](image/raw_black_level/README.md) | Manual four-plane levels or actual same-frame optical-black ROI means; synchronous frame RAM, half-up mean, pedestal, clipping counters and explicit missing-plane errors. 126 cases/149064 pixels, protocol recovery and five invalid parameter profiles | 1560/1585/1618 at RAW8/10/12 / 0 |
| [RAW white balance](image/raw_white_balance/README.md) | Actual same-frame pooled-green gray-world gains with ROI and threshold gating, exact shared serial multiply/divide, Q12 limit/round/saturation; 160 cases/13682 pixels, actual 65536-pixel maximum frame, reset recovery and retrieved Infinite-ISP GrayWorld comparison | 2652 default, 2660/2680 alternate / 0 |
| [Static defect map](image/defect_map/README.md) | Complete double-buffered host defect map with atomic publication; nearest original valid same-phase donors over full frame, average of all distance ties, explicit no-donor fill/status; 144 main frames/6576 pixels, 16 numeric frames/1324 pixels and 21 protocol frames/504 pixels | 1771 default, 2280 alternate / 0 |

The actual RAW12 black-level -> RAW white-balance -> MHC RGB12 RTL chain
passes eight frames/504 RGB pixels across all four Bayer layouts. Independent
optical-black means, rational gray-world gains, both intermediate RAW streams,
final MHC pixels, markers, CE pauses and output backpressure are checked.
Black levels and gains are calculated in RTL from the captured frame.
Independent isolated configurations use conservative 2/2/6 BRAM9 units for
black-level/white-balance/defect-map respectively; no combined-chain synthesis
or real-time video claim is made. Mature-reference algorithm differences and
static-map calibration requirements are documented in each module README.

## Previous checkpoint (99, verified incremental)

Latest completed checkpoint: **99 projects, 68 integrations, 101 RTL sources**,
**466 frozen inputs**. Three new ISP cores and nine new regression entries
pass, along with complete source-bundle compilation and input stability.

- [Results](evidence/image_extensions_incremental_20261019T081023Z_0af698e1/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T081023Z_0af698e1/checkpoint_audit.json)
- [Recursive ancestry audit](evidence/image_extensions_incremental_20261019T081023Z_0af698e1/ancestry_check.json)
- [Source-bound resource audit](evidence/image_extensions_incremental_20261019T081023Z_0af698e1/resource_audit.json)

Verified incremental execution: 80/25 full baseline -> 84/30 -> 87/34 ->
90/41 -> 93/50 -> 96/59 -> 99/68. This layer freshly runs three core suites
and nine additional suites, not a fresh full 99-case regression. Seven-layer
ancestry checks 776 observed files and all 202 unchanged production files.
New extension board and routed timing acceptance remain unproven.

| New core | Implemented behavior and tested scope | Isolated conservative LUT-class / DSP |
|---|---|---:|
| [Malvar demosaicing](image/malvar_demosaic/README.md) | Actual signed 5x5 MHC kernels, all four production CFA patterns, synchronous full-frame RAW RAM, full-size REFLECT101 edges, saturation and sampled-channel preservation; 84 functional cases/12496 pixels, 12 mature-reference cases/1512 pixels, 18 numeric cases/1764 pixels and protocol recovery | 1127 default, 1227/1306 at 10/12 bits / 0 |
| [Lens shading](image/lens_shading/README.md) | Four Bayer-plane gain meshes, exact rational bilinear gain and one final RAW rounding, complete inactive-map loading and atomic publication, source-marker checks; 16 frames/3771 RAW points with Fraction and numerator checks, in-flight commits, parameter and recovery tests | 2122 default, 3058 alternate / 0 |
| [High-bit tone LUT](image/raw_gamma/README.md) | Synchronous double-buffered piecewise-linear LUT with exact full-range coordinates, endpoint and nonmonotonic-table support, three-stage elastic II=1 pipeline; 20 frames/38912 pixels, 15 protocol frames/480 pixels, ten invalid-profile rejections and full legal index proof | 1592 default, 1492 for 17 nodes / 0 |

The production CFA ABI remains 0=RGGB, 1=GRBG, 2=GBRG, 3=BGGR.
Two actual RTL chains pass: RAW12 lens shading -> MHC RGB12 (18 frames/450
RGB pixels including single-row/column geometry), and that chain -> three
lockstep tone LUTs -> RGB888 (six frames/378 pixels). Intermediate RAW,
RGB12 and final RGB888 are checked, including CE and backpressure. These are
functional simulations, not whole-pipeline synthesis or board acceptance.

MHC uses REFLECT101; the retrieved mature implementation's default boundary
mode differs, and its native border differences are preserved in reference
evidence. Matching-boundary comparison and the tested interior agree exactly.
Mesh gains and tone tables are externally provided; calibration/curve fitting
and full-resolution image-quality acceptance are outside these modules.
Serialized MHC and mesh correction have no real-time video claim; tone II=1
is a simulated transfer property, not routed timing signoff.

## Previous checkpoint (96, verified incremental)

Latest completed checkpoint: **96 projects, 59 integrations, 98 RTL sources**,
**443 frozen inputs**. Three new stereo processing cores, nine new regression
entries, complete source-bundle compilation and input-stability checks pass.

- [Results](evidence/image_extensions_incremental_20261019T075218Z_cb5502ca/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T075218Z_cb5502ca/checkpoint_audit.json)
- [Recursive ancestry audit](evidence/image_extensions_incremental_20261019T075218Z_cb5502ca/ancestry_check.json)
- [Source-bound resource audit](evidence/image_extensions_incremental_20261019T075218Z_cb5502ca/resource_audit.json)

Verified incremental execution: 80/25 full baseline -> 84/30 -> 87/34 ->
90/41 -> 93/50 -> 96/59. This layer freshly runs three core suites and nine
additional suites; it is not a fresh full 96-case execution. Six-layer ancestry
audit checks 734 observed files and all 202 unchanged production files.
Extension board and routed timing acceptance remain unproven.

| New core | Implemented behavior and tested scope | Isolated conservative LUT-class / DSP |
|---|---|---:|
| [Rectification sampling](image/stereo_rectify/README.md) | Host-loaded signed Q16.8 remap, atomic double map buffering, synchronous frame RAM, real four-tap bilinear interpolation and border validity; 25 functional cases/3540 pixels including synthetic OpenCV calibration maps, six numeric profiles and atomic/error/reset checks | 2779 default, 2147..3552 across three profiles / 0 |
| [Subpixel disparity](image/stereo_subpixel/README.md) | Complete disparity-axis WTA, second-best confidence, real adjacent costs and exact quadratic interpolation; 2480 Fraction-checked axes including COST24/Q12, protocol recovery and 10000 mature-source expression comparisons | 1073 default, 1262 wide profile / 0 |
| [Disparity speckle removal](image/disparity_speckle/README.md) | True four-neighbor connected components using neighbor disparity differences, thresholded component-size rejection, synchronous frame/visited/queue storage; 18 frames/1374 pixels with 1358 actual OpenCV comparisons, signed extremes and protocol recovery | 1207 default, 862..1642 across three profiles / 0 |

Two additional real RTL chains pass: automatic multiscale descriptors into
the Hamming matcher (five image pairs, 294 queries, including empty sets), and
SGM -> speckle removal -> general-Q XYZ (six frames, 462 pixels, disabled/small/
whole-frame rejection and all-invalid input). These are functional simulations,
not synthesized whole-pipeline resource or board acceptance claims.

Rectification requires externally supplied maps; no automatic calibration is
claimed. Q8 and OpenCV fixed-table Q5 remapping are explicitly separate numeric
variants. Subpixel symmetric rounding can differ from OpenCV's signed C++
expression by one Q4 unit; it is not claimed bit-compatible. These cores remain
serialized, bounded implementations without real-time video claims.

## Previous checkpoint (93, verified incremental)

Latest completed checkpoint: **93 projects, 50 integrations, 95 RTL sources**,
**422 frozen inputs**. Three newly developed cores and nine new regression
entries pass, including direct color JPEG codec and SGM-to-3D RTL chains.

- [Results](evidence/image_extensions_incremental_20261019T072950Z_e7adbe38/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T072950Z_e7adbe38/checkpoint_audit.json)
- [Recursive ancestry audit](evidence/image_extensions_incremental_20261019T072950Z_e7adbe38/ancestry_check.json)
- [Source-bound resource audit](evidence/image_extensions_incremental_20261019T072950Z_e7adbe38/resource_audit.json)

Verified incremental execution: 80/25 full baseline -> 84/30 -> 87/34 ->
90/41 -> 93/50. This layer freshly executes three core suites and nine
additional suites, compiles all 95 RTL sources, and preserves all 202 production
files. Recursive audit covers five layers and 694 observed files. Extension
board acceptance and routed timing remain unproven; original 48 board projects
are tracked separately.

| New core | Implemented behavior | Isolated conservative LUT-class / DSP |
|---|---|---:|
| [Color JPEG decoder](image/jpeg_color_decoder/README.md) | Actual baseline YCbCr 444/422/420 bytes-to-RGB, MCU sequencing, IDCT and centered chroma reconstruction with libjpeg narrow-image fallback; functional, malformed-stream, reset, numeric and Pillow comparisons; direct encoder-to-decoder chain | 9156 including LUTRAM / 0 |
| [Multiscale features](image/multiscale_features/README.md) | Automatic Gaussian pyramid, FAST9, NMS, centroid orientation and rotated BRIEF; OpenCV pyramid/corner comparisons and all 4096 derived ROM entries checked per tested radius | 9938 default, 10472 R15 / 0 |
| [Disparity reprojection](image/disparity_reproject/README.md) | General 4x4 Q homogeneous projection, subpixel disparity, atomic matrix configuration, zero/negative W and saturation status; exact integer, Decimal and actual OpenCV references; direct SGM input chain | 2874 default, 2837 alternate / 0 |

Serialized bounded implementations; no real-time or full-resolution claim.
Color JPEG progressive and nonzero restart intervals remain explicitly
unsupported. Ordinary JPEG comparisons stay within 3 RGB levels; extreme
coefficient streams can diverge from Pillow and retain explicit ideal-IDCT
evidence. Multiscale descriptors are not a complete OpenCV-compatible ORB.

## Previous checkpoint (90, verified incremental)

Latest completed checkpoint: **90 projects, 41 integrations, 92 RTL sources**,
**399 frozen inputs**. The three new cores, seven new integration/protocol
regressions, full source-bundle elaboration and production-baseline audit pass.

- [Results](evidence/image_extensions_incremental_20261019T070036Z_b4778f54/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T070036Z_b4778f54/checkpoint_audit.json)
- [Independent recursive ancestry audit](evidence/image_extensions_incremental_20261019T070036Z_b4778f54/ancestry_check.json)
- [Resource audit and peer review](evidence/sgm_oriented_jpeg_peer_review_20261019T070146Z_253373c1/resource_audit.json)
- [Cleanup](evidence/image_extensions_incremental_20261019T070036Z_b4778f54/cleanup_check.json)

This is **verified incremental execution**, not a fresh full 90-case run:
80/25 full baseline -> 84/30 -> 87/34 -> 90/41. The latest layer freshly runs
3 cases and 7 integrations, freezes 399 inputs, and compiles all 92 RTL sources.
The independent recursive audit checks all four evidence layers, 652 observed
files and 202 unchanged production files. No extension board or routed timing
acceptance is claimed; the original 48-project board acceptance is separate.

| New core | Implemented behavior and evidence | Isolated conservative LUT-class / DSP |
|---|---|---:|
| [Four-path SGM](image/stereo_sgm/README.md) | Exact normalized Census-cost recurrence in four cardinal directions, full disparity/score map; 10 local frames/510 pixels with every aggregate bin checked; real dual-Census frontend integration adds 12 frames/1404 pixels | 1265..1579 across three profiles / 0 |
| [Oriented BRIEF](image/oriented_brief/README.md) | Circular intensity centroid, 16 orientation bins, actual rotated 256-bit sampling; radii 1..15, 264 local descriptors/88 frames, quarter-turn invariance; real FAST/NMS frontend adds 14 frames/529 results (68 valid descriptors) | 6780 / 0 |
| [Gray JPEG decoder](image/jpeg_gray_decoder/README.md) | Compressed bytes through header/Huffman parsing, dequantization, wide IDCT and raster output; 31 normal/error cases/9431 output pixels, abort/reset recovery and four numerical extremes; direct RTL encoder-to-decoder integration adds 4 images/438 pixels | 4854 including LUTRAM / 0 |

Oriented BRIEF has a proven orientation quantization error below 12 degrees;
it is not a complete ORB implementation or OpenCV-compatible descriptor.
JPEG supports baseline sequential single-component grayscale; color,
progressive and restart streams terminate explicitly as unsupported. Ordinary
JPEG fixtures differ from Pillow by at most 1 gray level. Extreme entropy-category
stress streams match ideal double-precision IDCT in tested cases but can differ
from Pillow by 255; the numerical report preserves that divergence. These are
serialized resource-bounded implementations, without real-time video claims.

## Previous checkpoint (87, verified incremental)

Previously completed checkpoint: **87 projects, 34 integrations, 89 RTL sources**,
**348 frozen inputs**. All registered results, complete bundle compilation,
input stability, production baseline and recursive ancestry audits pass.

- [Results](evidence/image_extensions_incremental_20261019T062717Z_fee08795/results.json)
- [Checkpoint audit](evidence/image_extensions_incremental_20261019T062717Z_fee08795/checkpoint_audit.json)
- [Recursive ancestry audit](evidence/image_extensions_incremental_20261019T062717Z_fee08795/ancestry_check.json)
- [Cleanup](evidence/image_extensions_incremental_20261019T062717Z_fee08795/cleanup_check.json)

Execution is **verified incremental**, not a fresh full 87-case run:
80 full cases / 25 integrations -> 4 newly executed cases / 5 integrations ->
3 newly executed cases / 4 integrations. Every inherited input and result is
bound to its sealed baseline, and all 89 RTL files compile together. The recursive
audit verifies all three evidence layers and 202 unchanged production files.
No extension board or routed timing acceptance is claimed.

| Newly developed core | Actual function and local evidence | Isolated LUT/ALU/MUX budget |
|---|---|---:|
| [Local entropy](image/entropy_filter/README.md) | True 256-bin local Shannon entropy, 3/5/7 windows; 33 functional frames / 3918 pixels and 30 recovery frames, actual SciPy/skimage comparison with explicit Q20 error bound | 372, 0 DSP |
| [Three-class Otsu](image/multi_otsu/README.md) | Exact rational globally optimal two thresholds, 11 functional frames / 32 recovery frames; full 256 levels and count1024 tested; equally optimal skimage tie differences documented | 2164, 0 DSP |
| [Chamfer matching](image/chamfer_match/README.md) | Real EDT, edge template, complete directed mean squared-distance score map and best origin; 13 frames / 2556 scores, 39 recovery frames, empty-data sentinels and independent SciPy checks | 1441 including conservative LUTRAM conversion, 0 DSP |

All three have independent peer review and frozen source/dependency assets.
[Combined elaboration and peer review](evidence/entropy_otsu_chamfer_bundle_20261019T062529Z_32b85dc4/results.json).

## Previous checkpoint (84, verified incremental)

84 cases / 30 integrations / 86 RTL sources / 331 frozen inputs passed.
[Results](evidence/image_extensions_incremental_20261019T062248Z_1f8558c6/results.json),
[audit](evidence/image_extensions_incremental_20261019T062248Z_1f8558c6/checkpoint_audit.json),
[ancestry](evidence/image_extensions_incremental_20261019T062248Z_1f8558c6/ancestry_check.json).
Gabor, Niblack, finite Hough segments and the automatic Hough segment pipeline
were freshly executed here. The remaining 80 cases reused the full baseline
below only after hash, registry-behavior and source-list checks passed.

## Previous full-regression baseline (80)


Latest completed **full execution** checkpoint: **80 projects, 25 integrations,
82 RTL sources**, **305 frozen inputs**. All cases, integrations, complete bundle
compilation and complete input-closure stability pass. The audit binds both
results and the tested-input hash table. All 202 production baseline files are unchanged.

- [Results](evidence/image_extensions_20261019T054112Z_74ffccb7/results.json)
- [Audit](evidence/image_extensions_20261019T054112Z_74ffccb7/checkpoint_audit.json)
- [Cleanup](evidence/image_extensions_20261019T054112Z_74ffccb7/cleanup_check.json)

Added to this checkpoint: actual joint spatial-color Mean Shift filtering,
exact-central-moment adaptive Wiener denoising and complete 180-degree polar
Hough lines. Individual READMEs state numerical variants and supported bounds.
No incremental result reuse was used. No extension board acceptance is claimed.

At this historical 80-case baseline, four modules were staged. They subsequently
passed the 84-case incremental checkpoint above; their local evidence is retained below.

## Previous checkpoint (77)


Latest completed full-regression checkpoint: **77 projects, 22 integrations, 79 RTL sources**, with **289 frozen inputs** and all 202 production baseline files unchanged.
[Results](evidence/image_extensions_20261019T050159Z_897e7f00/results.json) and
[audit](evidence/image_extensions_20261019T050159Z_897e7f00/checkpoint_audit.json).
All cases, integration tests, complete bundle compilation and input stability passed.
No extension board acceptance is claimed.

Added in this checkpoint: seam-to-multiband pipeline, unsharp mask, complete-circle
Hough voting, phase-correlation registration and true ZNCC template matching.
Their individual READMEs specify numerical variants, bounded dimensions, protocol
coverage and isolated synthesis results.

Historical note: Mean Shift, adaptive Wiener denoising and full-angle Hough lines
were staged after this 77 checkpoint; they subsequently passed the full 80-project
checkpoint linked above. Incremental reuse remains disabled. Gabor, Niblack, finite Hough segments and the automatic Hough-to-segment pipeline
are locally complete in separate directories and are not in the 80 count.

## Modules integrated at checkpoint 84

These four modules passed local implementation, test, synthesis and independent
review, then the 84-case incremental checkpoint. No board pass is claimed.
[Combined elaboration](evidence/new_four_bundle_20261019T055715Z_9bb2d63a/results.json)
passes for all 86 RTL sources; all four frozen local asset sets and pipeline dependency hashes match.

| Core | Functional evidence | Isolated maximum configuration |
|---|---|---|
| [Complex Gabor](image/gabor_filter/README.md) | Real/imaginary full convolution, host coefficient generator; 44 normal and 30 recovery frames, SciPy exact and actual OpenCV checks; independent asymmetric-kernel and worst-case accumulation probes | 1285 LUT/ALU/MUX, 0 DSP at 32x32 |
| [Niblack](image/niblack/README.md) | Exact central moment and Q8 square root, signed k/bias; 19 functional and 22 recovery frames; actual skimage comparison with one explicitly documented quantization-boundary classification difference; independent 750 threshold checks | 1659 LUT/ALU/MUX, 0 DSP |
| [Finite Hough segments](image/hough_segments/README.md) | Real edge-supported endpoints for one supplied polar candidate, max gap/min length/min support; 27 fixtures/38 segments, 29 recovery frames; independent seven endpoint/gap/length probes | 1034 LUT/ALU/MUX, 0 DSP |
| [Automatic Hough segments](image/hough_segment_pipeline/README.md) | Complete frame-to-peaks-to-real-endpoints hierarchy, synchronous per-candidate replay; 8 fixtures / 28 candidates / 38 segments, 40 recovery frames and independent handshake/terminal-boundary review | 2554 LUT/ALU/MUX, 0 DSP, full hierarchy |

## Previous checkpoint (72)


Latest completed checkpoint: **72 projects, 20 integrations, 74 RTL sources**
(73 extension sources and one unchanged production dependency).
[Results](evidence/image_extensions_20261019T043614Z_0444e49c/results.json),
[audit](evidence/image_extensions_20261019T043614Z_0444e49c/checkpoint_audit.json)
and [cleanup](evidence/image_extensions_20261019T043614Z_0444e49c/cleanup_check.json)
confirm all cases, integrations, bundle compilation and 266 frozen inputs pass;
all 202 production baseline files remain unchanged. No extension board or
routed timing acceptance is claimed.

Newly integrated cores:

| Core | Actual function and verification | Isolated resources |
|---|---|---|
| [Seam finding](image/seam_find/README.md) | Three-neighbor DP, full traceback, vertical/horizontal seam and feather mask; 12 main frames and 15 recovery frames, independent shortest path and small exhaustive checks | 1659 LUT, 653 FF, 0 DSP |
| [Poisson blending](image/poisson_blend/README.md) | Normal/mixed gradient-domain Q8 Gauss-Seidel with true residual reporting; 47 frames/9443 pixels, integer oracle and SciPy sparse reference; iteration-limited frames explicitly unconverged | 848 LUT, 83 MUX5, 3 MUX6, 367 FF, 3 DPX9B, 0 DSP at 32x32 |
| [Phase correlation](image/phase_correlation/README.md) | True dual 2D FFT, cross-power magnitude normalization, IFFT and integer circular peak; 8/16/32 sizes, 20 main frames and 10 recovery frames, NumPy/OpenCV displacement checks | Up to 2250 LUT, 1622 ALU, 1395 FF, 9 DPX9B, 0 DSP |

Two further completed cores have independent local evidence and are staged
for the next shared regression; they are **not included in the 72 count**:

- [Automatic seam-to-multiband frame pipeline](image/seam_multiband_blend/README.md):
  actual seam mask, synchronous A/B replay and Laplacian reconstruction;
  10 normal frames and 19 recovery frames pass. Abort and terminal-child-error
  output handshakes are consistently gated and tested at the sampling edge.
  Full hierarchy: 3652 LUT, 1341 FF, 0 DSP; combined source-bundle compile passes.
- [Unsharp mask](image/unsharp_mask/README.md): gray/RGB Gaussian detail sharpening,
  gain/threshold snapshot, saturation; 116 frames/16646 pixels and 36 recovery
  frames pass. Actual OpenCV comparison differs by at most one output LSB.
  32x32 RGB: 479 LUT, 65 MUX5, 244 FF, 2 DPX9B, 0 DSP.

Hough circle detection is under development; no completion claim is made.

## Previous checkpoint (69)

Latest completed checkpoint: **69 projects, 19 integrations, 71 RTL sources**
(70 extension sources and one unchanged production dependency).
[Results](evidence/image_extensions_20261019T035158Z_aa38d684/results.json) and
[checkpoint audit](evidence/image_extensions_20261019T035158Z_aa38d684/checkpoint_audit.json)
prove all cases/integrations, the complete source-bundle compile and input
stability pass. All 252 tested inputs (including the Lab ROMs and oracle
matrix) match their hashes; all 202 production baseline files remain intact.
New build temporaries are absent. Required ROM assets are retained.

The latest four projects have functional and isolated synthesis evidence;
none has board or routed timing acceptance:

- CIELAB conversion implements sRGB transfer functions, D65 XYZ matrices,
  Lab nonlinearity and the full inverse using synchronous ROMs and serial
  arithmetic. 3248 actual samples match the integer reference; tested direct
  CIE formula differences are at most one LSB. Actual OpenCV differences are
  forward [1,2,1] and inverse [1,1,1] LSB, respectively. Ten multirow protocol
  frames, nine CE-disabled reset/recovery stages and four illegal geometries
  pass. Eight-bit Lab roundtrip loss reaches [16,2,4] RGB LSB on these fixtures;
  direct CIE quantization gives the same worst loss, so lossless behavior is
  not claimed. Tested isolated geometry counts reach 1852 LUT, 1336 ALU,
  786 FF, eight SPX9 and zero DSP.
- RGB K-means provides seeded frame-sample initialization, full Lloyd passes,
  integer center updates, explicit empty-cluster retention, convergence or
  iteration-limit stopping and final reassignment with labels/quantized colors,
  centers, counts and inertia. 57 complete frames / 7259 pixels, four sizes
  through 32x32, invalid configurations and protocol/recovery checks pass.
  Actual sklearn comparison matches on three integral fixtures with identical
  initial centers; random-image differences from floating means and empty-
  cluster relocation are reported without an equivalence claim. At 32x32:
  2083 LUT, 235 MUX5, 878 FF, two DPX9B and zero DSP. Capacity is 1024 pixels.
- Multiband blending is a real two/three-level Gaussian/Laplacian pipeline
  over two grayscale images and a mask, with signed Q8 band differences and
  coarse-to-fine reconstruction. Twelve fixture classes / thirteen frames
  match the integer oracle; actual OpenCV double pyrDown/pyrUp differences
  reach one grayscale unit. Odd/thin/32x32 geometries, mask extremes and seven
  CE-low reset stages pass. Seam output differs from single-layer weighting
  by up to 64 units, demonstrating actual band processing without a general
  quality claim. Synthesis: 1825 LUT, 600 FF, nine DPX9B, zero DSP.
- The complete Lab K-means quantizer reuses one converter for RGB-to-Lab and
  inverse passes around the real clustering engine. Ten full normal frames
  and fourteen post-error/reset recovery frames verify pixels, labels,
  markers, initial/final centers and every statistic. It explicitly clusters
  encoded Lab8, not unscaled CIE DeltaE. Full hierarchy synthesis at 7x5/32x32
  uses 5232/5152 LUT, 549/481 MUX and 1715/1691 FF, with eight SPX9 plus
  18 RAM16SDP4 / two DPX9B, zero DSP. See its README for ROM path parameters,
  whole-frame error discard, abort and reset/restart contracts.

Previous completed checkpoint: **65 projects, 17 integrations, 67 RTL sources**
(66 extension sources and one unchanged production dependency).
[Results](evidence/image_extensions_20261019T032008Z_f610111b/results.json) and
[checkpoint audit](evidence/image_extensions_20261019T032008Z_f610111b/checkpoint_audit.json)
show every case/integration, complete source-bundle compilation and input
stability passing without retries. All 232 tracked inputs and 202 production
baseline files match their hashes. Checkpoint temporary files are absent.

The three latest additions have actual local functional and isolated synthesis
evidence, with no board/route/timing claim:

- RGB/HSV_FULL conversion: 5308 integer-exact samples, actual OpenCV differences
  at most one LSB on tested channels; 11 protocol frames, six reset phases,
  held DONE and four illegal geometries. Forward hue uses a 256-unit turn;
  inverse uses the documented OpenCV FULL 255-unit convention. Actual two-core
  RGB-to-HSV-to-RGB integration checks four adjacent 32x16 frames / 2048 pixels
  with an exact composed oracle, CE/backpressure and markers. Maximum roundtrip
  difference on these fixtures is eight RGB LSB; lossless conversion is not
  claimed. Individual synthesis uses at most 1035 LUT plus 682 ALU, 219 FF,
  zero DSP and zero RAM.
- Fixed-point MOG3: three persistent grayscale Gaussian models, matching,
  learning, replacement, exact weight normalization, score sorting and
  foreground/background outputs. 210 complete frames / 6902 pixels, complete
  123-bit model words, 53 rejected configurations and threshold/variance
  boundary cases pass. Maximum geometry is 1024 pixels. Failed-marker frames
  invalidate all models for automatic cold rebuilding; rejected configuration
  preserves models and ignores its reset request. This specified variant is
  not OpenCV MOG2. Same-algorithm floating checks cover 5824 temporal samples
  with zero foreground differences and maximum background difference 0.501026
  grayscale units on these fixtures. At 32x32: 2462 LUT, 363 MUX, 634 FF,
  seven SPX9 and four RAM16SDP4, zero DSP. Serial processing prioritizes area.
- Perspective RANSAC: seeded four-point hypotheses, source/destination
  degeneracy rejection, full consensus scoring, all-inlier refit and final
  reclassification. Seven fixture classes / nine actual runs include genuine
  perspective, outliers, 64 matches, replay and explicit failures. Fraction
  reference prediction differences reach 0.000388 pixels; actual OpenCV
  comparison reaches 0.1418 pixels on common inliers. Signed input coordinates
  are limited to [-127,127]; matrices use signed64 Q24 and thresholds unsigned
  Q16 Manhattan pixel error. Near-degenerate normal equations and arithmetic
  overflow explicitly fail. Arithmetic/protocol/six-stage CE-low reset tests
  pass. Synthesis uses 9059 LUT, 1187 MUX, 3739 FF, four SDPX9B and
  48 RAM16SDP4, zero DSP.

Previous completed checkpoint: 62 projects, 15 integrations, 64 RTL source
files (63 extension sources and one unchanged production dependency).
See [resolved checkpoint](evidence/image_extensions_20261019T022352Z_e6ce2770/resolved_checkpoint.json).
All 220 tracked test inputs remain identical; all 202 production baseline
files remain unchanged. One color-scan error-test compiler launch received
Windows `WinError 5`; its original failure log is preserved and an unchanged
rerun passed. The original `results.json` is retained without rewriting its
failure. `resolved_checkpoint.json` binds the successful retry evidence.

The four added color JPEG projects provide actual RGB-to-JFIF encoding with
runtime 444/420 sampling, dual quantization tables, independent component DC
predictors and MCU-boundary restart markers. Twenty complete RTL files match
an independent integer entropy oracle byte for byte and decode with Pillow;
22 error/reset recovery files also decode. The full encoder synthesizes at
6935/6953 LUT and zero DSP for 16x16/33x17, with CHECK passing. Compile-time
capacity is at most 65536 pixels; the serial full-frame implementation makes
no real-time video claim. These extensions have not been board accepted.
Temporary build products for this checkpoint have been removed; small logs,
JPEG fixtures, hashes and baseline artifacts are retained.

These new cores use a separate source list, `rtl_extension_sources.f`. They do
not change the original 48-core production acceptance snapshot.

| Core | Source directory | Function |
|---|---|---|
| RGB/CIELAB converter | `image/cielab_color` | Complete sRGB / D65 XYZ / Lab transforms and inverse with synchronous nonlinear ROMs |
| K-means frame segmentation | `image/kmeans_segmentation` | Seeded complete Lloyd clustering, final labels/colors and full statistics |
| Multiband image blend | `image/multiband_blend` | Gaussian/Laplacian pyramids, per-band masks and coarse-to-fine reconstruction |
| Lab K-means color quantizer | `image/lab_kmeans_quantizer` | Actual RGB-to-Lab clustering-to-RGB frame hierarchy with shared converter |
| RGB/HSV_FULL converter | `image/hsv_color` | Bidirectional integer color conversion, stream backpressure and held completion |
| Three-Gaussian background | `image/mog3_background` | Persistent grayscale mixture models, foreground mask and background estimate |
| Perspective RANSAC estimator | `image/homography_ransac` | Four-point hypotheses, inlier scoring and all-inlier homography refit |
| Color JPEG headers | `dsp/jpeg_color_headers` | Three components, dual DQT, four default DHT, 444/420, DRI/RST/EOI |
| Color JPEG entropy scan | `dsp/jpeg_color_scan` | Shared serial transform/quantizer, three DC predictors, MCU-boundary restarts |
| RGB color JPEG MCU formatter | `image/jpeg_color_mcu` | RGB888 raster to 444/420 YCbCr blocks, edge replication and chroma averaging |
| Complete color JPEG frame | `dsp/jpeg_color_frame` | Actual RGB raster to complete baseline JFIF file, runtime mode/table updates |
| Automatic exposure controller | `image/auto_exposure` | Frame-statistics feedback, bounded exposure and Q8 gain recommendations |
| Chroma 4:2:2 reconstruction | `image/chroma_reconstruct/upsample422` | Nearest/linear reconstruction with explicit chroma siting |
| Chroma 4:2:0 reconstruction | `image/chroma_reconstruct/upsample420` | Nearest/bilinear reconstruction with horizontal and vertical siting |
| Statistics-to-AE bridge | `image/ae_stats_bridge` | Aggregate synchronous zone RAM records into AE frame statistics; explicit overruns |
| Packed RAW decoder | `image/raw_unpack` | CSI-2 RAW10/RAW12 payload-byte unpacking, explicit malformed-group handling |
| Linear ASRC | `dsp/asrc` | Dual-clock sample FIFO, fractional interpolation and dynamic externally supplied ratio |
| Dual-exposure HDR | `image/hdr_dol` | Active-row LONG/SHORT alignment, exposure normalization, saturation blend and motion rejection |
| RGB565 conversion | `image/rgb565` | RGB888 packing and bit-replicated expansion, optional rounding and byte swap |
| Packed RAW encoder | `image/raw_pack` | CSI-2 RAW10/RAW12 payload-byte packing, independently checked pack/unpack round-trip |
| DCT/IDCT | `dsp/dct8x8` | Serial fixed-point orthonormal 2D 8x8 DCT-II and inverse; block transport |
| Contrast autofocus | `image/autofocus` | Coarse/fine lens search with acknowledged actuator commands and settling-frame rejection |
| JPEG entropy bit packing | `dsp/jpeg_bitstream` | MSB-first code/amplitude packing, FF00 stuffing and ones-padding at explicit scan flush |
| JPEG quantization | `dsp/jpeg_quant_zigzag` | Block quantization/dequantization, standard zigzag/inverse zigzag, atomic runtime tables |
| JPEG coefficient symbols | `dsp/jpeg_entropy` | Per-component DC prediction, AC run/category/amplitude, ZRL/EOB and restart events |
| JPEG default Huffman tables | `dsp/jpeg_huffman` | Annex K luma/chroma DC/AC canonical lookup, metadata preservation |
| NV12/NV21 frame layout | `image/nv12_layout` | Macro-stream to/from planar byte memory transactions, stride/address/odd-geometry checks |
| Raster/block rearrangement | `image/raster_blocks` | Synchronous frame RAM, 8x8 blocks, edge replication and inverse padding removal |
| Grayscale JPEG headers | `dsp/jpeg_headers` | RTL SOI/DQT/SOF0/DHT/DRI/SOS/EOI/RST byte emission with atomic frame configuration |
| JPEG multi-block scan control | `dsp/jpeg_scan_control` | Continuous block bits, restart alignment/markers, predictor-reset handshake and cancellation |
| Grayscale JPEG scan encoder | `dsp/jpeg_grayscale` | Reusable block-pixel DCT/quantization/symbol/Huffman/scan integration |
| FAST-9 corner score map | `image/fast9` | Radius-three 9/16 circle arcs, strict threshold, full-frame synchronous RAM; no nonmaximum suppression |
| Connected components | `image/connected_components` | Exact 4/8 connectivity, raster labels, area/bbox; explicit label-capacity overflow |
| Binary distance transform | `image/distance_transform` | Exact Manhattan L1 or chessboard Linf, two synchronous RAM passes; no Euclidean-distance claim |
| Four-angle Hough accumulator | `image/hough_lines` | Explicit 0/45/90/135 degree normals with Q8 diagonal coefficients; saturating counts and peak |
| RAW bad-pixel correction | `image/bad_pixel` | Same-Bayer-phase eight-neighbor median and strict threshold, two-pixel border passthrough |
| Census descriptors | `image/census` | 3x3/5x5 row-major descriptors with center omitted, optional intensity deadband and explicit border flag |
| Census stereo matching | `image/stereo_census` | Rectified integer disparity search, Hamming cost, absolute uniqueness and invalid flags; includes actual dual-Census RTL integration tests |
| Gaussian image pyramid | `image/gaussian_pyramid` | 1..4 successive binomial 5x5/2 levels, REFLECT_101 border, ceil geometry, synchronous ping-pong memory |
| Stereo left/right consistency | `image/stereo_lr_check` | Positive right-reference disparity, matched-coordinate check, absolute tolerance and explicit invalid reason |
| Integer 2D Haar lifting | `dsp/haar2d` | Reversible signed forward/inverse transform, odd-tail preservation and checked arithmetic ranges |
| RGB 3D LUT | `image/color_lut3d` | Endpoint-aligned exact-rational trilinear color mapping, whole-table commit between frames; normalized .cube host import |
| Block motion estimation | `image/block_motion` | Exhaustive integer SAD search, actual partial edge blocks, deterministic ties, runner-up gap and invalid reasons |
| Temporal median background | `image/median_background` | Exact per-coordinate median of three/five previous completed frames, explicit warmup and foreground threshold |
| HOG feature variant | `image/hog` | Nine approximate unsigned orientation bins, L1 gradient magnitude and overlapping 2x2-cell L1-normalized descriptors; not L2-Hys |
| Corner nonmaximum suppression | `image/corner_nms` | Full score-map 3x3 NMS, strict frame-atomic threshold, local raster tie rule, selectable border handling; actual FAST9 chain tested |
| Programmable BRIEF variant | `image/brief` | 128/256 intensity-pair bits, atomic runtime patterns and explicit invalid patches; upstream smoothing required for smoothed BRIEF |
| Sauvola adaptive threshold | `image/sauvola` | Local population statistics, integer square root and explicit quantized Sauvola formula; independently measured float-reference error |
| Binary descriptor matching | `image/descriptor_match` | Exact Hamming best/second matches, strict ratio and gap filtering, metadata and invalid reasons; actual BRIEF chain tested |
| Zhang–Suen thinning | `image/thinning` | Two simultaneous-deletion subiterations, zero exterior, explicit convergence/iteration-limit status and ping-pong RAM |
| Histogram specification | `image/histogram_match` | Atomic reference histogram, exact normalized-CDF closest target with lowest-intensity ties, full-frame mapping; discrete, not interpolated |
| Binary hole filling | `image/hole_fill` | Exact boundary-background BFS with 4/8 connectivity, filled mask and hole count, bounded full-frame queue |
| Block motion compensation | `image/motion_compensation` | Exact integer backward warp, ordered partial-block vectors, invalid/out-of-bounds fill and metadata; actual motion-estimation chain tested |
| Gray-level co-occurrence matrices | `image/glcm` | Four integer-offset directions, 16/32-level quantization, optional symmetric voting and exact contrast/dissimilarity/ASM numerators and denominators |
| Squared Euclidean distance transform | `image/euclidean_distance` | Exact separable min-plus squared distances and nearest zero coordinates, lowest raster ties and explicit absent-feature invalid |
| Spatial moments and centroid | `image/moments` | Exact unsigned raw moments through order two, intensity/binary weights and optional mask, hardware Q16.16 centroid with explicit empty support |
| Morphological reconstruction | `image/morph_reconstruction` | Full-precision grayscale dilation/erosion reconstruction with 4/8 connectivity, explicit marker/mask ordering and bounded convergence |
| Dense Lucas–Kanade optical flow | `image/optical_flow` | Two-frame, single-scale, single-linearization local least-squares flow with signed fixed-point displacement, texture rejection and explicit border/range invalidity |
| Binary mask run-length codec | `image/binary_rle` | Canonical row-bounded encoder and strict coverage-checking decoder, explicit malformed-token errors and lossless pixel transport |
| Single-scale grayscale Retinex | `image/retinex` | Fixed binomial 5x5 surround, REFLECT_101 borders, quantized log2 ratio and configurable saturated display mapping; not multiscale or color restoration |
| Floyd–Steinberg error diffusion | `image/error_diffusion` | Uniform grayscale quantization with signed Q4 error diffusion, optional internal serpentine traversal and raster-order input/output |
| Field-to-progressive deinterlacing | `image/deinterlace` | Temporally ordered odd/even fields, WEAVE, linear BOB or local-threshold adaptive selection; not motion compensation or bwdif |
| Marker-controlled watershed | `image/watershed` | Elevation-priority flooding with label-on-push, deterministic discovery ties, 4/8 connectivity and domain mask; bounded tile processing without watershed lines |
| Brown–Conrady lens mapping | `image/lens_distortion` | Hardware radial/tangential inverse sampling coordinates, atomic calibration and explicit fixed-point overflow/OOB flags; serial arithmetic |
| Affine RANSAC estimation | `image/affine_ransac` | Seeded three-point hypotheses from signed16 matches, hardware affine solve and QFRAC L1 consensus scoring; no refinement or OpenCV-equivalence claim |
| Complete binary contours | `image/contours` | Ordered oriented cell-edge loops including holes, FG4/BG8 topology, signed area and synchronous edge memory; not pixel-center contours |
| Pyramidal iterative optical flow | `image/pyramidal_flow` | Coarse-to-fine Gaussian pyramid, interpolated initial flow and iterative bilinear warping/local LK; bounded grayscale tiles |
| General affine stabilization | `image/video_stabilization` | Accumulated and EMA-smoothed affine trajectories, hardware inverses and forward/inverse correction matrices; pixel sampling is downstream |
| RGB lateral chromatic correction | `image/chromatic_aberration` | Independent red/blue radial calibration, frame RAM and bilinear sampling, green preserved |

Run from the repository root:

```powershell
python cores/system/common_scaffold/integration/test_image_extensions.py
```

The runner executes each core's independent numerical regression, stores logs
in a unique `evidence/image_extensions_*` directory, and binds passing results
to the tested RTL SHA256. A source changed during its regression is rejected.
The runner snapshots its source list, listed RTL, test entry scripts, companion
Python/Verilog sources in each core directory, integration entry scripts and
tooling before testing, then checks that these inputs stayed
unchanged across the complete run. The snapshot is saved with the results.
Individual core documentation specifies interfaces, buffering, boundaries,
and synthesis results.

The runner also compiles the complete extension source list together and verifies
that earlier tested RTL did not change while later regressions ran. The statistics
bridge end-to-end test additionally compiles the existing `dsp_isp_library` meter.

The ASRC needs an external ratio controller and an antialias filter for qualified
downsampling. HDR accepts explicitly marked active LONG/SHORT rows; it does not
parse sensor-specific DOL blanking or CSI transport. Resource and throughput
limits in each core README remain part of its interface contract.

These extension regressions are local simulation evidence. They do not assert
board acceptance, full-resolution video throughput, image-quality qualification,
or camera actuator integration. AE supplies recommendations; a camera driver
must apply exposure and gain with the sensor's frame latency.

`integration/test_jpeg_scan.py` tests the actual DCT→quantization→symbols→Huffman→
byte-packer RTL chain. It compares entropy bytes with an independent numerical
and canonical-code oracle, supplies JPEG headers in software, and decodes three
8x8 grayscale files with Pillow. The constant, stripe and random fixtures have
maximum pixel errors 0, 5 and 8 at a constant quantization table of 8. This scope
is one block per scan, with no restart markers, chroma subsampling or hardware
headers. It is not a complete camera/JPEG product. The unified runner also runs
the DCT→quant→dequant→IDCT round-trip regression. Python Pillow is required for
the JPEG decoder check; no physical measurement hardware is required.

The later `integration/test_jpeg_frame.py` regression instantiates actual RTL
raster rearrangement, grayscale scan encoding and header emission. No software
headers are used in its output JPEGs. Four complete grayscale images (8x8,
16x16, 13x9 and 1x1) pass exact independent entropy comparison and Pillow decode,
including right/bottom edge padding and restart intervals 0/1/2. The maximum
pixel errors are 8/8/6/0 for these lossy table=8 fixtures. Small JPEG evidence
files are retained for inspection. Local malformed-block and abort tests also
pass; held abort and CE-paused abort are regression-covered in the controller.
This extends file interoperability evidence, not board timing or real-time
video throughput qualification.

Latest integrated checkpoint: `evidence/image_extensions_20261018T193241Z_278c0fd7/results.json`.
All thirty-one extension projects (including integration cores) passed their functional regressions and the complete
extension source bundle compiled together. Each project has isolated Gowin synthesis
evidence in its directory or linked evidence folder; none has board acceptance.
The original production snapshot was independently rechecked: 202 files, zero
SHA256 mismatches. Simulation executables and generated vectors use temporary
directories and are removed after execution; retained outputs are small logs and
reviewable evidence.

The four new vision cores are included in this checkpoint. FAST-9 has 26 RTL
fixture frames plus an independent OpenCV 5.0.0 coordinate cross-check on 18
images. Connected components has 102 fixture frames including nine expected
label-capacity overflows. Distance transform has 72 fixture frames; Hough has
56 frames with 3168 exact accumulator bins and 56 peaks. These are functional
coverage counts, not board acceptance or unrestricted performance claims.

RAW bad-pixel correction adds 42 valid frames / 2289 pixels across seven
profiles, including strict thresholds, hot/dead samples, phase isolation and
bad-frame recovery without reset. The final unified 25-project regression,
three integration checks and source-bundle compilation all pass. FAST test
configuration handshakes now explicitly require CE as well as ready. All 202
original production snapshot hashes remain unchanged. New-core synthesis is
isolated; none of these extension results establishes board acceptance.

Census descriptors add 96 frames / 4871 output words covering both 3x3 and
5x5 windows, one-hot bit-order patterns, equal/max thresholds, malformed-frame
recovery, CE/backpressure and thin images. Unified checkpoint: 26 projects,
three integration tests and complete source-bundle compilation PASS. All 202
production snapshot hashes remain unchanged. Census synthesis has no DSP
and synchronous frame RAM; this is a descriptor stage, not a stereo matcher.

Census stereo matching adds 87 descriptor frames / 1397 outputs and eight
paired grayscale frames / 720 outputs through two actual Census RTL cores
and the matching RTL. Disparity, Hamming cost and invalid flags match independent
numerical models. Unified checkpoint: 27 projects, three integration checks
and complete source bundle PASS. The original 202-file production snapshot
is unchanged. This is integer rectified winner-takes-all matching, with explicit
absolute cost-gap uniqueness; no SGM, depth calibration or board claim.

Multi-level Gaussian pyramid adds 48 frames / 1032 outputs and 150 exact
OpenCV pyrDown per-level cross-checks across 8/10/16-bit inputs, odd/thin
geometry, 1x1 saturation of dimensions and one to four levels. Unified
checkpoint: 28 projects, three integration checks and complete source bundle
PASS. All 202 original production snapshot hashes are unchanged. Black-level
and lens-shading RTL already exist in dsp_isp_library and were not duplicated.

Parallel additions: stereo LR consistency (114 frames / 3496 samples),
reversible 2D integer Haar (36 actual RTL roundtrips, 72 frames / 1536 outputs),
and exact RGB 3D LUT (400 pixel comparisons, including actual normalized .cube
export-to-RTL loading). LUT grids include 17^3, full table/last/commit checks
and endpoint-aligned rational interpolation. The host exporter rejects invalid
tables and has an optional independent FFmpeg ordering check, which passed.
Unified checkpoint: 31 projects, four integration checks and complete source
bundle PASS. All 202 original production snapshot files remain unchanged.
These three additions have isolated synthesis evidence; no new board or
timing acceptance is implied. Temporary fixture/executable cleanup is automatic.

Integrated checkpoint: [34 projects and five integration checks](evidence/image_extensions_20261018T200424Z_c9d787ff/results.json),
complete source-bundle compile and tracked-input stability all PASS. The original
202 production snapshot files were rechecked unchanged; the evidence directory
contains the baseline check and integrated RTL hashes.

This checkpoint adds exhaustive block motion (130 oracle frames / 834 vectors),
previous-frame temporal median background (147 frames / 2118 outputs), and the
HOG variant (84 frames / 6912 descriptor values). HOG's exhaustive 261120-pair
8-bit gradient audit reports a maximum orientation error of 4.151853 degrees;
its L1 normalization and approximate orientation are part of the contract.
All three have isolated synthesis evidence with zero DSP in the measured
configurations. None has board acceptance. Block motion is integer exhaustive
SAD, not subpixel optical flow; temporal median uses only prior completed frames
and requires full warmup after reset or malformed-frame recovery.

Integrated checkpoint: [37 projects and five integration checks](evidence/image_extensions_20261018T201309Z_f568c0be/results.json),
source-bundle compilation and 82-file tracked-input stability all PASS. The
original 202 production snapshot files remain unchanged; integrated RTL hashes
and baseline verification are saved alongside the results.

The three further additions are corner NMS (114 frames / 4471 pixels, including
actual FAST9-to-NMS RTL), programmable plain BRIEF (90 descriptors, atomic
patterns and bounded geometry checks), and quantized Sauvola (88 frames / 1485
pixels, nine invalid-parameter checks). All have independent numerical tests
and isolated synthesis evidence with zero DSP in measured configurations.
BRIEF expects upstream smoothing and is not OpenCV bit-compatible. Sauvola
reports its real-formula quantization error, including one differing binary
decision in the tested fixtures; it does not claim float equivalence. These
extensions have not been programmed or accepted on the board.

Integrated checkpoint: [40 projects and six integration checks](evidence/image_extensions_20261018T202721Z_82f91d5f/results.json),
complete source-bundle compilation and 137-file tracked-input stability PASS.
All 202 original production snapshot files remain unchanged. The evidence
directory contains integrated RTL hashes and the baseline verification.

The new descriptor matcher passes 168 transactions / 686 query results and
actual BRIEF-to-matcher RTL checks at both descriptor lengths. Zhang–Suen
thinning passes 63 frames / 2187 pixels, including explicit nonconvergence at
iteration limits. Histogram specification passes 56 frames / 664 output pixels
and 51200 LUT entries. Cross-review found and fixed a pending-reference-update
deadlock during partial capture; its directed regression holds the update
request through capture, computation, output and DONE until the next boundary.
All three have isolated synthesis/check evidence with zero DSP in measured
configurations. None has board acceptance.

An additional integration check drives the same actual pixels through FAST9,
corner NMS and BRIEF RTL over 14 frames / 44 descriptors with CE pauses,
backpressure, no-corner frames and multi-frame reuse. The independent oracle
derives corner locations and descriptor bits directly from the input pixels.
Zhang–Suen explicit deletion rules are not bit-compatible with every library
LUT variant; histogram matching uses discrete CDF nearest candidates rather
than scikit-image's interpolated values. Their documented differences remain
part of the algorithm contracts.

Integrated checkpoint: [43 projects and seven integration checks](evidence/image_extensions_20261018T204152Z_0fc590ed/results.json),
complete source-bundle compilation and 149-file tracked-input stability PASS.
All 202 original production snapshot files remain unchanged. Integrated RTL
hashes and baseline verification are saved alongside the results.

Binary hole filling adds 80 frames / 2110 pixels checked with independent BFS
and SciPy, including full-capacity queues and diagonal 4/8-connectivity cases.
Block motion compensation adds 120 frames / 2808 pixels, a real estimation-to-
compensation RTL chain (three frames / 27 vectors / 105 pixels), 131070 large-
coordinate outputs and a 65536-pixel capacity check. GLCM adds 48 frames / 98304
matrix counts / 192 exact feature records, with actual scikit-image matrix and
normalized-feature comparisons. All three have isolated synthesis/check results
with zero DSP in measured configurations; no board acceptance is implied.

The new hole-fill-to-connected-components integration checks 42 actual RTL
frames / 1582 filled pixels and labels / 108 component areas and bounding boxes.
Its independent raw-mask oracle also passes 60 SciPy fill/label comparisons.
Background and foreground use dual connectivity, with explicit diagonal leaks,
no-hole masks, multi-frame reuse, thin images, CE pauses and backpressure.
GLCM's energy numerator divided by its denominator is ASM; standard energy is
the square root of that quotient. Zero-pair normalization remains undefined
and is explicitly flagged. Motion compensation is integer backward warping,
not subpixel interpolation or motion estimation itself.

The next three additions provide exact squared Euclidean EDT (115 frames /
4279 outputs, including 102 actual SciPy numeric comparisons), raw spatial
moments with hardware centroid (176 frames / 273186 pixels and 176 OpenCV
audits), and grayscale morphological reconstruction (150 frames / 2675 pixels,
including 122 converged scikit-image comparisons). Each has independent
numerical regression and isolated synthesis/CHECK evidence with zero DSP in
the measured configurations. No board acceptance is implied.

EDT uses zero pixels as features, exact separable squared distances and a
lowest-raster nearest-feature tie rule. No-feature frames explicitly return
invalid rather than adopting SciPy's implicit outside-feature behavior. Spatial
moments are exact unsigned raw moments through order two; centroid is floored
Q16.16 and empty support is explicit. These are not central moments or Hu
invariants. Morphological reconstruction implements simultaneous grayscale
dilation/erosion under a mask, with first-pair operation/connectivity snapshots,
explicit illegal ordering, bounded iteration and nonconvergence status.

The hole-fill-to-moments integration feeds actual filled binary pixels into the
hardware moments module across 42 frames / 1582 pixels and checks all six raw
moments, Q16.16 centroid and zero-weight status against a raw-mask oracle.
It covers both connectivities, no-hole/fully filled/empty masks, thin geometry,
multi-frame reuse, CE pauses and downstream backpressure.

Latest integrated checkpoint: [46 projects and eight integration checks](evidence/image_extensions_20261018T205652Z_3a0875f2/results.json),
complete source-bundle compilation and 159-file tracked-input stability all
PASS. All 202 original production snapshot files were checked unchanged both
during integration and after the complete regression. The same evidence
directory records the 46 integrated RTL hashes, production baseline checks
and compact integration summary. This remains simulation/synthesis evidence
for the extensions, separate from the original 48-core board acceptance.


## Integrated checkpoint: 49 projects, 9 integration checks

Evidence: `evidence/image_extensions_20261018T212613Z_32bc588b/results.json`.
All 49 extension projects and all nine integration checks pass in one frozen
run. The complete 50-file RTL bundle compiles together. The post-run audit
verifies all 171 tracked inputs unchanged, including the checked-in Retinex
ROM; all 202 original production baseline files remain unchanged.
`integrated_source_sha256.json` and `production_baseline_check.json` bind the
checkpoint to these sources. The runner now includes companion `.hex` and
`.mem` inputs, and its provenance regression detects a modified ROM.

This batch adds three projects (four RTL modules):

- Dense Lucas-Kanade: 161 paired frames, 15069 output records, 4187 valid
  vectors and 13 explicit range rejections checked against arbitrary-precision
  normal equations. Eight actual one-pixel translation fixtures have median
  displacement errors below 0.11 pixel. It is a single-scale, single-linearization
  estimator, with no large-motion, pyramidal or iterative-flow claim. Separate
  boundary evidence, `evidence/optical_flow_boundaries_20261018T212959Z_7539f163`,
  also verifies FRAC=0/16, OUT_BITS=32 and narrow-output overflow rejection.
- Binary mask RLE: 63 complete frames, 631845 pixels and 115196 canonical
  runs through the actual RTL encoder/decoder, including 65535-pixel runs.
  Thirteen malformed-token cases report explicit errors and recover after
  acknowledgement. This is a custom row-bounded token interface, not a BMP
  or byte-stream RLE file format. A partial errored frame must be discarded.
- Grayscale single-scale Retinex: 154 frames, 4840 outputs, all 4096 log-ROM
  entries audited independently with high-precision Decimal and inspected in
  actual RTL ROM; the binomial surround also matches actual OpenCV filtering.
  The 5x5 binomial surround is rounded to integer before the log lookup. Against
  an unrounded floating surround, low-light fixtures show up to 0.41504 log2
  units or 13.2812 mapped intensity units of error for tested gains. Log-only
  quantization contributes at most 0.003854 to the raw difference in those
  fixtures. This is a documented quantized SSR variant, not MSR/MSRCR.

The new actual hole-fill -> RLE encoder -> decoder -> moments integration
checks 64 frames, 1824 reconstructed pixels, 772 exact maximal runs and all
six moments plus Q16 centroids. Raw masks independently determine expected
filled pixels; the codec output is checked pixel by pixel. Tests cover dual
4/8 background connectivity, rings, diagonal leaks, checkerboards, single-pixel
and thin images, CE pauses, backpressure and multi-frame reuse.

All three projects have isolated Gowin synthesis/check evidence. Optical flow
uses 3117/4845 LUT for the measured 8/12-bit 16x16 configurations; Retinex uses
790/856 LUT at measured 9x7 configurations. RLE is a streaming FF implementation
with no frame RAM. All measured configurations use zero DSP. These results
are per-core synthesis evidence, not simultaneous device occupancy or routed
throughput. No extension project in this checkpoint has board acceptance.
All generated vectors and simulation/synthesis intermediates use temporary
directories; only compact logs, small fixtures and reviewable reports remain.


## Integrated checkpoint: 52 projects, 10 integration checks

Evidence: `evidence/image_extensions_20261018T214615Z_ad02c980/results.json`.
All 52 projects, ten integration checks and the complete 53-file RTL bundle
pass in one frozen run. All 182 tracked inputs remained unchanged, including
the watershed protocol test and mathematical ROM inputs. The final independent
audit also verifies all 202 production baseline files unchanged. Source bindings
and the audit are saved as `integrated_source_sha256.json` and
`production_baseline_check.json` in that evidence directory.

This checkpoint adds three functional projects:

- Floyd-Steinberg error diffusion: 198 frames / 9438 pixels across 8/10/12-bit
  inputs, multiple output bit depths, identity quantization and both traversal
  modes. It uses Q4 signed error, 7/3/5/1 over 16 weights, round-to-nearest
  ties-away contributions, half-up quantization/reconstruction, corrected-value
  clipping and discarded out-of-bounds contributions. Serpentine traversal is
  internal; input and output remain raster. Its equations intentionally differ
  from Pillow's internal implementation; no Pillow bit-exact claim is made.
- Field-to-progressive deinterlacing: 448 field-group fixtures / 6784 output
  pixels, including 1142 BOB-selected pixels and ten synthetic comb-pattern
  mode differences. WEAVE combines paired spatial lines; BOB preserves the
  temporally newer field and interpolates missing lines with half-up averaging
  and replicated boundaries. Adaptive mode selects BOB at a missing pixel
  when its older-field sample differs from that estimate by more than the
  threshold. This can mistake static vertical detail for motion and is neither
  motion-compensated interpolation nor FFmpeg bwdif. Odd heights and the
  single-top-field HEIGHT=1 case have explicit contracts and tests.
- Marker-controlled watershed: 132 frames / 2288 exact label records against
  an independent heapq oracle, plus reset/recovery tests at five CE=0 stages.
  Actual scikit-image 0.25.2 matches 99 legal frames; 15 legal tied-elevation
  cases differ under the documented deterministic initial-seed raster tie
  rule. Other frames exercise explicit errors rather than comparison with
  skimage. All seeds reserve their labels before flooding; discovery assigns
  labels at enqueue. The queue key uses raw elevation then discovery age,
  not a minimax water level. No watershed lines are emitted. Unseeded masked
  components stay label zero/invalid. Capacity is 4096 pixels per tile, with
  synchronous RAM and O(N-squared) serial queue selection; no video-rate or
  full-resolution throughput claim is made. A separate algorithm-only audit
  passes 100 unique-elevation heapq-versus-skimage cases in
  `evidence/watershed_reference_audit_20261018T214059Z_a419a4e2`.

The new actual fields -> deinterlacer -> diffusion -> binary RLE encoder ->
decoder -> spatial moments chain checks 60 frames / 1512 pixels, every
progressive sample, every dithered code/reconstructed intensity, every decoded
pixel and six raw moments plus Q16 centroids. It covers all three deinterlace
modes, temporal field orders, serpentine settings, odd/even/thin/single-pixel
geometry, CE pauses and backpressure. Evidence:
`evidence/deinterlace_diffusion_20261018T215506Z_28ed1342/results.json`.
Per-profile frame-mean intensity error is recorded rather than assumed zero.
The one-pixel 128-to-255 binary quantization fixture has normalized frame-mean
error 127/255 = 0.49804; diffusion cannot preserve a single pixel's average
when outside weights are discarded. Larger-image visual quality is not signed
off by these numerical tests.

Measured isolated synthesis/checks pass with zero DSP: diffusion 1378/1757 LUT
for 9x7 B8/O1 and B12/O4; deinterlacing 271/319 LUT for 16x12 B8/B12;
watershed 354/394 LUT plus 164/196 ALU for 32x32 B8 and 64x64 B12. These are
per-core synthesis configurations, not combined resource or routed timing
claims. All new simulation vectors, executables and synthesis intermediates
were temporary and cleaned; compact evidence and baseline artifacts remain.
None of these extension projects has board acceptance.

## Verified geometry and contour checkpoint: 55 projects

The complete regression now passes 55 projects, 12 integration checks and a
56-file RTL bundle compile. All 194 tracked test inputs stayed unchanged,
and all 202 original production baseline files retain their board-tested hashes.
Authoritative evidence:
`evidence/image_extensions_20261018T222542Z_bfd66a73/results.json`, with adjacent
`tested_input_sha256.json`, `integrated_source_sha256.json` and
`production_baseline_check.json`.

New hardware functions and their independent evidence:

- Brown–Conrady mapping: 49 frames / 1715 coordinates, staged saturating
  fixed-point oracle, configuration errors, CE, backpressure and reset.
  Actual OpenCV map comparison gives maximum error 0.000451446 pixels on
  46 bounded frames. Serial shared arithmetic takes about 560 enabled cycles
  per coordinate; this is not a full-rate video pipeline.
- Affine RANSAC: 36 complete RTL results / 720 hypotheses, signed16 coordinates,
  FRAC 0/8/16, deterministic replay, outliers, degenerate inputs and explicit
  errors. Actual NumPy/OpenCV comparisons cover translation, rotation and
  scale/shear. Consensus uses inclusive QFRAC L1 residuals, a fixed hypothesis
  budget and no refinement; general OpenCV equivalence is not claimed.
- Complete contours: 895 frames / 12989 pixels / 14468 edges / 2026 closed
  loops / 52 holes, independent edge geometry and actual skimage FG4/Euler
  audit. Pixel-cell edges, FG4/BG8 and signed polygon area are explicit;
  these are not OpenCV pixel-center contours or a hierarchy output.

Two real RTL integrations are included in this complete run:

- Hole fill -> contours: 120 frames / 2520 pixels / 1786 edges / 206 loops,
  independent BFS and actual SciPy fill, exact exposed-edge coverage,
  continuity, closure, shoelace area and skimage topology checks.
- Lens map -> existing production bilinear sampler: 26 frames / 910 pixels,
  2312 exact memory-read addresses, 332 border pixels, 34 overflow pixels and
  518 fractional samples, randomized CE/request/response/output stalls.
  The adapter truncates Q16 to Q8 and uses border fill on OOB or overflow.
  The production sampler is read-only and explicitly included in the complete
  run's tracked inputs although it is outside the extension RTL source list.

Isolated synthesis/checks use zero DSP: lens mapper 3345 LUT plus 298 MUX5,
1053 FF; affine estimator 5472–5721 LUT, 1912–2006 FF for its tested profiles;
contours 570–635 LUT plus 285–314 ALU for 32-square/64-square tiles.
These are independent synthesis results, not combined fitting or routed timing.
New temporary builds were cleaned; the extension library remains simulation
validated and is separate from the original 48 board-accepted entries.

## Verified motion and chromatic checkpoint: 58 projects

Authoritative complete-run evidence:
`evidence/image_extensions_20261018T224907Z_3daa2639/results.json`.
All 58 project regressions and 13 integration checks pass, together with
the complete source-bundle compile. All 205 tracked inputs stayed unchanged.
The bundle contains 59 extension RTL files plus one unchanged production
dependency, `image/geometry/rtl/img_geo_frame_sampler.v`, required by the RGB
correction top. It is not counted as a newly developed project.
Adjacent integrated-source hashes, production-baseline check and cleanup check
bind this checkpoint to its actual inputs. All 202 production baseline files
remain unchanged; the original 48 board-accepted entries are separate.

New functions:

- Pyramidal iterative LK: paired synchronous Gaussian pyramids, 2/3 levels,
  coarse-flow bilinear upsampling, current-image warping and 1..4 local
  iterations in hardware. Supports odd 8..32-pixel dimensions, grayscale B8,
  3/5 windows and signed16 Q4 flow. Full integer regression checks 1932 output
  vectors, malformed-frame recovery and saturation. Directed tests cover
  seven CE-disabled reset phases, extra SOF/internal EOL errors, MAX_STEP=128
  and determinant equal to threshold. A real 32x32 RTL fixture with translation
  (4,2) matches every vector; valid central flow median endpoint error is
  0 pixels, P95 0.088388 pixels. The same single-scale solver's central median
  error is 4.521645 pixels on that fixture. These bounded results are not a
  general optical-flow accuracy or throughput guarantee.
- General affine stabilization: all six coefficients participate in cumulative
  trajectory, causal coefficient EMA, hardware inverse and correction matrices.
  332 complete RTL results pass, including a 100-frame mixed-transform path,
  random affine inputs, near-singular EMA, overflow and state rollback.
  Actual NumPy comparison gives maximum trajectory matrix error 0.001231227
  and tested inverse-warp point error 0.003168879 pixels. This is a matrix
  controller; downstream sampling/cropping is required for stabilized pixels.
- RGB lateral chromatic correction: independently calibrated radial red/blue
  maps, full RGB frame RAM and actual hardware bilinear sampling, with green
  preserved. Exact integer oracle checks 60 frames / 1356 RGB pixels over
  B8/B10/B12, including thin/odd/single-pixel tiles, invalid configuration,
  frame-atomic updates, errors, CE and reset. Actual OpenCV comparisons cover
  1461 in-domain channel samples; maximum differences are 2/3/18 LSB for
  the tested B8/B10/B12 profiles, reflecting different interpolation precision.
  Conservative mapper intermediate overflow is explicitly flagged and uses
  border fill, even if the final ideal radial coordinates would be in range.

The new actual RANSAC -> stabilizer integration checks nine frame matrices,
216 point matches and 432 hypotheses with six outliers per frame. Exact
Fraction/Gauss-Jordan geometry checks noncommuting translation/rotation/shear/
scale, EMA, scene cuts and low-inlier rejection, plus CE/backpressure stability.
The Q8-to-Q16 fixture adapter explicitly range-checks its representable models;
this is not a general-purpose conversion bridge claim.

Independent synthesis/CHECK passes, all zero DSP: pyramidal LK 2802/2952 LUT
plus 2640/2824 ALU and 4/6 RAM for 16x16 and 31x32; stabilization 7789 LUT,
608 MUX5, 2982 FF; complete chromatic-correction hierarchy 5471/6038 LUT,
401/393 MUX5, 2104/2220 FF for 9x7 B8/B12. These are individual tested
configurations, not a combined board fit or routed timing result. New build
temporaries were removed. None of this extension checkpoint claims board,
full-resolution video or general image-quality acceptance.
