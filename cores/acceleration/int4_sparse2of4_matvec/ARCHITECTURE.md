# Representation, architecture and resource review

Deduplication read the resident dense int4_weight_matvec, grouped pointwise,
stream_sparse_matvec, sparse_dot and sparse duplicates/unsorted variants;
searched canonical/core/common_scaffold/operator sources for 2:4 structured
compression. Dense inference stores every weight; generic sparse matrix rows
stream full column indices and coefficients and do not retain compressed
row-wise INT4 patterns. The new capability is resident 11-bit/four-column
representation, prefix publication, cached activation gather and persistent
quantization. It is a distinct format/architecture, not a renamed data width.

A four-position pair has six legal possibilities. Three metadata bits and two
S4 values consume 11 logical bits per group, compared with 16 for dense S4.
This is a logical storage comparison; FPGA RAM granularity and inference may
erase some savings. Two products are always scheduled even when a stored weight
or a cropped position is zero. No dynamically pruned model is generated.

The alternatives considered were decoding back to dense and running the old
matvec, generic index-stream sparse rows, and resident pattern-aware execution.
Decoding to dense loses compressed storage and still scans every column. The
index stream is useful for general sparsity but needs repeated weight traffic.
The selected design reads one group, gathers its two selected activations and
uses one 9x4 signed multiplier. A product register separates multiply from the
40-bit accumulator; the first accumulate overlaps the second multiply. Five
clocks per group include weight read, first activation read, two multiplies and
the final accumulate. Per row also needs initialization, scaling and quantizer
admission. A separate 40x17 scale multiplication is a deliberate fixed operator,
not a claimed shared DSP. The 57-bit product is extended into the existing exact
RNE quantizer; signed16 intermediate saturation cannot return into S8 range
after any allowed signed8 zero, so clip/data match final-only S8 saturation.

With R rows, C columns, G=ceil(C/4), continuous input and always-ready output,
the command-to-final-transfer budget is conservatively:

```
C_service <= C + R*(5*G + 5) + 8
```

This includes R precheck cycles and quantizer drain. It is an RTL service budget,
not hardware frequency or throughput evidence. Configuration traffic and
reset/reconfiguration are separate; input gaps and output stalls add waiting.
There is no guarantee under unbounded backpressure. No full parallel four-way
decode/MAC or large combinational reduction is used.

Default payload memory: 8*16*11=1,408 weight bits and 64*8=512 activation bits;
metadata is 8*61=488 bits, plus eight 16-bit prefix counts and eight valid bits.
Maximum payload: 64*256*11=180,224 weight bits and 8,192 activation bits;
metadata 3,904 bits plus 1,024 prefix-count bits and 64 valid bits. Memory payload
is not reset. Read/write occur at clock edges; row metadata is small register
storage. Constant row-stride address multiplication is not a data MAC. A single
11-bit weight array supports the ordered configuration/load/compute phases.

Risk: LOW for default structural scale, MEDIUM for maximum RAM packing,
address decoding and parameter-dependent implementation. There is no vendor
primitive, external memory, new CDC, measured area, timing or power result.
Changing supported limits requires revisiting counters, exact arithmetic and
source/finite qualification. The Top-2 example adds the unchanged two-slot
ranking array; its variable insertion service is included in end-to-end tests,
not assumed to have II=1.
