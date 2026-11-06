# Numeric and ownership review

The alternatives considered were independent straight-channel bilinear
interpolation, premultiply-to8bit followed by an existing packed-lane scaler,
and full-precision alpha-coupled filtering. The first introduces transparent
color contamination; the second inserts an additional rounding boundary.
The selected direct formula retains full precision while the one-owned-token
budget allows one shared multiplier. No dense-video throughput was required.

Weights are17bit, with exact sum65536. Each alpha product and their sum are
bounded by255*65536=16,711,680 (24bit). Alpha×color is at most65,025 (16bit).
Each weighted color product and the sum over four taps are bounded by
65,025*65,536=4,261,478,400, strictly below2^32. Although the shared multiplier
register is34bit, every consumed color product fits32bit; alpha products
fit24bit. Those bounds cover all accepted unsigned byte/fraction inputs.

For color n, let h=floor(n/65536), l=n mod65536. Then
q=floor(h/255) is the full floor(n/(255*65536)); the remaining low part is
too small to increase the quotient when h mod255<=254. For h<=65025,
q=floor((h+1+floor(h/256))/256) exactly. The 24bit remainder is
`{h-q*255,l}` with its upper part0..254. Compare this to0x7f8000 and increment
on greater, or equality with odd q. This is RNE with a single final boundary.
Alpha uses its retained16bit remainder against0x8000. Maximum q255 always
has remainder0, so output cannot overflow. A and C RNE monotonicity preserves
premultiplied output without clipping a faulty intermediate.

Each tap takes17 calculation edges: weight setup/product/save3, weighted
alpha product/add2, three color product/setup/product/add sequences12.
Four taps plus one final quantization give69 edges to output valid. Shared
mul operands and product have explicit registers; accumulator addition never
shares an edge with consumption of an unregistered multiplication result.
No inferred data-memory port or target primitive is assumed by the filter.

The wrapper has one owner. It sends one integer query, consumes its response,
then sends the next of four; all occur under sampler resident ownership.
Only after four responses does it start filtering. Its filter output feeds
the old composition input atomically, and ownership survives the final held
composition result. A management offer is gated at the sampler boundary until
that owner retires. Allowing c_valid through earlier would suppress the
sampler's lookup ready and deadlock an owned query: the gate is therefore
required even when its lookup pipeline is temporarily empty.

The independent model uses Python arbitrary-precision sums and divmod on the
literal denominators. It does not use the RTL fold, cycle schedule, shared
multiplier algorithm or any imported project implementation. The core TB
checks absolute cycle latency and premultiplication invariants, metadata,
hold stability, cancellation and recovery. The real wrapper TB loads actual
resident banks and compares complete combined RGBA/error/OOB metadata to the
oracle; no mock sampler or mock composition is used.
