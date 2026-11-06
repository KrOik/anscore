# Causal raster palette error diffusion

`causal_palette_diffusion` turns unsigned 8/10/12-bit grayscale pixels into one
of two runtime configured grayscale levels. It emits each result before
requesting the next input pixel, using two error rows and no captured frame or
result image. This permits a live raster source to make progress without first
supplying an entire frame. The actual example connects the unchanged mature
`isp_rgb2gray` RGB888 converter through an explicit one-token CE/RV adapter.

The existing `common_scaffold/image/error_diffusion/floyd_steinberg.sv` captures
a complete frame, supports internal serpentine traversal and fixed full-scale
uniform code levels, and stores a complete result frame. It remains unchanged.
This package adds a distinct causal storage/dataflow organization and runtime
two-level palette. It has raster-only traversal and serialized pixel service.

For a frame command, snapshot unsigned `c_low < c_high`, and `c_tag`. Let
`M=2^BITS-1`. At raster coordinate `(x,y)`, with an accumulated signed Q4 error:

```
corrected = clamp(16*input + incoming_error, 0, 16*M)
code = 1 if 2*corrected >= 16*(low+high), else 0
level = high if code else low
error = corrected - 16*level
contribution(weight) = sign(error)*floor((abs(error)*weight+8)/16)
```

Contributions go right with weight7, down-left with3, down with5 and down-right
with1; every weight is divided by16 by the expression above. Midpoint ties
choose the high level. Contributions are separately rounded in Q4 units to
nearest with half values away from zero. No whole-intensity truncation occurs
between pixels. Corrected intensity is clamped before selection/error; the
accumulated error is never additionally saturated. Borders discard unavailable
neighbors without renormalization. Row ends discard the right contribution.
Output includes both the selected unsigned level and its one-bit code. Palette
levels need not span full scale, so discarded/clamped error may bias brightness.
No frame-mean conservation or visual quality guarantee is made.

All public channels use ordinary `valid && ready` on rising `clk`; there is no
CE and no CDC. `rst` is active-high and sampled synchronously by the new core;
it overrides all work and cancels pending output/completion. The reused gray
core in the example internally asserts its active-low reset asynchronously
through `!rst`; callers hold reset across a rising edge. All public handshake
outputs are suppressed while reset is high. RAM is not reset: each valid new
command explicitly clears both rows before source readiness.

`c_valid/c_ready` starts exactly one static WIDTH-by-HEIGHT frame. Configuration
pins may change after acceptance. Palettes with `low>=high` produce DONE error1
without accepting pixels. Input markers must be SOF only at `(0,0)`, EOL only
in column `WIDTH-1`, and LAST only at `(WIDTH-1,HEIGHT-1)`. Marker mismatch
produces DONE error2 and no output for the failing input. Earlier outputs are
provisional until successful DONE; errors or reset require discarding the whole
frame. Error3 is the illegal-control-state recovery diagnostic. No automatic
resynchronization or source/backpressure timeout exists.

Each accepted legal input yields exactly one output. Output data, code, raster
coordinates, markers and command tag hold until accepted. Pixel position advances
only when output is consumed. DONE holds error/tag until `d_ready`; the next
command cannot cross a held pixel or DONE. Outputs for an erroneous frame must
be discarded. The example does not prefetch another RGB pixel while a gray token
is owned, so no later token can survive a marker fault into the next frame.

Allowed parameters: WIDTH/HEIGHT1..4096 independently, BITS8/10/12, TAG_W1..32.
There is no frame-product storage restriction. Defaults128x64/BITS8/TAG8.
Dimensions4096x4096 receive syntax checking only in the frozen plan. Interface
coordinates are unsigned16; tags are opaque. See ARCHITECTURE.md for exact
widths, memory ports, cycle schedule and qualitative implementation risks.

All file lists are relative to this package root:

```
iverilog -g2012 -s causal_palette_diffusion -f files.f
iverilog -g2012 -s rgb_palette_diffusion -f example/files.f
```

These are integration descriptions, not evidence of execution. The source-only
plan is PRECHECK_PLAN.json. `run_tests.ps1 -Freeze` only hashes source/tools.
After complete-source review and root first-run authorization,
`run_tests.ps1 -Execute` archives the exact dependency closure, launches one
isolated vector preparation child, then eleven finite HDL children. Each child
has20s execution/5s tree-kill/one joint2s raw drain limit, including exception
closure of every acquired process/stream. It fails closed and retains all
images/logs; no retries or cleanup are performed. There are no old checker,
runner or oracle imports. The independent oracle uses an entire 2-D error field.

Current state: RTL_CANDIDATE, INTEGRATION_CANDIDATE, HW_UNVERIFIED. No model or
HDL execution has yet occurred. No synthesis, PnR, STA, board or PPA is claimed.
