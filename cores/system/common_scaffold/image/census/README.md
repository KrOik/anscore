# Census frame descriptor

`img_census_frame.sv` implements 3x3 (RADIUS=1, eight descriptor bits)
or 5x5 (RADIUS=2, 24 bits) Census descriptors on grayscale raster pixels.
Descriptor neighbors follow row-major order, omitting the center; bit zero
corresponds to the top-left neighbor. A bit is one iff
`center - neighbor > threshold`, evaluated without unsigned underflow.
Threshold zero is the strict neighbor-less-than-center Census transform.
Nonzero threshold provides an explicit intensity deadband. Equal samples
always produce zero. Hamming matching, disparity selection and stereo
rectification are separate functions and are not part of this module.

The RADIUS-wide image border emits descriptor zero with m_border=1.
Interior descriptors have m_border=0. Images too small for the selected
window emit only border descriptors. No artificial padding is used.
BITS is 8..16 inclusive. WIDTH/HEIGHT are positive, <=4096, with
WIDTH*HEIGHT<=65536. Geometry/window size are static parameters.

Input ports: s_data, s_valid/s_ready, s_sof on first pixel and s_eol at
each row end. cfg_valid/cfg_ready accepts cfg_threshold before capture
of a frame starts; configuration takes priority over input pixels and
persists until changed or reset. Reset threshold is zero.
Output m_descriptor/m_border uses m_valid/m_ready and raster m_sof/m_eol.
All transfers require ce && valid && ready. Payload/markers hold during
stalls. Active-low reset is synchronous and aborts the current transaction.
done_valid holds until done_ready is accepted. A marker mismatch sets
frame_error, discards capture, and produces no descriptor raster; discard
the remaining malformed frame, acknowledge done, then send a fresh frame.

The core captures the whole frame into synchronous RAM before serial
neighborhood reads. Storage is WIDTH*HEIGHT*BITS bits plus descriptor and
control registers. An interior output takes 2+2*descriptor_bits processing
cycles followed by its output transfer, excluding CE/ready pauses. A border
output uses two processing cycles and a transfer. This implementation does
not claim continuous camera-rate throughput or a qualified maximum clock.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/census/run_tests.py
python -B cores/system/common_scaffold/image/census/synth.py
```

Independent numerical regression: 96 frames / 4871 output descriptors,
seven profiles, both radii, 8/10/12/16-bit inputs. One-hot neighbor patterns
exercise each descriptor position, including the last neighbor, with ties,
strict threshold equality, monotonic and random images, max threshold,
thin images, randomized CE/backpressure, marker errors, recovery without
reset and reset while waiting for a result. Temporary binaries/vectors
are removed automatically. Evidence:
`../../evidence/census_20261018T190429Z_27861908`.

Default 16x16/8-bit/RADIUS=2 Gowin isolated synthesis (-noalu -nodsp):
379 LUT1..4, 36 MUX5, 174 FF, one DPX9B, zero DSP. check -assert PASS.
Evidence: `../../evidence/census_synth_20261018T190443Z_fbaf3a98`.
No board acceptance, timing signoff or stereo image-quality qualification.
