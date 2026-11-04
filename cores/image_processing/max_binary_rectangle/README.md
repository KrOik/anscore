# Exact largest all-foreground rectangle

`max_binary_rectangle` receives a binary raster and returns the maximum-area
axis-aligned rectangle containing only foreground pixels. Its inclusive
zero-based bounds are `(xmin,ymin,xmax,ymax)`. For equal areas the winner is the
lexicographically smallest `(ymin,xmin,ymax,xmax)`: earliest top edge, then
earliest left edge, then earliest bottom and right edges. An all-background
frame returns area zero, empty true, and all four coordinates zero.

This capability differs from connected-component bounding boxes: a component's
outer box can contain background holes and concavities. The returned rectangle
here is guaranteed all foreground and need not contain a complete component.
The repository's CCA, contour, binary moments, geometry and distance-transform
packages do not implement this maximum-inscribed-rectangle objective. Both
repository-wide text searches and the existing image-package list were checked
before development. Existing RTL was not modified.

## Interface contract

Every signal uses the rising edge of one `clk`. Reset `rst` is synchronous,
active-high and overrides all work; hold it across a rising edge. Reset cancels
a partially received frame, active stack computation or pending result. The
ready and valid outputs are combinationally suppressed during reset. No CE or
CDC is present. Connecting a CE-qualified legacy stream requires an adapter
with an explicit transfer contract.

An input pixel transfers on `s_valid && s_ready`. The producer must hold
`s_pixel`, `s_sof`, `s_eol` and `s_tag` stable while valid and not ready.
`s_pixel=1` is foreground. Data are accepted left-to-right, top-to-bottom,
exactly WIDTH*HEIGHT pixels per frame. `s_sof` must be true only at the first
pixel; `s_eol` must be true exactly at every final column. The first accepted
pixel's `s_tag` is retained for the result; later tags are ignored. There is no
separate input last marker: the fixed dimensions define the final pixel.

Marker disagreement sets sticky `m_error` but does not stop or resynchronize
capture. The engine still consumes exactly the fixed raster count and computes
the rectangle on those accepted bits. An error-marked result therefore has a
defined numerical value but invalid external framing. A missing or extra pixel
cannot be inferred from marker values alone; use reset when source alignment
is lost. A missing source valid pauses normally without timeout.

One result transfers on `m_valid && m_ready`. Area, coordinates, empty, error
and tag remain stable under output backpressure. There is one result per frame,
so this single result also denotes transaction completion. No new frame pixel
is accepted while this result is pending. Output sidebands are meaningful only
while `m_valid=1`; working best-area registers may change during computation.
Consuming the result clears the working summary and enables the next frame.

| Parameter | Default | Legal range and representation |
|---|---:|---|
| WIDTH | 64 | 1..1024 pixels |
| HEIGHT | 64 | 1..1024 rows |
| TAG_W | 8 | 1..32 unsigned uninterpreted tag bits |

Parameters are static elaboration configuration; there is no runtime update
channel. Simulation guards reject invalid parameter profiles. Area width is
`max(1,clog2(WIDTH*HEIGHT+1))`, representing the full-frame maximum exactly.
Coordinate widths are `max(1,clog2(WIDTH))` and `max(1,clog2(HEIGHT))`.
All quantities are unsigned integers; there is no rounding, fixed-point scale,
approximation, saturation or overflow for legal parameters. There is no
external memory/bus interface, bus address, memory error response or ECC.

## Algorithm, storage and cycle behavior

Each column retains the current vertical run length of foreground pixels. A
zero resets that height; a one increments it. The first row overwrites heights
without reading their previous values. For each row, an increasing-height
monotonic stack finds the exact largest histogram rectangle. A zero sentinel
at x=WIDTH drains the stack, so rectangles touching the right border and final
row are considered. Every positive height is pushed at most once and popped
at most once per row. Equal heights retain the earliest start coordinate.

The stack top is cached in registers. A push writes the previous top to stack
RAM; a pop reads the preceding entry synchronously and restores it on a later
clock. The height array also uses a registered read and separate write stage.
All consumed stack cells were previously pushed; every consumed height is
written in this frame. RAMs do not need reset or initialization files, and no
unwritten cell influences output. Pixel traffic is blocked during stack work,
so input backpressure is required and is not a no-stall video interface.

A pixel without a pop is accepted every four clocks: input/read, height
update, stack processing and advance. Each pop adds one clock if it empties
the stack, or two clocks when a deeper top must be restored. A zero sentinel
adds two base clocks per row, plus its pop work. The worst-case total work is
bounded above by `6*WIDTH*HEIGHT + 2*HEIGHT` clocks when source valid is
continuously available, before sink stalls. The exact final-pixel-to-result
delay depends on the row's stack content. There is no unconditional completion
deadline if the source or sink may stall indefinitely. These are RTL schedule
bounds, not measured hardware frequency or throughput.

Storage is O(WIDTH), rather than a binary frame or per-component label table:
`WIDTH*HCW` height bits and `WIDTH*(HCW+XW)` stack bits, where
`HCW=clog2(HEIGHT+1)` and XW is the coordinate width. Default array capacity is
1280 bits; maximum legal geometry needs 32768 array bits. The implementation
has one height-by-width multiplication for candidate area, a best-area compare,
coordinate tie comparison, counters and the finite controller. There is no
unbounded hardware loop, external memory, vendor primitive, ROM, include or
generated coefficient dependency.

Qualitative architecture risk is **LOW** for default storage and **MEDIUM** for
candidate multiply/compare timing and target-specific RAM inference. Maximum
parameters retain modest logical bit storage, but physical BRAM packing, LUT
mapping, DSP inference, frequency and target fit are unmeasured. This is a
structural assessment, not synthesis evidence or a device-fit guarantee.

## Offline use and finite verification

`files.f` is the complete production-source closure relative to this package.
`example/max_rectangle_example.sv` connects an unsigned 8-bit grayscale stream
through a threshold of 128 to a 64x64 rectangle engine. The example has no
implicit camera/board dependency. Frame markers and the pixel must share the
same ready/valid acceptance event.

```powershell
python -B cores/image_processing/max_binary_rectangle/run_tests.py
```

The runner needs Python 3's standard library plus Icarus Verilog and vvp. It
prefers the existing repository OSS CAD Suite and adds its bin/lib paths to
the subprocess environment. Each tool process has a strict 20-second timeout.
Temporary generated testbenches and simulator binaries are task-specific and
automatically removed. The full deterministic TB template and fixture
generator are source in `run_tests.py`; no network or external vector file is
required. A failed rerun removes the previous PASS report first.

Current status: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**.
`verification.json` binds actual command outputs to source SHA256. The finite
suite passed 672 frames over 1x1, 1x7, 7x1, 3x3, 8x6 and 9x8 geometry. It
exhaustively checks all 512 binary 3x3 images against an independent oracle
that enumerates every rectangle with summed-area counts, rather than sharing
the hardware stack algorithm. Directed and seeded cases cover zero/full
frames, checkerboards, stripes, borders, rising/falling height sequences,
random sparse/dense masks and deterministic equal-area coordinates. Every
frame's area, full box, empty/error/tag are compared. Protocol checks include
source gaps, calculation backpressure, five-cycle output stalls, malformed
SOF/EOL, frame reuse and reset during active processing, sentinel draining and
pending output.

Default/example compilation and the maximum 1024x1024/tag32 profile pass
`iverilog -g2012 -Wall -tnull`; the maximum profile was **not simulated**.
WIDTH=0/1025, HEIGHT=0/1025 and TAG_W=0/33 are separately rejected. No synthesis,
PnR, STA, board operation, full regression or arbitrary-parameter proof was
performed. The local LF rule ensures the hashed text matches committed blobs.

Source provenance and the inspected upstream license are in [SOURCES.md](SOURCES.md).
