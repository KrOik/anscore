# Grayscale stable extremal regions

Bounded, frame-buffered SystemVerilog detector for one-sided area-ratio stable
extremal regions in 8-bit grayscale images. It consumes one raster frame and
returns exactly N dense raster records, including canonical tree information,
an exact variation fraction and a selected flag. Bright and dark polarity are
configured per frame. The definition is fixed in MATHEMATICS.md; diversity is
disabled and the global root is excluded.

The present package is source-only. Preparation, reference evaluation, fixture
generation, lint, simulation, runner, synthesis, PnR, STA and board checks are
NOT_RUN. Hardware is HW_UNVERIFIED. AUTHOR_SEAL.json freezes the source and
future finite plans; it is not test evidence or execution authorization.

## Parameters and interface

WIDTH and HEIGHT are integers 1..16 (default8), CONNECTIVITY is4 or8 (default4),
and TAG_W is1..32 (default8). N=WIDTH*HEIGHT, IW=max(1,ceil(log2 N)), and
CW=max(1,ceil(log2(N+1))). Pixels are fixed unsigned8. Unsupported parameters
elaborate the named unresolved marker
`grayscale_stable_extremal_regions_invalid_parameter__see_README`.

The first `s_valid && s_ready` transfer locks `cfg_bright`, `cfg_delta`,
`cfg_variation_p`, `cfg_variation_q`, `cfg_min_area`, `cfg_max_area`, and `s_tag`.
Delta must be1..255, Q must be1..255, P may be0..255, and
1<=min_area<=max_area<=N. P=0 is legal and selects no region. Later configuration
and tag pins are ignored for numerical semantics. Every held input beat,
including all configuration pins, must remain valid and stable until accepted.
SOF must equal(index==0); EOL must equal(x==WIDTH-1), including WIDTH1.

No following frame input is admitted until the current final output transfer
retires. A following valid offer may be held throughout computation and replay.
Every output field remains stable while `m_valid && !m_ready`.

Each output is `(index,parent,level,area,variation_num,variation_den,canonical,
selected,errors,tag,sof,eol,last)`. Index advances in raster order0..N-1; level is
the original source gray value at canonical indices, for both polarities.
Noncanonical parent/level/area/num/den and selected are zero. A canonical root
has parent=self, area=den=N, num=0, selected=0. Error bit0 is SOF mismatch, bit1
EOL mismatch and bit2 invalid first configuration. Any error still drains all N
inputs, then emits N records with numeric/flag fields zero and the accumulated
errors and first tag. Input pixels are not early-terminated on a marker error.

Reset is synchronous active-high; public ready/valid and output markers are
also combinationally gated low whenever reset is high. Reset abandons ownership
and permits a wholly fresh frame. Node RAM and its read register have no reset;
every successful new frame overwrites all N entries before reading them.

## Integration and files

Both lists are resolved with this package as the working directory:

```
files.f
example/files.f
```

They explicitly reference the unchanged exported sibling
`../grayscale_max_tree/rtl/grayscale_max_tree.sv`. Do not use example/ as the
working directory. `example/stable_regions8.sv` forwards every configuration,
source, sink and result port of the default8x8/K4/T8 implementation. DEPENDENCIES
records the B29 manifest and exact production dependency hash. There are no ROMs,
nested lists, vendor primitives or protected untracked production sources.

MATHEMATICS.md defines numerical semantics and hand witnesses. ARCHITECTURE.md
documents the RAM schedule and widths. COST.md derives exact cycles and bounded
storage. FORMATS.md defines fixtures/raw streams and reset observations.
PROCESS.md describes the two separate future approvals, fail-stop execution and
retained evidence. SOURCES.md records provenance and licenses. CASE_TABLE.json,
BOUNDARY_CERTIFICATES.json, PREPARATION_PLAN.json and TEST_PLAN.json are frozen
source metadata, not generated numerical fixtures.

Repair01 strengthens the future preparation and HDL gates with a complete
runtime inventory, fixed child environment, copied numerical entry/model,
retained original approval/reviews and full PASS provenance in SOURCE_SEAL.
The numerical contract and fixed40-reference/34-fixture/26-child plan are
unchanged. All execution remains NOT_RUN pending new independent reviews and
separate exact root approvals.
