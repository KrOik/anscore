# RGB888 / RGB565 streaming pixel converter

`rgb565_stream.sv` provides one registered, backpressurable pixel-format stage.
`PACK=1` converts 24-bit `{R8,G8,B8}` to a 16-bit RGB565 word with R in bits
15:11, G in 10:5 and B in 4:0. `PACK=0` expands the 565 word to RGB888 using
bit replication: R/B = `v*8+floor(v/4)`, G = `v*4+floor(v/16)`.
This expansion preserves both endpoints and exactly round-trips through
truncating packing. It is not gamma correction or a color-space transform.

`SWAP_BYTES=1` swaps the two bytes on the RGB565 side in either direction.
These are numeric word interfaces, not byte serializers. For memory byte
streams, choose the swap setting together with the system's byte-lane order.
The Linux [V4L2 RGB format table](https://docs.kernel.org/userspace-api/media/v4l/pixfmt-rgb.html)
documents RGB565 versus RGB565X memory byte order; it was consulted to distinguish
word bit fields from memory layout. No external implementation was copied.

`ROUND_NEAREST=0` truncates low RGB888 bits. `ROUND_NEAREST=1` rounds packing
to the nearest quantization step (8 for R/B, 4 for G), ties upwards, clamping
at the largest channel code. This option has no effect on expansion. All
parameters are static 0/1; invalid settings fail elaboration/simulation.

The common handshake is **ce && valid && ready**, sampled on the rising edge.
Both sides must share CE. Input `s_ready` is low during reset/CE pause; output
valid/payload/markers remain held during pause. Asynchronous active-low reset
aborts pending output. SOF and EOL pass with each pixel; this module neither
counts geometry nor validates frame markers. A producer must keep a pending
pixel and markers until accepted. With CE=1 and ready=1, latency is one cycle
and initiation interval is one pixel per clock, including simultaneous pop/push.

From the repository root:

```powershell
python cores/system/common_scaffold/image/rgb565/run_tests.py
python cores/system/common_scaffold/image/rgb565/synth.py
```

Six profiles pass 151552 independent expected-vector comparisons, including
every RGB565 code in each byte order and directed/random RGB888 rounding,
random CE/backpressure/source gaps, marker propagation and output stability.
Expanded colors are additionally checked for exact truncated round-trip.
Logs and source hashes are retained in unique evidence directories; generated
vectors and simulation executables are automatically removed.

Isolated Gowin synthesis and `check -assert` pass all three datapath variants:
truncating packing and expansion each use 4 LUT1..4 and 19 FF; rounded packing
uses 29 LUT1..4, 1 MUX2_LUT5 and 19 FF. No DSP or RAM is used. Bit replication
allows expanded output register bits to share FFs. No P&R/board timing or
display-interface acceptance is claimed.
