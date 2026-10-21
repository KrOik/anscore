# Complete Lab color frame quantizer

`lab_kmeans_quantizer.sv` converts RGB888 to D65 encoded Lab, performs full
integer Lloyd clustering on the stored frame, then converts the selected
cluster centers back to RGB for every output pixel. The hardware reuses one
CIELAB converter for the two frame passes. It contains the real converter,
frame RAM, clustering arithmetic and inverse converter path.

WIDTH and HEIGHT are compile-time positive dimensions; total capacity is
1024 pixels. START atomically passes K (2..4), maximum iterations (1..255),
center-movement tolerance (0..255) and seed to the clustering engine. Supply
exactly WIDTH*HEIGHT pixels with SOF on the first pixel and EOL on each row
end. Output RGB, cluster label and generated SOF/EOL/last remain stable under
backpressure. Every transfer requires CE and valid/ready. Completion is held
until `done_ready`. CE-disabled reset clears control and allows a new frame.

The nonlinear ROM parameters DECODE_FILE and NONLINEAR_FILE default to
`decode.mem` and `nonlinear.mem`. Set them to the two supplied tables from
`../cielab_color/` or place those exact files in the simulation/synthesis
working directory. Tests copy the tables into automatically cleaned temporary
directories and freeze their hashes.

Distance is squared Euclidean in OpenCV-style **encoded Lab8**, where L is
scaled to 0..255 and a/b have offset128. This is not unscaled CIE DeltaE.
Statistics and initial/final centers retain this Lab8 encoding. Empty clusters
retain their previous centers and ties choose the lowest cluster ID. See the
clustering module for exact seeded sample initialization and rounding rules.
Color conversion and quantization are lossy; general image-quality or
real-time video performance is not claimed.

On failure, discard the complete output frame, including any pixels already
received. Error0x10 OR the Lab marker bitmask reports source framing errors;
0x20 OR the clustering code reports its errors (0x21 invalid configuration).
Abort reports0x93 and illegal parent state0x94. FAILED holds the error and
resets both children. After acknowledging FAILED, the next START can run a
complete new frame without an external reset. Statistics are invalid on
failure. Abort after successful completion does not rewrite the held result.

From repository root:

```powershell
python -B cores/system/common_scaffold/integration/test_lab_kmeans_quantizer.py
python -B cores/system/common_scaffold/image/lab_kmeans_quantizer/test_errors.py
python -B cores/system/common_scaffold/image/lab_kmeans_quantizer/synth.py
```

The normal test checks ten complete real RTL frames across1x1,7x5,16x9,32x32
against an independent Lloyd implementation composed with the independently
tested Lab integer reference. It compares every RGB/label/marker and all
initial/final centers, counts, inertia, iteration and convergence statistics.
Inputs include constant colors producing empty clusters, random images and
spatial gradients, plus runtime configuration changes, CE, backpressure and
held completion. Timestamped reports reside in `../../evidence/`.
No board acceptance or routed timing claim is made.

Fourteen additional healthy recovery frames pass after malformed markers,
invalid K/iteration configuration, abort during capture/clustering/held output,
and six CE-disabled reset phases. Every recovered RGB/label/marker and all
statistics match the composed oracle. FAILED/ACK recovery and abort during
held successful DONE are covered.

Full hierarchy isolated synthesis/CHECK passes at7x5 and32x32:
5232/5152 LUT,549/481 MUX,1715/1691 FF and zero DSP. ROMs use eight SPX9;
frame storage adds18 RAM16SDP4 / two DPX9B, respectively. These are individual
synthesis configurations, with no routed timing evidence.
