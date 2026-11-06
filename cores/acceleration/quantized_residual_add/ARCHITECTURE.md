# Architecture before execution

The operation joins two quantized inference branches with different input scales
and zero points. One exact scaled sum is rounded once. Independently requantizing
each branch before addition is not equivalent at half ties or cancellation.

Choose one shared9x17 signed multiplier, two product registers, a27-bit sum and
the unchanged three-stage `stream_requantize` with OUT_W28. That widened output
cannot saturate a27-bit numerator; output zero and activation interval are applied
after rounding. No divider, reciprocal table, DSP primitive or frame RAM is used.
Two separate input slots permit arbitrary branch skew up to one accepted beat;
later data is backpressured. Serial service is appropriate for a small area
inference engine; no full pixel-rate or device clock claim is made.

For U8 a,z and U16 S, `|(a-z)*S|<=255*65535=16711425`.
Each26-bit signed product retains the complete9x17 result. The exact sum magnitude
is at most33422850, safely inside signed27. RNE yields signed28; adding signed8
zero is performed in signed29. Shift0..31 is legal, including shifts>=27 which
round the scaled numerator to zero. Intermediate cancellation is exact, even
when either product would already saturate signed8.

Metadata is77 bits/channel: two U16 scales, shift5, two U8 input zeros and
signed8 output zero/min/max. One synchronous read per pair; config writes occur
only at idle. Default16 channels means1232 payload bits plus16 validity bits;
max64 means4928 plus64. Payload memory has no reset. Address and valid accesses
are bounded before narrowing. Small/deep physical RAM placement is tool dependent;
the bit counts are logical, not a BRAM assertion. Scalar input/product/output
registers and reused quantizer pipeline are additional. Risk LOW at defaults,
MEDIUM at max due to variable shift and serial branch coupling.

After the later input accepts at edge E, COLLECT detects both stored operands at
E+1, metadata reads at E+2, products register at E+3/E+4, sum at E+5 and quantizer
accepts at E+6. Its output is captured at E+9; public output is visible after E+9
and transfers no earlier than E+10. The next pair accepts no earlier than E+11:
always-ready pair II11 clocks. Command precheck consumes one clock per selected
channel. Configuration/command gaps, source skew and output stalls add time;
unbounded stalls imply no unconditional frame deadline. These are RTL schedule
counts to be checked by the finite TB, not hardware throughput results.

All existing sources are reused without edits. The example is an actual
boot-configured instance accepting two signed8 streams and computing sat8(A+B)
by exact signed8-to-affine-U8 XOR128 conversion. No historical hardware evidence
is inherited by this composition.
