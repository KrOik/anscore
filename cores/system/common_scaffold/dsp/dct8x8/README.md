# Serial fixed-point 2D 8x8 DCT-II / IDCT

`dct8x8_serial.sv` implements the separable orthonormal transform
F=C*X*C^T and inverse X=C^T*F*C. C[k,n]=alpha(k)*cos(pi*(2n+1)k/16),
alpha(0)=1/sqrt(8), otherwise 1/2. The 64 hardcoded coefficients are nearest
Q14 signed integers. Both spatial and coefficient blocks use row-major ordering.
This is a transform core, not a JPEG encoder, quantizer or entropy codec.

BITS=2..16 signed samples enter a 64-element block store. Both dimensions
use a single reused 24x16 signed multiply and 48-bit accumulator (1024 total
products). Each 8-term dot product rounds once, `(acc+8192) >>> 14`, ties
toward positive infinity. The first pass retains 24-bit results without
saturation; the supported input range fits intermediate storage. Only final
outputs saturate to signed BITS range. `saturated` is cumulative for the current
completed transform, cleared at the next block's final input handshake and
by reset. It can rise as saturated output samples are presented.

All transfers are **ce && valid && ready**. CE is a shared pipeline clock
enable: downstream logic must also honor CE. Output valid/data remain stable
under CE pauses and backpressure. `cfg_inverse` commits on cfg_valid&&cfg_ready
only while completely idle between blocks; default is forward. cfg_done lasts
one enabled cycle. Pending cfg_valid prevents the first input beat from being
accepted simultaneously. Geometry is always 64 samples: there are no markers,
partial-block flushes or timeout recovery. `busy` includes capture, arithmetic
and output; no next block is accepted until the previous block drains.
Synchronous active-low reset overrides CE, discards partial/pending blocks,
clears status and restores forward mode; memories need no reset.

The two 64x24 stores use synchronous reads. Each dot product takes 17 enabled
cycles (8 read/MAC pairs plus store), so both passes take 2176 enabled cycles
after final capture. The first output becomes valid 2178 enabled edges after
the final input handshake and can be accepted on the following edge. Subsequent
outputs have II=3 enabled cycles without stalls. This is deliberately resource-
bounded block processing, not an II=1 streaming transform.

Verification commands, from repository root:

```
python -B cores/system/common_scaffold/dsp/dct8x8/test_dct.py
python -B cores/system/common_scaffold/dsp/dct8x8/synth.py
```

The independent Python matrix oracle computes floating and exact fixed-point
transforms. Tests cover 8/12/16-bit variants, 57 blocks/3648 output samples,
zero, DC, impulse, alternating signs, random values, full-scale positive and
negative values, saturation, inverse transforms, and five roundtrip profiles
per variant. Actual inverse RTL outputs are checked against transformed forward
coefficients. Random valid/ready/CE, stalled output stability, partial-block
reset, mode changes and terminal idle are checked. Fixed-point roundtrip maximum
error for the unsaturated low-amplitude fixtures is 2 LSB. Maximum unclipped
floating discrepancy in full-scale 16-bit fixtures is 35 LSB (coefficient
quantization amplified by DC gain); this is not a lossless transform.

Default isolated Gowin synthesis (`-noalu -nodsp`) maps the shared multiplier
into logic: 1599 LUT1-4, 67 MUX2_LUT5, 115 FF, 48 RAM16SDP4 and zero DSP.
CHECK reports zero problems. This verified flow satisfies the <=4 DSP bound
without relying on vendor DSP decomposition; a DSP-enabled map was not measured.
No P&R, clock target or board verification is claimed. Temporary simulation
and synthesis binaries are automatically removed; small evidence logs remain.
