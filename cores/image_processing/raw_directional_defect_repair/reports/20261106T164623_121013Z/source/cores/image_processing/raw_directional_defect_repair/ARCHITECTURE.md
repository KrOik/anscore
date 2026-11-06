# Architecture budget and invariants

The primary design objective is useful adaptive RAW repair with bounded line
storage and a backpressured burst II of one accepted window. A full-frame,
serial median8 implementation already exists and is deliberately not repeated.
The selected envelope/pair rule needs no sort network and no corrected-frame
buffer. Its stricter detection policy is part of the published algorithm.

Same-phase offsets are {-2,0,+2} in each axis, excluding the center. Padded K5
windows supply the exact donor/center alignment. Eligible centers must be two
pixels from every edge; replicated edge donors are never used for a repair.

Numeric bounds for M=2^BITS-1:

| Node | Width | Range / quantization |
| --- | --- | --- |
| Original samples, differences, donor extrema, excess | BITS unsigned | 0..M |
| Pair sums | BITS+1 unsigned | 0..2M |
| Pair sum plus half-up bias | BITS+1 unsigned | 1..2M+1 |
| Predictor | BITS unsigned | floor((a+b+1)/2),0..M |
| Adaptive threshold | BITS+1 unsigned | base+(g>>shift),0..2M, no saturation |
| Transfer and repair counters | 17 unsigned | 0..65536 inclusive |
| Direction | 2 unsigned | H,V,backslash,slash =0,1,2,3 |

Stage A registers center, extrema and four complete sum/difference pairs.
Stage B selects the earliest minimum gradient and registers predictor/gradient.
Stage C compares excess with the full-width threshold and registers the output.
Each stage has its own occupancy and ready event; empty upstream stages can
fill during downstream holds, and all carried markers follow the same events.
Window coordinates advance only when A accepts a window. Input coordinates
advance only when the original pixel is accepted. Summary counters advance on
retired output. START fields remain owned until DONE retirement.

The reused engines explicitly infer register row memories on this repository's
supported path. Their storage is not represented as a fabricated BRAM estimate:
5*(WIDTH+4)*BITS bank bits plus WIDTH*BITS padded row bits, with tap/history,
read-data and local pipeline registers additional. At default64x48 RAW12 the
row arrays contain4848 logical bits. No full-frame RAM, data multiplier or data
divider is authored. Physical LUT/FF/DSP/BRAM and Fmax remain unmeasured.

The K5 padded engine captures N original samples and replays (W+4)*(H+4)
extended pixels, with synchronous request/pending/drain stages and possible
overlap at phase boundaries. Local pipeline drain adds three accepted advance
steps; complete frame timing must include inherited row gaps and external
stalls. This paper budget does not assert a measured continuous pixel rate.
The actual Bayer composition adds the unchanged K3 row-window engine and its
output register, so RAW retirement is deliberately distinct from RGB retirement.

Controls use synchronous high reset and per-command local low-reset conversion
for K5 window state. RAM arrays are never reset. Frame history initialization
follows capture-before-consume in the original engines, including width/height1.
The public wrapper additionally owns the real demosaic output through its last
handshake. No dependency source, memory mode or legacy CFA ABI is changed.
