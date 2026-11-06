# Architecture review (source only)

The useful capability is exact sparse-triangle perspective attributes. A float or
reciprocal-LUT implementation would add approximation and verification choices;
a parallel divider/multiplier design would increase area for unspecified throughput.
This version spends cycles on one reusable unsigned24x24 multiplier and two bounded
8-step shift/subtract quotient loops. Three q values are runtime vertex inputs;
six q*U/V coefficients are prepared once per successful configuration. A common
reciprocal scale cancels exactly. No projection matrix or per-query reciprocal is
required. Multiplication is registered into operand registers and consumed in a
separate state; synthesis mapping and DSP count remain unknown.

The core uses:

- One24x24 product expression, magnitude plus independent sign for geometry.
- Three24-bit edge weights, six24-bit q*UV coefficients, three q registers and
  original coordinate/UV configuration registers.
- One42-bit denominator, two50-bit numerators, one50-bit remainder/trial datapath,
  an8-bit quotient, small FSM and metadata registers.
- No framebuffer, vertex list RAM, external memory, vendor primitive or initialized
  payload memory. Configuration arrays are guarded by valid state rather than reset.

All geometric deltas fit signed13. A coordinate delta is at most1023; a doubled
query-to-vertex displacement has magnitude at most1535. Each signed product is
therefore below2^21 and an edge difference below2^22; the24-bit magnitude and26-bit
signed cross datapaths retain it exactly. Accepted triangle area magnitude is at
most1023^2; nonnegative opposite edges at an inside point sum to twice that area,
below2^21. Positive q is at most65535, so D<2^37. U/V are convex weighted values
0..255; each full numerator is below2^45. The42/50-bit accumulators and full48-bit
product are conservative. Product slices used by geometry/denominator do not lose
reachable significant bits. q*UV<=65535*255<2^24. Trial D<<7 fits50 bits, and51-bit
twice-remainder comparison retains the RNE tie. Since a nondegenerate covered point
has positive D, there is no divide-by-zero branch in the owned query datapath.

Inside query work is nine geometric-product states, one coverage state, eighteen
MAC states, one division-init state, sixteen quotient states and two rounding
states:47 edges after acceptance to output valid. Outside stops at edge-check10.
Configuration uses3 area states +12 coefficient states=15. The one-result holder
adds retirement and return-to-ready edges; latency is not initiation interval.
Backpressure directly extends service time. No frequency is assumed.

The wrapper adds genuine unchanged raster cost: its coverage setup, per-covered-
fragment three RGB calculations (even though constant zero), bounding-box scan,
and scan advancement. Projector and sampler processing start only for covered
fragments. One fragment token prevents end-of-triangle completion overtaking a
held texture result. Texture write/lookup modes remain exclusive in the unchanged
sampler, with synchronous index then palette reads. There is no hidden frame RAM.

Sampler storage is8*TEX_WIDTH*TEX_HEIGHT +32*256 logical bits, with no reset of
payload arrays. Default40,960 and maximum532,480 bits need device-specific BRAM
packing confirmation; no physical BRAM count is asserted. Core architecture risk
LOW; wrapper default LOW/MEDIUM and maximum MEDIUM because of resident texture
memory and inherited multi-cycle raster cost. These are structural judgments,
not synthesis area or timing evidence. Width restrictions keep arithmetic scale
fixed; only sampler memory grows with texture dimensions.

Finite checks will establish behavior only for listed deterministic profiles and
vectors. Maximum dimension testing uses sparse6x6/3x3 triangles and repeated full
runtime texture loads, not every screen coordinate or all vertex/q combinations.
Any LUT/DSP/Fmax/power/PPA or real-time frame service claim requires a separate,
explicitly authorized downstream flow; none is part of this package.
