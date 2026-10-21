# Four-angle discrete line Hough voting

`hough_lines4.v` is a complete binary-edge-frame Hough accumulator with a
synchronous RAM, full bin output and maximum-bin result. No equivalent
Hough voting RTL was found in the existing image/ISP directories.

## Defined geometry and quantization

Parameters WIDTH/HEIGHT=1..4096, COUNT_W=1..24. Pixel coordinates start at
top-left (x=0,y=0), x increases right and y down. Each accepted s_edge=1
casts four votes. Theta is the **line normal** angle, not the direction
along the line:

| m_theta | normal angle | exact implemented rho |
|---:|---:|---|
| 0 | 0 degrees | x |
| 1 | 45 degrees | floor(181*(x+y)/256 + 1/2) |
| 2 | 90 degrees | y |
| 3 | 135 degrees | floor(181*(y-x)/256 + 1/2) |

181/256 approximates 1/sqrt(2). Its direction ratio is exact for the two
diagonals; its norm is slightly quantized. Rho uses nearest integer with
half ties toward positive infinity, including negative rho. This precise
Q8 normal-vector definition is the numerical contract. Angle resolution is
fixed at 45 degrees; there is no arbitrary angle/precision configuration.
The standard transform is rho=x*cos(theta)+y*sin(theta), documented for
example at https://docs.opencv.org/4.x/d9/db0/tutorial_hough_lines.html .

MAXR=WIDTH+HEIGHT-2 safely bounds all implemented normals. Each angle has
BINS=2*MAXR+1 signed rho bins [-MAXR,+MAXR]. The full memory contains
4*BINS counters, total storage 4*BINS*COUNT_W bits. Degenerate 1x1 geometry
has MAXR=0 and one rho bin per angle. No vote addresses outside this derived
range. Counter additions saturate at 2^COUNT_W-1; `overflow` becomes sticky
for the current frame if an additional vote hits an already saturated bin.
A count that merely reaches its maximum does not yet signal overflow.

## Stream and RAM execution

Input s_edge/s_valid/s_ready is one binary pixel per transfer in raster
order. SOF s_sof must be true only at (0,0); s_eol must be true at every
row's last pixel. Incorrect accepted markers set marker_error but geometry
continues from counters; reset is the explicit frame-abort/resync mechanism.
Each frame consists of exactly WIDTH*HEIGHT transfers, including zero pixels.

At reset and between frames, RAM is cleared serially, one bin per enabled
clock; no bulk reset/async coefficient array is used. Input ready is low
until all bins are cleared. Zero-edge pixels can be accepted on adjacent
enabled clocks. An edge pixel triggers four serial read-modify-write votes,
each with address/read/write stages; its next input can transfer 13 enabled
clocks after acceptance when otherwise unstalled. There is no continuous
pixel-rate guarantee: upstream must obey ready. No frame storage is needed.

After the last pixel and its pending votes complete, the entire accumulator
is streamed via m_valid/m_ready, m_theta, signed m_rho and m_count, in
theta-major order and ascending rho. `m_last` marks only the final bin.
Each synchronous RAM read precedes its output valid, giving output II=2
enabled clocks absent backpressure. Bin metadata width is 2 bits for theta;
rho is signed RW=max(1,clog2(MAXR+1)+1) bits. Every bin, including zeros,
is emitted exactly once. This complete output permits external top-K/nonmax
suppression or multi-line extraction without repeating voting.

After all bins drain, peak_valid is held until peak_ready with peak_theta,
peak_rho and peak_count. The largest count wins; ties choose the smallest
theta index then smallest signed rho. Thus a blank frame returns theta=0,
rho=-MAXR,count=0 deterministically. overflow and marker_error remain stable
through peak backpressure, then clear during the next serial RAM clear.
Only after peak acknowledgment and memory clearing can a new frame start.
`busy` is high during clear/voting/output/peak and partial input frames;
it is low while ready at the next frame's first pixel.

All transfers are **ce && valid && ready**. CE=0 freezes state, counters,
RAM accesses, payload and sidebands; output valid may remain high. Input
ready is low during CE pause. Both bin and peak output remain stable under
backpressure. Active-high synchronous rst overrides CE, aborts any partial
frame/output and restarts serial clearing; RAM data is not directly reset
and cannot be read until clearing completes. Static invalid parameters are
rejected by elaboration or the module's initial guard.

## Verification and isolated resources

```
python -B cores/system/common_scaffold/image/hough_lines/test_hough_lines.py
python -B cores/system/common_scaffold/image/hough_lines/synth_hough_lines.py
```

The independent Python oracle evaluates dot products with exact rational
normal vectors, rounds signed coordinates mathematically, then builds a
coordinate-keyed voting dictionary and selects its maximum. Seven configs
cover 1x1, single row/column, odd/non-square and even frames. Eight frames
per config include blank, vertical/horizontal/diagonal lines, multiple
boundary lines, random edges, all edges and reset-aborted data followed by
a clean blank frame. All **3168 bins and 56 peaks** are checked, including
COUNT_W=1/2 saturation and flags. Random CE/input gaps/bin backpressure,
held peak output, independently malformed SOF/EOL, reset clearing and five
illegal static parameters are covered. Temporary binaries and fixtures are
automatically deleted; small JSON results remain here.

Isolated synth_gowin, no family/P&R:

| WIDTH x HEIGHT / COUNT_W | LUT1-4 | ALU | FF | DSP | BRAM |
|---|---:|---:|---:|---|---|
| 64x48 / 16 | 223 | 113 | 103 | 1 MULT9X9 | 1 DPX9B |
| 640x480 / 16 | 414 | 170 | 141 | 1 MULT9X9 | 9 DPX9B |

MUX5 counts are separately recorded in synthesis_result.json. RAM demand
grows with WIDTH+HEIGHT and COUNT_W; accepted parameter bounds are arithmetic
bounds, not a promise that every combination fits a particular FPGA. No
P&R/timing closure, board validation, subpixel line fitting or arbitrary-angle
Hough transform is claimed.
