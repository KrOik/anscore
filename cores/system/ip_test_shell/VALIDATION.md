# Validation

`logic_probe8` simulation passed 1024 cases covering all eight page values,
random observed inputs, asynchronous reset and registered output isolation.

From repository root:

```powershell
. ./scripts/env.ps1
iverilog -g2012 -s tb_logic_probe8 -o artifacts/ip_test_shell_25k/tb_logic_probe8.vvp cores/system/ip_test_shell/rtl/logic_probe8.v cores/system/ip_test_shell/tb/tb_logic_probe8.v
vvp artifacts/ip_test_shell_25k/tb_logic_probe8.vvp
```

Result: `PASS logic_probe8 1024 page/isolation cases`.
No synthesis or board qualification yet; no resource figure claimed.
Production hybrid RTL/scripts unchanged; hybrid regression not applicable.

## Packet width adaptation

`python cores/system/ip_test_shell/tools/test_width_adapter.py` passed all 16
ordered width pairs across 8/16/24/32 bits, each with 128 packets. Golden is a
Python list of qualified bytes, independently regrouped into output words.
Coverage includes every keep mask on short packets, seeded random longer
packets, empty TLAST, and downstream stall stability assertions.

Evidence: `../../artifacts/ip_test_shell_25k/width_20261020T143418769455Z/summary.json`.
Default 32->24 synthesis passed with 0 CHECK issues; see PPA_25K.csv. No routed
Fmax or board throughput claim is made. The isolated module port count exceeds
available GPIO and must be routed inside a reference top, not pin-mapped alone.

## Four-source composition

`python cores/system/ip_test_shell/tools/test_fabric.py` passed three clock
ratios: source/destination half periods 5/7, 7/5 and 5/11 ns. These are
simulation settings, not measured hardware operating frequencies.
Each case checks 256 packets (64 per source), 7660 bytes, lengths 0..60,
packet-constant metadata, per-source order, frame locking, every qualified
output byte, last/keep, long/random stalls, zero drops and no trailing outputs.
Three unrelated clocks/seeds exercise both faster and slower consumers.
This is digital CDC simulation, not analog metastability qualification.

Evidence: `../../artifacts/ip_test_shell_25k/fabric_20261020T144029066571Z/summary.json`.
Canonical frame_switch4, width_converter and packet_async_fifo are instantiated
unchanged. Default FIFO depth is 32 output words (96 payload bytes), one packet
in flight. Larger packets use the FIFO's atomic discard behavior; that path
is not covered by this normal-traffic integration regression.

Fault regression now separately covers a depth-4 FIFO at all three clock
ratios: atomic discard of 24-byte oversize packet; exact-capacity 12-byte
packet; asynchronous reset with a complete packet stalled at output; and a
7-byte recovery packet with no old or trailing output. Counters are verified
before/after reset. All passed alongside the normal-traffic suite.
Latest combined evidence:
`../../artifacts/ip_test_shell_25k/fabric_20261020T144201086607Z/summary.json`.
Digital reset tests do not prove reset recovery/removal timing or metastability
behavior. Domain-specific synchronized reset release remains an integration gate.

Composition synthesis passed CHECK (0 problems): 329 LUT1..4, 98 ALU,
223 DFFCE, one SDPX9B, zero DSP. Three RTL warnings only expand tiny owner/rr
arbitration arrays into registers. No coefficient memories are involved.
This module has 293 port bits and needs an internal board test top for P&R;
there is no routed timing or physical acceptance claim yet.

## CSR endpoint

`python cores/system/ip_test_shell/tools/test_components.py` passed probe
regression and CSR regression (27 directed transactions, eight consecutive
consume/replace cycles, reset with pending response). Tests check byte strobes,
range/alignment/unknown-address errors, busy write guards, live probe selection,
start pulse count, read snapshots and response stability under backpressure.
Evidence:
`../../artifacts/ip_test_shell_25k/components_20261020T144423892985Z/summary.json`.
CSR is transport-neutral; no UART/JTAG hardware success is inferred.

## AXI-Lite control path

Bridge + real CSR endpoint passed 35 writes and 68 reads: independently delayed
AW/W in both orders, concurrent reads/writes, partial strobes, invalid accesses,
B/R response backpressure, CSR backend stalls and reset with an unpaired AW.
Backend request stability is asserted. A discovered read-side unused-data
stability failure was fixed; failing evidence remains preserved.
Latest complete component evidence:
`../../artifacts/ip_test_shell_25k/components_20261020T144844750640Z/summary.json`.
The four-slave interconnect and board transport are not yet in this regression.

## Runtime-controlled integrated core

`python cores/system/ip_test_shell/tools/test_replay_runner.py` passes the
runner and integrated CSR core. Three runtime cases (seed/length/mask:
18/7/0, 189/63/0x33333333, 255/256/0x55555555) run without external reset.
Complete CSR readback verifies 440 trace words and 1304 payload bytes, including
source order, packet boundaries and byte values. CRC results 1d13cecd,
b04bcafd and 72c300ea match independent Python zlib golden calculations.
Runner invalid-length and permanent-stall timeout paths pass separately.
Latest source-bound evidence:
`../../artifacts/ip_test_shell_25k/replay_20261020T145434162081Z/summary.json`.

Core synthesis passes: 1246 LUT1..4, 946 ALU, 674 FF, 2 SDPX9B, zero DSP.
This remains synthesis-only; no routed Fmax or board result is implied.
The generated-input tests do not satisfy the work order's physical runtime
JTAG stimulus loading gate. The new core is ready for transport integration.

Host-loaded CSR RAM wrapper: component regression components_20261020T152714530662Z PASS, all six suites. Three loaded datasets / 24 complete response words, invalid lengths/indices, partial writes, busy guards, response and stream stalls, timeout/reset recovery. Isolated synthesis PASS: capture_synth_20261020T232748210. No physical acceptance for this new endpoint. See CAPTURE_REPLAY.md.

Integrated host-loaded fabric: replay_20261020T154344672941Z PASS, 3/31/256
words (290 total) complete readback, independent Python golden and CRCs
A1943F39 / ADB69DC0 / 0B6EEDFF. Actual keep/user/last checked; zero packet
drops; response selection held when request address changes under stalls.
Original generated three-case regression / 440 trace words preserved.
Six component suites PASS: components_20261020T154317477064Z.
25K route/pack PASS: board_20261020T154348294344Z; physical 3564 LUT4,
1442 FF, 10/56 BSRAM, 0 DSP, 11 IOB, 0 PLL; reported Fmax93.24MHz, PASS50MHz.
No download/physical L3 acceptance for this image. See BOARD_STATUS.md.

Scan mailbox: scan_20261020T155253230058Z PASS. TCK periods6/14/46ns vs system10ns, 52 complete independent codec-checked transactions each; malformed/busy/stall/error/reset/snapshot tests. End-to-end serial scan into real CSR/fabric passes three datasets/290 full words and Python golden CRCs. Isolated GW5A synthesis PASS482 LUT1..4/276FF/14ALU/0DSP/0BSRAM. No physical JTAG or physical CDC qualification; see SCAN_PROTOCOL.md.

Video codec plus actual packet fabric: video_codec_20261020T160148949646Z PASS.
Each path checks 384007 RGB pixels / 723 lines (1x1,3x2,320x240,640x480),
SOF/EOL/frame ID/config latching under randomized backpressure; composed path
uses 24/32 adaptation, canonical switch source0,32/24 and FIFO1024. Zero drops.
Codec-only continuous128 pixels at II1; this is not whole-fabric II1 or board
frame-rate acceptance. Error cases include SOF/EOL/zero width/keep/metadata.
Isolated GW5A synthesis PASS: packetizer141 LUT1..4/96ALU/100FF;
depacketizer13 LUT1..4/44FF; no DSP/BSRAM, no P&R or physical video claims.
Evidence video_codec_synth_20261021T000158084. See video_stream_contract.md.
