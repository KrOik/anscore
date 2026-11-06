# Numerical and resource contract

Let `D=2^BITS-1`, `K=2^GRID_LOG2`. For each channel x, the exact endpoint-aligned
coordinate is K*x/D. Choose lower=`x>>(BITS-GRID_LOG2)` and remainder
`(low_bits(x)<<GRID_LOG2)+lower`. This is exact: writing x=q*2^(BITS-G)+t gives
K*x=q*D+(q+K*t). The remainder is in [0,D], equals D only at x=D, and thereby
selects the final real cell with fraction 1 rather than a nonexistent cell K.
No approximate rescaling, division or iterative coordinate loop is used.

Sort remainders descending a>=b>=c with deterministic R/G/B tie priority.
Vertices start at lower=(r,g,b), increment the largest-fraction axis, then the
middle-fraction axis, then the smallest. Integer weights are D-a,a-b,b-c,c;
they are nonnegative and sum exactly D. For each output channel, S is the sum
of four node values times weights. Thus 0<=S<=D^2; every partial sum has the
same bound. Three unsigned BITS*BITS multipliers are reused across four nodes.
Products and accumulators each have 2*BITS bits, with a separate multiply and
accumulate state. No combinational multi-product chain is inferred by design.

The output is nearest integer `floor((S+floor(D/2))/D)`. D is odd, so an exact
half tie is impossible. With Y=S+floor(D/2), Y<2^(2*BITS). Split Y=q*2^BITS+r;
Y=q*D+(q+r), and q+r<2D. Therefore the exact quotient is
q + (q+r>=D). The final normalization uses an add, compare and correction,
without a general divider. The result remains in [0,D] with no wrap or clamp.

The independent oracle uses Fraction coordinates, an ordinary geometric sort,
four rational barycentric weights, and numerator/denominator divmod rounding.
It does not use the RTL coordinate or quotient-folding shortcuts.

Each bank is an independent array with one synchronous read and one synchronous
write interface. Reads select frame_bank; writes select load_bank, guaranteed
different while a frame is active. Reset only clears ownership/validity.
Bank activation is allowed only at IDLE command acceptance; no pixel can change
table midway through a frame, including when configuration completes under a
held output. Pending state prevents a second loader from overwriting unpublished
data. A held configuration response also blocks the next begin command.

Pixel states are CLASSIFY, then four repetitions of READ/CAPTURE/MULTIPLY/
ACCUMULATE, then ROUND/OUTPUT. A source transfer changes PIXEL to CLASSIFY;
the first valid output follows after 18 clocks. Its handshake at clock 19
permits the next source transfer at clock 20. Output or DONE stalls add their
actual duration; unbounded downstream backpressure has no finite completion
bound. The two memories hold only the cube, never an input/result frame.

Alternatives considered: reuse the existing exact trilinear block (same old
capability and eight reads), or parallelize all four vertices (RAM replication
or banking plus twelve products). The selected tetrahedral arithmetic adds an
independent color transform while using four sequential reads and three reused
products. Default LUT storage fits a modest on-chip budget on paper; largest
17-cube storage and mapping granularity need later synthesis, which is excluded
from this task. No physical Pareto or throughput claim is made.
