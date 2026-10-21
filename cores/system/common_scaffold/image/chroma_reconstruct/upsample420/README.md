# Tagged 4:2:0 to 4:4:4 reconstruction

`chroma_420_to_444.sv` implements real spatial chroma reconstruction, not a
placeholder or a repetition-only adapter. BITS is 8 or 10; static WIDTH and
HEIGHT must be positive. This is a frame-buffered, bounded-throughput design.

Input follows `cores/signal_processing/dsp_isp_library/isp/chroma/SPEC.md`: `{tag,A,B}`,
tag 0 = `{Y_even,Y_odd}`, tag 1 = `{Cb,Cr}`. Each even row has CW luma
beats, each odd row (and the last row if HEIGHT is odd) alternates luma and
chroma beats, CW pairs. CW=ceil(WIDTH/2), CH=ceil(HEIGHT/2). Odd-width
padding luma is ignored. EOL marks the last beat of that input row; SOF
marks the first luma beat. This tagged stream is **not NV12** or planar YUV.
Output is WIDTH*HEIGHT row-major `{Y,Cb,Cr}`, with SOF/EOL on pixel positions.
Packing alone does not identify chroma sampling phase.

Frame-atomic `cfg_mode`, `cfg_h_siting`, `cfg_v_siting` accept values 0/1.
Mode 0 is nearest, mode 1 bilinear. Siting 0 places samples on even luma
coordinates; siting 1 places them at 2*i+0.5. Reconstruction evaluates
u=(x-phase_h)/2, v=(y-phase_v)/2. Nearest ties select the greater coordinate;
bilinear uses the four surrounding samples, clamped independently to frame
edges, with one final round-to-nearest (ties up). No intermediate rounding.
For streams produced by existing chroma_420, vertical siting must be zero;
horizontal siting must match the producer. Centered vertical mode also supports
external producers with that phase. This interpolation cannot recover detail
discarded by decimation.

All handshakes require **ce && valid && ready** at the rising edge. CE is
a shared pipeline clock enable and consumers must obey it too. Output valid
and payload remain stable through CE pauses and output backpressure. Reset is
synchronous active-low and overrides CE; it discards an incomplete frame and
clears diagnostics/configuration (nearest, co-sited). Configuration is accepted
only while completely idle; cfg_valid prevents simultaneous first input.
Illegal commits pulse cfg_error without changing active fields; legal commits
pulse cfg_done. Pulses last one enabled cycle. busy includes capture and output.

marker_error is sticky until reset. Accepted tag, SOF and EOL are checked
against expected beat geometry. Malformed markers do not change memory
addressing or terminate early: the expected beat count must still be supplied.
There is no timeout or automatic resynchronization after dropped input beats.
Configuration while busy waits until idle; callers must hold it stable.

Storage is exactly 2*BITS*(CW*HEIGHT + CW*CH) bits, using synchronous
registered RAM reads without memory reset. Input capture is one beat per
enabled cycle; output begins only after full capture. First output becomes
valid 7 enabled rising edges after the last input handshake; its earliest
handshake is the following edge. Subsequent pixels have initiation interval
8 enabled cycles in the absence of stalls. Output/backpressure prevents next
frame capture; this design makes no II=1 or video-line-rate claim.

Run `python -B cores/system/common_scaffold/image/chroma_reconstruct/upsample420/test_reconstruct.py`
from repository root. The script locates local OSS tools, uses temporary
directories (automatically removed), generates independent floating spatial
and integer oracles, then simulates 16 geometries/bit-depth combinations and
8 configurations each (128 frames). Tests exercise valid gaps, ready stalls,
CE pauses, output stability, reset during capture, malformed SOF, illegal
configuration with retained-mode replay, terminal idle and invalid parameters.
`evidence.json` records the bounded coverage; no JTAG/board evidence is claimed.

`python -B .../upsample420/synth.py` performs isolated Gowin synthesis at the
default 8x6/8-bit geometry, without DSP/ALU inference; see synthesis.log.
This is not P&R or timing signoff, nor a resource guarantee for arbitrary frames.
The default mapping reports 3401 LUT1-4, 120 MUX2_LUT5, 305 FF,
12 RAM16SDP4 and zero DSP; synthesis CHECK reports zero problems.
Full-frame RAM scales with resolution and must be budgeted by the integrator.

Phase/format reference: https://docs.kernel.org/userspace-api/media/v4l/pixfmt-yuv-planar.html
and the repository chroma SPEC above. No external RTL was copied.
