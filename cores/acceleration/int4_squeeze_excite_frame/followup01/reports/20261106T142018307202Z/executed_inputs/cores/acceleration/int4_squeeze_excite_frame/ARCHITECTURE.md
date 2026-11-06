# Architecture and feasibility review

A full frame is required because every channel gate depends on all pixels.
Caching input plus a descriptor is smaller than retaining a parallel convolution
graph. One frame is processed at a time; no claim of continuous frame acceptance.
The two existing dense instances retain separate matrices and serialize each
dot product. Reconfiguring one physical dense instance between layers would
require replaying persistent parameters; two instances keep the public reuse
contract simple. Neither implements a parallel channel MAC array.

Pooling sums are exact signed24: 4096*(-128) is -524288. The inherited pool
supports an even larger domain. Its means lie in signed8. Reduction has at most
64 terms with magnitudes 128*8, expansion at most32 terms of127*8; with signed32
bias both fit the reused signed40 accumulator. The inherited signed57 scaling
product and RNE quantizer preserve its specified dense arithmetic. Gate
endpoints short-circuit; interior z+96 lies in1..191, so numerator4*(z+96) is
4..764 and a10-bit quotient/remainder divider by3 suffices. Quotient<=254 and
rounding by remainder2 produces gate<=255. A256 endpoint is written directly.

Final scaling uses one8x10 signed multiplier with the positive nine-bit gate
zero-extended to signed10. Its exact range[-32768,32512] fits signed17; an18-bit
register retains the complete natural product. Magnitude quotient/remainder
by256 and parity give signed RNE. Rounded values remain[-128,127]. All arrays
use separate write and registered-read phases with no same-address read/write
collision. Payload arrays have no reset loops. Resettable validity is finite.

Logical payload bits, excluding arithmetic/control/metadata and pipeline slots:

| Storage | Default C16/H4/P256 | Maximum C64/H32/P4096 |
|---|---:|---:|
| Frame | 32768 | 2097152 |
| Descriptor/hidden/gates | 304 | 1344 |
| Packed W0/W1 | 768 | 16384 |
| Child vector caches | 160 | 768 |
| Pool sums | 384 | 1536 |

Packed matrix padding is included: 32*(H*ceil(C/8)+C*ceil(H/8)). Parent mirrored
validity is H*ceil(C/8)+C*ceil(H/8)+H+C bits,44 default and608 maximum; the child
cores have matching validity. Dense row metadata is61*(H+C) bits. These are
logical structural budgets, not mapped BRAM/LUT/DSP counts. The maximum frame
alone can exceed a small FPGA's on-chip RAM. Architecture risk MEDIUM default,
HIGH at maximum, with registered memory reads, address multiplexing and inherited
wide scale multipliers still requiring device-specific implementation checks.

Precheck visits H*ceil(C/8)+C*ceil(H/8) validity entries. The pool accepts at most
one input every2 clocks and performs a24-step division per channel. Each dense
term uses its existing registered read/MAC pair, plus per-row scale/quantization.
Each unsaturated gate adds a10-step division and handshake overhead. Replay has
four states per result: read, multiply, round, output; with an always-ready sink,
successive outputs transfer4 clocks apart. No independent latency assertion is
currently run. Input gaps, output or completion stalls have no completion bound.
There is no MHz, real-time-video, energy, accuracy or power measurement.
