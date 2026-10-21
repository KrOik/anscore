# Complete RAW-to-Sobel composition

`isp_sobel_pipeline.v` connects the existing RAW/BLC/Bayer/AWB/CCM/Gamma and
RGB statistics wrapper to `gray_sobel_stream.v`. All frame configuration is
accepted in a single command handshake. The grayscale conversion is the exact
integer expression `(R+2*G+B)>>2`, with a ten-bit intermediate. The Sobel
stage's command captures its bypass setting at the same handshake.

Both Bayer and Sobel crop one border pixel. A W x H RAW frame produces
(W-4) x (H-4) output bytes, including center-bypass mode. Input dimensions
smaller than 5 or wider than MAX_WIDTH return error1 without starting either
child. The existing RGB-only wrapper remains available for 3x3 input.
Statistics describe the (W-2) x (H-2) RGB image before luma/Sobel, not the
cropped final grayscale output. The original source frame ID is preserved.

The successful frame response waits for both children, including Sobel final
EOF acceptance. Statistics consumption remains independently backpressured;
the pending snapshot blocks the next command through the RGB wrapper.
If the color core fails, this wrapper waits for all accepted Sobel tokens and
pending synchronous-window processing to drain, then returns the upstream
error. Response consumption resets the partial Sobel frame. This handles a
pre-payload Gamma configuration rejection as well as a malformed partial frame.
Consumers must discard already emitted pixels on an error response. External
reset still aborts a source/consumer that stops indefinitely.

`gray_sobel_stream.drained` is a passive boundary signal: metadata empty,
no offered window, and window idle/awaiting input/responding. It does not claim
the current partial frame completed. It permits safe abort after upstream
has stopped offering pixels. Its data-path behavior is otherwise unchanged.

Commands after sourcing `scripts/env.ps1`:

```powershell
python cores/image_processing/isp_stream/tools/test_isp_sobel.py
python cores/image_processing/isp_stream/tools/test_isp_sobel_recovery.py
```

Directed evidence `sobel_recovery_20261020T175202234373Z` PASS: incomplete Gamma
configuration rejected with error8 and no output, malformed EOL with held
downstream data and no early response, clean 7x7 RAW recovery producing nine
exact center-bypass pixels, successful RGB sums625/625/625 and counts25/5,
snapshot held30cycles after response, next command blocked until consumption.
Both error and successful responses wait through explicit downstream stalls.
The test also offers LUT writes during a held invalid-dimension response;
ready must remain low because no child accepts those writes. It first exposed
the missing top-level ready gate (`sobel_recovery_20261020T175142124662Z`, FAIL),
then passed after valid/ready were gated together.

Full RAW8/10/12 golden run `isp_sobel_20261020T174734732567Z` terminal PASS:
each377317pixels/seven snapshots, independent full-image Python Bayer/color,
luma and Sobel golden, all metadata,320x240/640x480 frames,mode/config changes,
gamma reloads,source/output stalls and invalid-dimension recovery. This run
precedes the LUT-ready-only correction. Current-source full rerun
`isp_sobel_20261020T175240510760Z` terminal PASS RAW8/10/12, each377317pixels
and seven exact RGB statistics snapshots. Session94931 completed successfully.
Current-source standalone
Sobel regression `sobel_20261020T175204225742Z` PASS380669pixels covers the
new passive drained port without changing its numerical data path.
No PPA, sustained30fps or
physical25K acceptance is implied. Per-stage bypass/config CSR and probe
integration remain open alongside the other work-order gates.

Current-source isolated GW5A synthesis `sobel_synth_20261021T015223545` PASS:
6217 LUT1..4,1604ALU,3289FF,214MUX2_LUT5+1MUX2_LUT6,6SDPX9B+4SPX9 cells,
zeroDSP. This uses `-noiopads`;676portbits are internal interfaces, not board
pins. These are synthesis cells, not a physical BSRAM count or routed PPA.
The prior no-PPA limitation remains; no Fmax claim is made.
