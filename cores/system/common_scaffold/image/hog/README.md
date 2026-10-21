# HOG L1 nine-bin feature variant

`hog_l1_9.v` is a synthesizable grayscale frame feature extractor. It is a HOG
variant, not OpenCV HOG or Dalal–Triggs L2-Hys. Existing classifier compatibility
must be assessed using this exact descriptor definition and training pipeline.

## Mathematical contract

Input pixels are unsigned BITS (8–12). Static WIDTH/HEIGHT are 1–4096;
CELL_W/CELL_H are 1–32; EPSILON is 1–65535. Capture the entire frame first.
Central differences use replicate extension at actual frame boundaries:
`gx=I(y,min(x+1,W-1))-I(y,max(x-1,0))`, with analogous `gy`.
Magnitude is `abs(gx)+abs(gy)`.

Unsigned orientation uses octant-linear approximation. Compute
`q=floor(576*min(abs(gx),abs(gy))/max(abs(gx),abs(gy)))` (zero gradient: zero).
First-quadrant coordinate is q when abs(gx)>=abs(gy), otherwise 1152-q.
Opposite gradient signs reflect the coordinate to 2304-coordinate; 2304 wraps
to zero. One bin interval is 256 units (20 degrees). Vote to lower and next
modulo-nine bins with integer weights magnitude*(256-fraction) and
magnitude*fraction. There is no spatial interpolation between cells.

Only complete cells vote. Trailing partial rows/columns do not vote, but their
pixels remain available as gradient neighbors of the last complete cell.
Blocks overlap with stride one cell. Each emits 36 values ordered TL, TR, BL,
BR, nine bins per cell, with blocks in raster order. For each histogram h:
`value=floor((h*65535+floor(den/2))/den)`,
`den=sum(block histograms)+EPSILON`. EPSILON uses magnitude-times-256 units.
This is L1 normalization with half-up rounding, without clipping or L2-Hys.
Frames with fewer than two complete cells on either axis emit no values and
still reach DONE.

## Streaming and implementation

Transfers occur only on `ce && valid && ready`; synchronous active-high reset
overrides CE. Input SOF must mark the first pixel and EOL every final row pixel.
Marker errors latch until the next first accepted pixel; fixed geometry still
consumes the frame. Arithmetic overflow saturates and flags arithmetic_error;
legal parameter bounds prevent overflow. Output metadata and data remain
stable under CE pause/backpressure. DONE and flags are held until done_ready.
The consumer should reject a frame whose terminal error flag is set.

Full-frame and histogram arrays use synchronous reads, without array reset.
Serial histogram clear, neighbor fetch, restoring divider and shift-add vote
multiply keep DSP use zero. Processing is frame-buffered and multi-cycle;
there is no one-pixel-per-clock throughput claim. Storage scales as
W*H*BITS plus floor(W/CW)*floor(H/CH)*9 histogram words. Not every legal
geometry fits every FPGA. Input stalls during processing and descriptor output.

## Reproduction and evidence

```
python -B cores/system/common_scaffold/image/hog/test_hog.py
python -B cores/system/common_scaffold/image/hog/synth_hog.py
```

Independent image oracle checks 84 frames and 6912 descriptor values over seven
configurations, including partial cells, no blocks, 8/10/12-bit pixels,
ramps/diagonals/random/blank, marker error, reset, CE pauses and backpressure.
Six invalid parameter cases are rejected. Exhaustive 261120 signed 8-bit
gradient pairs against math.atan2 give maximum 4.151853-degree angle error
(bound <4.16 degrees). Observed maximum descriptor difference from exact-angle
floating reference is 3422.076 Q16 units across these fixtures; these are
deliberately different mathematical models, not numerical equivalence.

Isolated synth_gowin: default 32x32/8-bit/8x8 cells maps to 678 LUT1–4,
39 LUT5 muxes, 427 ALU, 437 FF, two RAM primitives and zero DSP. The 64x48,
12-bit case maps to 790 LUT1–4, 44 LUT5 muxes, 521 ALU, 510 FF, four RAM
primitives and zero DSP. Detailed small statistics are in synthesis_result.json.
No timing closure, integrated resource budget, board or classifier acceptance
is claimed. All generated simulation and synthesis intermediates are temporary.
