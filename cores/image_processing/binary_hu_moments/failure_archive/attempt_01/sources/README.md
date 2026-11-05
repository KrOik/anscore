# Exact seven rational Hu descriptors of a binary raster

`binary_hu_moments` accepts actual binary pixels, accumulates all ten spatial
moments through degree three, and computes all seven Hu quantities in RTL.
No host moments, centroid, normalized values, expected descriptor or prebuilt
arithmetic result is an input. This adds complete central/normalized shape
descriptors beyond the existing six second-order raw moments and centroid.

Hardware remains **HW_UNVERIFIED**: no synthesis, PnR, STA, board test, measured
resources, clock frequency or power. Source exists as RTL_CANDIDATE. Only a
`verification.json` with `status=UNIT_SIM_PASS`, matching the exact current
`SOURCE_FREEZE.json` and all source hashes, qualifies its finite unit checks.
Without that receipt, numeric and HDL qualification is NOT_RUN. The plan is
fixed before first HDL; a failure stops the whole attempt and retains its
original sources, receipt, output and existing compiled artifacts. No adaptive
splits, retries, seed searches or unrecorded qualification are permitted.

## Raster and handshake

Static WIDTH and HEIGHT are independently1..32, TAG_W1..32. Default8x8/T8.
All ports use one rising-edge clock, synchronous high-active `rst`, ordinary
ready/valid, no CE, runtime configuration, CDC, vendor primitive, external
memory or lookup-table dependency. Exactly WIDTH*HEIGHT input handshakes close
one frame in raster order. Each pixel is a point sample of weight0 or1 at
integer `(x,y)`, with x right and y down. SOF is true only on the first pixel;
EOL is true exactly on every final column. There is no input LAST, KEEP,
automatic marker restart or missing-input timeout. Missing samples wait.

The source holds `{s_pixel,s_sof,s_eol,s_bad,s_tag}` until valid&&ready or reset.
Every accepted raster position advances, including background. The first tag
owns the whole frame, including a malformed/empty one; later tags are ignored.
Input II=1 throughout capture. Computation and all held outputs block new
input. The next frame may first transfer on the edge after the last response
retires; no overlapping frame buffers are claimed. Source/sink pauses have no
unconditional wall-clock bound.

Good frames emit index0..6 in order, one exact signed numerator and positive
unsigned denominator per record, keep1, last only at index6. `m_area` is the
foreground population. Every response field is stable under backpressure.
Fractions are intentionally unreduced; zero numerators retain the specified
positive denominator. There is no integer division, square root, floating
point, log magnitude, rounding, saturation, tolerance or approximate result.

| m_errors bit | Meaning |
|---|---|
| 0 | Empty complete raster (m=0), Hu normalization undefined |
| 1 | At least one accepted SOF mismatch |
| 2 | At least one accepted EOL mismatch |
| 3 | At least one accepted s_bad |

All errors drain the entire fixed raster, then emit exactly one record:
num0/den1/index0/keep0/last1, actual population, first tag and sticky errors.
All16 combinations, including empty malformed frames, are reachable. A
nonempty one-pixel object has m=1, denominator1 and seven valid zero values;
it is distinct from m=0 error. No failed frame exports a partial descriptor.

Reset immediately gates s_ready/m_valid low, cancels the frame on its edge,
and resets scalar ownership/state regardless of traffic. Scratch payload and
read-q are unreset. A fresh complete capture writes all ten raw source words
and every arithmetic destination before any corresponding read. Reset during
capture, RAM work, a multiply, any output or a retired prefix cannot leak a
canceled response. A source may drop an aborted transfer under reset.

## Exact quantities

For foreground points, let `m=M00`, `M_pq=sum(x^p*y^q)`, centroid
`cx=M10/m,cy=M01/m`, and `mu_pq=sum((x-cx)^p*(y-cy)^q)`.
Define `Qpq=m*mu_pq` for degree2 and `Tpq=m^2*mu_pq` for degree3. These are
integers. With

```
p=T30-3*T12; q=3*T21-T03; u=T30+T12; v=T21+T03; z=Q20-Q02
```

the output fractions are:

| index | Numerator | Denominator |
|---|---|---|
| 0 | Q20+Q02 | m^3 |
| 1 | z^2+4*Q11^2 | m^6 |
| 2 | p^2+q^2 | m^9 |
| 3 | u^2+v^2 | m^9 |
| 4 | p*u*(u^2-3*v^2)+q*v*(3*u^2-v^2) | m^18 |
| 5 | z*(u^2-v^2)+4*Q11*u*v | m^12 |
| 6 | q*u*(u^2-3*v^2)-p*v*(3*u^2-v^2) | m^18 |

These are the real-valued Hu formulas using the point-sample binary-image
moments, represented exactly. An arbitrary raster rotation or resize changes
the sampled support and is not generally a bitwise invariance. Translation
and90-degree rotations of an unchanged in-bounds point set preserve all
seven. A genuine reflected coordinate transform preserves the first six
and reverses H7's sign. Tests assert those identities only for actual
unclipped integer-coordinate transforms; no universal resampling claim is made.

## Architecture and finite scope

Coordinate monomials use exact finite differences; ten small raw accumulators
provide II1 without coordinate multipliers. A fixed79-instruction DAG uses
45 signed multiplications and34 add/sub operations. All wide arithmetic,
including operand magnitudes and restored product signs, shares one carry
adder. Every multiplier executes exactly WORK_W bit steps. Scratch is one
32-word synchronous single-port read-or-write bank, not a frame RAM.
The full instruction allocation and per-step bounds are in
[INSTRUCTIONS.json](INSTRUCTIONS.json); its peak live set is20 words.

[COST.md](COST.md) derives every declaration, width and latency. At default:
WORK_W117, RAW_W16, RAM3744bits, scalar1325bits. At32x32/T32:
WORK_W189, RAW_W26, RAM6048bits, scalar2246bits. These are logical declarations,
not physical BRAM, LUT, DSP, frequency or power measurements. Wide carry paths
and small wide RAM fragmentation are MEDIUM architectural risks; device fit
and inference remain UNKNOWN without synthesis.

After final capture, a good first valid appears at exactly
`45*WORK_W+464` edges. With a continuously ready sink the seventh retirement
is at `45*WORK_W+489`; the first handshake is first-valid+1. At maximum these
are8969/8994 edges, plus1024 capture edges for10018 total. Error first-valid
appears immediately after the final capture edge (offset0). There are no
data-dependent arithmetic skips. Backpressure adds time, while preserving
the count of actual RAM/ALU/bit operations.

The fixed plan has six profiles1x1/T1,1x7/T32,7x1/T1,3x3/T8,8x8/T8,32x32/T32;
192 main frames in72 simulations (maximum frame size uses one frame/group),
218 resets each followed by a full fresh raster and all seven outputs,
and306 total20-second child slots. N1 explicitly excludes four impossible
partial-raster targets. The independent oracle uses Fraction centering of
each actual coordinate, not raw-moment expansions or the RTL instruction DAG.
The TB cross-multiplies every response against that independently reduced
fraction and separately checks the required denominator/metadata. It checks
direct-coordinate raw sums, every significant multiply shift/partial/factor,
all arithmetic prefixes/bounds, synchronous scratch ownership and payload,
exact first-valid latency, all15 real states, queued traffic, actual fresh-first
next offers, reset-high rejection and held responses. See TEST_PLAN.json for
the complete immutable fixture/argv/predicate enumeration after preparation.

`files.f` and `example/files.f` are relative to this package; include rtl/ and
also sim/ when compiling the TB. `example/hu8.sv` is the complete default
instantiation. Runtime use needs only rtl/binary_hu_moments.sv and its supplied
instructions.vh. Offline assemble.py can recreate the static decode; it is
not a runtime dependency. Tool runs require root authorization after sealing:

```
python -B prepare.py                   # root-authorized finite preparation only
python -B run_tests.py --seal          # sources/fixtures freeze, no HDL
python -B run_tests.py --run           # only after exact root preflight approval
python -B run_tests.py --check         # receipt/raw metadata, no new HDL
```
