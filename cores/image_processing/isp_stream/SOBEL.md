# Grayscale Sobel stream stage

`rtl/gray_sobel_stream.v` composes unchanged canonical modules:
`img_window3x3_valid_draft`, `img_edge_sobel3x3`,
`img_edge_gradient3x3` and `img_filter_stream_register`.
It has a command-before-frame interface, ready/valid payload and response,
source frame IDs, and SOF/EOL/EOF output markers. One frame is in flight.
The window uses two synchronous row memories, not a frame buffer. Its native
input initiation interval is at least two clocks; the gradient kernel has
three elastic stages. This wrapper does not claim input II=1.

For W x H input the output is (W-2) x (H-2). Frame command latches dimensions,
ID and bypass. Both Sobel and bypass modes use the same crop: bypass returns
the center pixel. Sobel computes signed rightward Gx and downward Gy with
weights 1/2/1, then saturates `(abs(Gx)+abs(Gy)) >> MAG_SHIFT` to eight bits;
the default shift is two. Eight small metadata slots align EOF and center
pixels with the unchanged kernel. No coefficient or full-frame RAM is added.

Completion waits for the window response, final output EOF acceptance and
empty metadata. Invalid dimensions produce error1 without pixels. Window
framing errors produce error2 after draining pixels; consumers must discard
the errored frame. A source stopping mid-frame requires external timeout/reset.
Reset aborts the in-flight frame. This stage accepts grayscale bytes; RGB
luma conversion and integration into the full ISP remain separate work.

After `scripts/env.ps1`, run:

```powershell
python cores/image_processing/isp_stream/tools/test_sobel.py
```

Evidence `sobel_20261020T174452907145Z` PASS: 380669 output pixels and exact
frame IDs/SOF/EOL/EOF against independent Python convolution, source frames
7x6,320x240,640x480,3x3, randomized source gaps/output stalls, held-output
stability, alternating Sobel/center bypass, configuration pins changed after
acceptance, invalid dimensions followed by valid recovery, held responses.
The first asynchronous-response testbench failures remain preserved. The
passing test samples the ready/valid response on the rising clock edge.

No synthesis, Fmax, physical resource or sustained frame-rate claim is made
for this new wrapper. Full ISP Sobel composition, per-stage bypass, CSR/LA,
runtime control and required 25K physical acceptance remain open.
