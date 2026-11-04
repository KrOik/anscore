# Streaming binary topology summary

`streaming_binary_topology` directly computes two exact digital Euler
characteristics, foreground area, and cell-edge perimeter from a binary raster.
The direct topology metric and one-pass O(WIDTH) architecture are distinct from
the repository's frame-buffered CCA, contour tracing and hole-filling engines.
No full-frame labels, component budget, contour list, flood queue, iterative
convergence condition or host postprocessing is needed.

With foreground components `C4/C8` counted using four/eight neighbors and
background holes `H4/H8` counted using the indicated background connectivity:

```text
m_euler4 = C4 - H8    (four-connected foreground, eight-connected background)
m_euler8 = C8 - H4    (eight-connected foreground, four-connected background)
```

A background region is a hole exactly when it cannot reach the image boundary
through that background connectivity. The space outside the image is
background. Both metrics are signed integers and may be negative for a
connected foreground with several holes. They are not the component and hole
counts separately. Diagonally touching foreground pixels can give different
Euler characteristics under the two conventions; neither is substituted for
the other.

`m_area` counts all foreground pixels. `m_perimeter` counts exposed unit cell
sides, including image boundaries and hole boundaries. It is an integer
Manhattan cell-edge perimeter, not a Euclidean, Crofton or pixel-center contour
length. All-background input returns zero for both Euler metrics, area and
perimeter, and sets `m_empty=1`. A nonempty uniform rectangle has both Euler
metrics one, area WIDTH*HEIGHT, and perimeter `2*(WIDTH+HEIGHT)`.

## Interface and configuration

All signals use one rising-edge `clk`. `rst` is synchronous active-high and
overrides active capture, border draining and pending output. Assert it across
a rising edge to cancel a frame. Ready and valid are combinationally gated low
while reset is asserted. Payload outputs and control counters reset; the row
memory does not. There is no CE and no CDC. Existing CE-qualified streams need
an explicit interface adapter before connection.

Each pixel transfers on `s_valid && s_ready`. The source must hold pixel,
markers and tag stable until accepted. Input order is left-to-right then
top-to-bottom, with exactly WIDTH*HEIGHT pixels per frame. `s_pixel=1` is
foreground. `s_sof` must be true only on the first pixel; `s_eol` must be true
exactly at every row's last column. `s_tag` is retained from the first accepted
pixel; tags on later pixels are ignored. Static dimensions determine the final
pixel, so there is no separate input last field.

Wrong SOF/EOL sets sticky `m_error` but does not change the fixed raster count,
drop a pixel or attempt resynchronization. The numerical outputs still describe
the accepted bits laid out at the specified dimensions. Use reset if the source
loses pixel-count alignment; a marker alone cannot reveal omitted pixels.
Source gaps pause reception without timeout.

After the last pixel, input ready stays low while zero border contributions
are drained. The single frame result transfers on `m_valid && m_ready`.
Both Euler values, area, perimeter, empty, error and tag remain stable while
valid and stalled. No new frame is accepted until this result is consumed.
There is one result per frame and no separate output last marker. Output
fields are meaningful only when valid: area and perimeter are working
accumulators and may change during capture. The next frame is independently
initialized after result consumption.

| Parameter | Default | Legal values |
|---|---:|---|
| WIDTH | 64 | 1..1024 pixels |
| HEIGHT | 64 | 1..1024 rows |
| TAG_W | 8 | 1..32 opaque unsigned bits |

Parameters are static elaboration settings; there is no runtime configuration
update, external memory port, address map or bus error behavior. Simulation
guards reject illegal parameter profiles. Pixels, area, perimeter and tag are
unsigned; Euler outputs are signed. `AW=max(1,clog2(WIDTH*HEIGHT+1))`,
`EW=AW+1` and `PW=clog2(4*WIDTH*HEIGHT+1)` are their area/Euler/perimeter widths.
There is no fractional scale, approximation, rounding, saturation or capacity
overflow for legal parameters.

## Algorithm and structural review

Every 2x2 neighborhood at each of the `(WIDTH+1)*(HEIGHT+1)` image lattice
vertices is visited exactly once, with an implicit zero pixel border. Let Q1
be the count of neighborhoods containing exactly one foreground pixel, Q3 the
count containing exactly three, and QD the count containing exactly two
diagonal foreground pixels. Then

```text
4*Euler4 = Q1 - Q3 + 2*QD
4*Euler8 = Q1 - Q3 - 2*QD
```

The datapath adds local signed contributions selected by a 16-pattern case
table. At the final corner both numerators are exactly divisible by four;
the arithmetic right shift is an exact integer conversion, including negative
results. A conservative partial-sum magnitude bound of twice the vertex count
sets the signed numerator width, so intermediate padding contributions cannot
overflow even when a tiny frame has a relatively large border.

A synchronous one-bit-wide row RAM supplies the previous row. Upper-left and
left pixels are held in registers. The first row explicitly treats old RAM as
zero while overwriting it. Right-edge vertices are added at each row end;
after the final row, a separate synchronous-read pass adds the bottom edge and
corner. Thus every subsequently consumed row-memory cell belongs to the current
frame. Reads and writes occur on separate states and do not require a
read-during-write collision mode. Reset does not clear the RAM.

Area increments on each foreground pixel. Perimeter uses the exact identity
`4*area - 2*horizontal_foreground_pairs - 2*vertical_foreground_pairs`.
No multiplier, divider, DSP, vendor primitive, coefficient table, generated
memory data or external storage is required.

Within a row, accepted inputs are separated by two clocks for the synchronous
read and update. Between row-final and next-row-first pixels the interval is
three clocks because of the right-border vertex. Once the final input pixel
is accepted, result valid asserts after `2*WIDTH+3` clocks, independent of
pixel values. Source gaps before the last pixel and output sink stalls add
their own duration. These are RTL scheduling facts, not measured hardware
frequency or line-rate video performance.

Qualitative resource risk is **LOW** for the default arithmetic and storage;
RAM mapping at larger widths is **MEDIUM** until checked with a target tool.
Row storage is WIDTH bits (64 by default, at most 1024), plus scalar counters,
small pattern logic and one row-read register. Storage does not grow with frame
area. A one-bit RAM may map to LUTRAM, registers or a partially occupied BRAM;
no specific physical mapping, LUT count, timing, power or device fit is claimed.

## Offline use and finite evidence

`files.f` is the entire production dependency closure relative to this package.
`example/binary_topology_example.sv` connects a 64x64 unsigned grayscale stream
through a fixed threshold of 128 and exposes both signed Euler metrics and
unsigned area/perimeter. The markers and grayscale value must be aligned at
the same ready/valid event. No camera, display or board environment is assumed.

```powershell
python -B cores/image_processing/streaming_binary_topology/run_tests.py
```

The runner needs only Python's standard library and Icarus Verilog/vvp. It
prefers the repository's existing OSS CAD Suite and adds bin/lib to child
process PATH. Each tool process has a strict 20-second timeout. A failed rerun
cannot leave an earlier PASS report. Generated deterministic TBs are created
inside a task-specific temporary directory and removed with simulator binaries;
the complete TB template and vector generator remain in `run_tests.py`.
Tests need no network or third-party Python package.

Current maturity: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**.
`verification.json` binds five source hashes to actual finite check outputs.
Seven dimensions (1x1, 1x7, 7x1, 2x2, 3x3, 8x6, 9x8) cover 688 frames,
including every one of the 16 binary 2x2 and 512 binary 3x3 configurations.
The independent oracle counts foreground components and enclosed background
regions with graph traversal under both connectivities, and enumerates exposed
sides for perimeter. It does not reuse the hardware's local neighborhood table.
All four numerical fields, empty/error and tag are compared for every frame.
Fixtures include empty/full rasters, diagonal contacts, checkerboards, stripes,
border rings, multiple isolated holes with negative Euler, and seeded random
density masks. Protocol checks cover malformed markers, source gaps, input
backpressure, five-cycle held results, frame reuse and reset during capture,
bottom padding and pending output.

The default example and maximum 1024x1024/tag32 profile pass Icarus
`-g2012 -Wall -tnull`; the maximum profile is compiled only. Six invalid
WIDTH=0/1025, HEIGHT=0/1025 and TAG_W=0/33 profiles are separately rejected.
No synthesis, PnR, STA, board operation, full regression or arbitrary-parameter
proof was run. The local LF rule preserves text hashes across Git commits.

Fixed reference and license review are in [SOURCES.md](SOURCES.md).
