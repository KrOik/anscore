# 4:2:2 to 4:4:4 horizontal reconstruction

`chroma_upsample422.v` is complete standalone synthesizable RTL. It accepts
one packed `{Y_even,Cb,Y_odd,Cr}` word per two source pixels (MSB first,
BITS-bit tight fields), consistent with `dsp_isp_library/isp/chroma/SPEC.md`.
It emits `{Y,Cb,Cr}` per pixel. This is not an NV12 decoder, byte unpacker,
or arbitrary YUV layout adapter. For odd WIDTH the final Y_odd is ignored.
WIDTH and HEIGHT are static positive parameters; BITS is 8 or 10.

## Interpolation and configuration

A configuration handshake is `ce && cfg_valid && cfg_ready`. Configuration
is accepted only between frames, while idle. `cfg_siting=0` locates chroma
sample k at x=2k; `cfg_siting=1` locates it at x=2k+0.5. `cfg_linear=1`
interpolates the sampled piecewise linear signal at each integer pixel
coordinate, with replicate extension and round-half-up:

- co-sited even: C[k]; odd: (C[k]+C[k+1]+1)/2.
- centered even: (C[k-1]+3*C[k]+2)/4; odd: (3*C[k]+C[k+1]+2)/4.

`cfg_linear=0` uses the nearest chroma sample, with ties selecting the
larger coordinate (co-sited odd pixels choose C[k+1], centered pairs C[k]). Both components
use identical interpolation. Config siting 2/3 is rejected, sets sticky
`cfg_error`, and retains the whole prior configuration including linear.
Configuration signals must remain stable until accepted. A producer can
assert config while busy; it cannot change the active frame configuration.

## Stream, CE, reset and diagnostics

All transfers are `ce && valid && ready`. This CE-qualified contract must
be observed by both endpoints; this is not an ungated AXI stream adapter.
CE=0 freezes payload, sidebands, state and diagnostics; m_tvalid may remain
high during CE pause. Input ready is low during pause. On output backpressure
all output payload and markers stay stable. SOF=tuser is true exactly on the
first pair/pixel of each frame; EOL=tlast on the last pair/pixel of each row.
Geometry drives output markers, never unchecked input markers. Any accepted
incorrect SOF/EOL sets sticky `marker_error`; processing retains fixed
geometry (no implicit frame resynchronization). Synchronous active-high rst
has priority over CE, aborts the frame, clears diagnostics and restores
co-sited linear default. BRAM contents need not be reset: a whole row is
written before any row is read.

One synchronous single-read/single-write row memory stores ceil(WIDTH/2)
words. Rows are captured then replayed; capture and output do not overlap.
After the last input pair, four enabled clocks fetch the first neighborhood;
first output is valid after the fourth. First transfer can occur on the next
enabled edge. Adjacent pixels of one pair can transfer on adjacent enabled
edges. Four enabled fetch clocks separate output pairs. Thus this conservative
implementation is bounded-memory and stall-safe, not one-pixel-per-clock
continuous video. Upstream must obey ready; no blanking-rate guarantee is made.
No vertical filtering, color conversion, or inferred siting detection exists.
Packing and siting are separate metadata; see
https://docs.kernel.org/userspace-api/media/v4l/pixfmt-yuv-planar.html .

## Verification

Run from repository root:

```
python -B cores/system/common_scaffold/image/chroma_reconstruct/upsample422/test_upsample422.py
python -B cores/system/common_scaffold/image/chroma_reconstruct/upsample422/synth_upsample422.py
```

The independent Python oracle uses rational sample coordinates and edge
clamping, not RTL tap case logic. Ten configurations cover widths 1/2/3/7/8,
odd/even heights, 8/10 bits, all four siting/filter combinations, random
valid gaps, random CE and ready pauses, exact sample/marker counts, stall
stability, illegal config retained replay, malformed marker diagnostics,
and reset abort. Three illegal static parameters are rejected. 640 output
pixels pass. Temporary test binaries are held in TemporaryDirectory and
removed automatically; small JSON evidence remains beside the source.

Isolated `synth_gowin` (no family/P&R): W64 H48 B8 uses 239 LUT1-4,
129 FF, 16 RAM16SDP4, zero DSP; W1920 H1080 B10 uses 326 LUT1-4,
225 FF, 3 DPX9B, zero DSP. ALU cells and MUX5 are separately reported in
synthesis_result.json. No timing closure or board test is claimed.

