# RGB888 video and line-packet contract v1

This contract defines the first video adapter for IP-01/IP-03. It does not
define RAW Bayer packing, an ISP algorithm or a complete frame scheduler.
`rtl/video_line_packet_codec.v` contains the encoder and decoder.

## Video side

Each accepted valid/ready transfer is one RGB888 pixel: data[23:16]=R,
data[15:8]=G, data[7:0]=B. SOF accompanies the first pixel of the frame; EOL
accompanies the final pixel of every line, including the last line. Both flags
may be true on a one-pixel first line. Blanking carries no transfer. There is
no independent EOF flag; frame extent is the configured width and height.
The 7-bit frame ID accompanies the frame and wraps modulo 128.

Data and all associated flags must remain stable while valid=1, ready=0.
All signals/configuration belong to clk. At an accepted SOF, the encoder
samples width, height and frame ID. These inputs must remain stable while that
SOF is stalled, but may change after acceptance without affecting the frame.
Dimensions are unsigned 16-bit, nonzero; practical limits depend on buffers.
No CSR or atomic-config block is embedded: the caller owns configuration CDC
and must present a coherent configuration at SOF.

## Packet side

One line is exactly one packet. Its last bit means EOL, never EOF. At the
native 24-bit port every beat has keep=0b111. Pixel byte lanes serialize B,G,R
under packet_stream_contract.md. Packet-constant user is
`{frame_id[6:0], first_line}`. first_line is one on every beat of the first line,
not a per-beat SOF pulse. The decoder reconstructs SOF only on the first beat
of a packet carrying first_line=1. Width conversion may split/merge pixel bytes;
restore 24-bit words before decoding, without modifying user or last.

The decoder checks full RGB keep and constant metadata within each line. It
does not independently check dimensions, missing/extra lines or frame sequence.
The encoder checks SOF/frame activity, nonzero geometry and expected EOL
position. Errors are sticky until reset. Malformed transfers can still be
forwarded; an error invalidates the current frame, and the enclosing system
must discard/reset/restart it. This is not an automatic frame-recovery engine.

One encoded line may be arbitrated as a packet, but line-atomic arbitration
does not preserve frame ownership across multiple video sources. Route each
decoder to one ordered video stream or add an explicit frame/source scheduler.
The eight metadata bits here have no extra source ID. The reference integration
uses only source 0 and does not claim four-camera/frame isolation.

## Buffer, reset and rate requirements

Each codec stage is one registered valid/ready slot, peak II=1 pixel/cycle
when its peer is ready. Reset is asynchronous active-low and aborts partial
frames/lines. Reset all stages of the path together; these modules do not
provide clock crossing or independent-reset recovery.

The canonical packet FIFO is store-and-forward with one whole packet in flight.
Depth must cover a complete encoded line: for native RGB888, at least width
24-bit beats. The composed simulation uses DEPTH=1024, enough for 640 pixels;
the generated-runner depth128 is NOT enough for 320/640-pixel line packets.
Its overflow behavior is covered separately by packet FIFO fault tests.

The existing byte-serial width adapters cap their internal rate at one byte
per cycle. Thus codec II=1 does not imply whole-fabric II=1 RGB pixel/cycle.
Packet buffering, arbitration, width conversion and downstream stalls reduce
system throughput further. Full-resolution simulation is not evidence of a
25K board sustaining 320x240@30 or 640x480@30; those remain IP-03 board gates.

## Verification and resources

Run `. ./scripts/env.ps1` and
`python cores/system/ip_test_shell/tools/test_video_codec.py`.
The test checks every RGB pixel, frame ID, SOF and EOL for 1x1, 3x2, 320x240
and 640x480 frames (384007 pixels/723 lines per path). It covers frame-boundary
configuration latching, random backpressure, output stability, and malformed
SOF/EOL/dimensions/keep/metadata. A separate continuous 128-pixel run checks
codec-only II=1. The composed path is encoder -> 24/32 adapter -> source0
packet switch -> 32/24 adapter -> packet FIFO1024 -> decoder, with zero drops.

Isolated GW5A synthesis: encoder141 LUT1..4/96 ALU/100 FF; decoder13 LUT1..4/
44 FF. Both use zero DSP/BSRAM. These are synthesis counts, without P&R/Fmax.
Evidence: artifacts/ip_test_shell_25k/video_codec_synth_20261021T000158084.
No physical video, continuous ISP board test or L3 acceptance is claimed.

Regression evidence: artifacts/ip_test_shell_25k/video_codec_20261020T160148949646Z.
