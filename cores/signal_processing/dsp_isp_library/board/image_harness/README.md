# Full-frame UART qualification harness

This separate harness loads an externally supplied 8×8 RGB frame, replays all
64 words into the production four-stage CSC→morphology chain, stores every result
and exports it with actual output SOF/EOL. It does not modify block_harness or
run_block_board.py. This directory's scripts never access board devices.

Input/output stores reuse the read-only explicit `block_ram` implementation
(two 18-bit DPX9B blocks per 32-bit store). Synchronous reads have explicit prefetch;
RAM is not reset. Capture, replay and export are separate phases. The grayscale
morphology windows still use their shared inferred memories and require physical
qualification. Input SOF is pixel0; EOL is every pixel index congruent to7 modulo8.

Request (little-endian) is `IMG1`, tag:u32, config:u32, count:u8 (must be64),
stall:u8 (0..7), then 64 RGB:u32 words. Config fields are documented in the chain
README. A response is `IMR1`, echoed tag/config, count:u8, flags:u8, accepted-input
count:u8, accepted-output count:u8, replay-cycles:u32, then count result:u32 words.
Normal response is exactly276 bytes. Result bits31/30 are actual SOF/EOL; bits
BITS−1:0 are grayscale/binary pixels, other payload bits zero.

Flags: bit0 bad count/stall, bit1 RX framing error, bit2 unexpected busy RX
(sticky through later packets), bit3 illegal config, bit4 replay watchdog,
bit5 stream marker error. Invalid length/config returns a20-byte response with
zero processed outputs. Partial requests wait indefinitely; arbitrary corrupted
streams are not automatically resynchronized. Host must wait for a full response.
The watchdog is16384 replay clocks; its fault response includes an output accepted
on the same edge. No flash or device programming is performed here.

Replay phase increments modulo8; sink ready is `phase>=stall`. Replay-cycles
records RUN clocks, including pipeline fill, row pauses, backpressure and drain.
Numerical verification checks exact count, identity/config/flags, all pixels and
SOF/EOL. Cycle counts are observed performance measurements with a legal bound,
not an independently predicted exact-cycle host oracle. UART loading/export time
is separate and must not be described as target-clock pixel throughput.

Commands from root:

```sh
python cores/signal_processing/dsp_isp_library/board/image_harness/run.py --bits 8 --padding 1 --build
python cores/signal_processing/dsp_isp_library/board/image_harness/run.py --bits 10 --padding 1 --build
python cores/signal_processing/dsp_isp_library/board/image_harness/host.py prepare --bits 8 --config 0x3fec --output <fresh-dir>
python cores/signal_processing/dsp_isp_library/board/image_harness/host.py verify --expected <expected.json> --decoded <complete-decoded.bin>
```

`host.py prepare` creates a fresh nonce/tag and random external frame before
oracle computation; it never reads a DUT result to build expected values.
The main agent owns JTAG SRAM programming, capture and repeat-programming checks.
Do not use the block-harness board runner unchanged: magic, fixed frame count,
config meaning, model and performance contract differ.

Build execution snapshots production RTL and models, runs real serial-line
simulation, checks sixteen complete frames plus five illegal packets and160
checker mutations, then permits noalu Gowin synthesis, 27MHz place/route and
packing only if LUT<=15000 and DSP<=4. Timing and image SHA-256 are recorded.
Future builds reject latch, combinational-loop and missing/unconstrained-clock
diagnostics before packing. See `RETIREMENTS.md` for two withdrawn historical
images and the retained physical failure; a simulation pass does not resolve it.
No physical acceptance is claimed by BUILD_PASS_NOT_BOARD. Raw simulation,
failed runs and prior build outputs remain preserved in fresh directories.

Exact failed physical case replay (independent oracle recomputed from input):

```sh
python cores/signal_processing/dsp_isp_library/board/image_harness/run.py --bits 8 --padding 1 --replay-json artifacts/dsp_isp_20260925/isp_chain8_board_01/case_00/expected.json
```

This passed source RTL simulation in `evidence/image8_pad1_20260925_035713_688216`,
including all 64 pixels/markers, five invalid packets and ten checker mutations.
The saved request bytes were checked against the replay stimulus. This does not
establish the cause of the physical mismatch at pixels 16/24/32.

Corrected configuration-pending builds completed 16 full frames, five illegal
packets and 160 checker mutations each; final warning audits and SHA checks pass:

| Bits | Evidence directory | Mapped LUT | Routed LUT4 | DSP | Minimum reported MHz |
| --- | --- | ---: | ---: | ---: | ---: |
| 8 | `evidence/image8_pad1_20260925_035358_204245` | 2302 | 2362 | 0 | 116.18 |
| 10 | `evidence/image10_pad1_20260925_035413_020016` | 2669 | 2741 | 0 | 52.41 |

These jobs began before the expanded warning gate was added to the runner.
Their completed logs were separately audited using the same gate; retained
`warning_audit.json` records that supplemental check. Physical acceptance remains
pending, including replay of the previously failing external frame.
