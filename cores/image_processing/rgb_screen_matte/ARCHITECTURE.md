# Stage and arithmetic review notes

This document describes the draft original RTL; it is not an execution report.

| Stage | Arithmetic / ownership |
|---:|---|
|0| Capture absolute opponent differences9+9, RGB, excess/strength/screen channel, thresholds and metadata; capture O<I error |
|1| Two18-bit squares and one16-bit excess product; carry raw RGB/thresholds |
|2| Exact19-bit D2; nearest spill correction; corrected RGB |
|3| Classify invalid/hard/clamped/interior alpha; interior N=255*(D2-I) as27-bit shift-subtract, denominator O-I as19 bits |
|4..11| Eight fixed quotient bits, most significant first; carry corrected RGB and metadata |
|12| Exact nearest-even alpha from quotient and remainder |
|13| Three16-bit corrected-color*alpha products |
|14| Exact /255 color bytes and alpha; error override to zero |

All validity and metadata advance together only when the last stage is empty
or can retire. Each ratio stage has an independent registered remainder,
denominator, quotient, active bit and bypass-alpha byte. The same advance
condition gates the generated quotient stages and the main process. A bubble
does not create a new valid arithmetic result. rst overrides global stalls.

For an interior token0<n<d<=524287. N=255*n<255*d<256*d<2^27.
The first trial is d<<7, and one subtraction per bit successively leaves a
remainder below the next power-of-two trial. After bit0, 0<=remainder<d and
quotient=floor(255*n/d)<=254. Exact RNE can increment to255 but cannot wrap.
Hard/clamped/error paths carry active=0, denominator1, numerator0, quotient0
and a fixed-alpha byte through the same eight stages. No divide-by-zero or
data-dependent latency is introduced. Threshold values may exceed D2max.

For product p in[0,65025], nearest(p/255)=floor((p+127)/255). Let t=p+127.
The bounded exact fold is `(t+1+(t>>8))>>8`; all additions are17-bit.
There is no half tie for odd denominator255. Monotonic nearest rounding and
0<=C<=255 imply nearest(C*alpha/255)<=alpha.

The source declares one globally stalled fifteen-token pipeline. All x/y/tag,
three flags and32-bit user are carried at every stage, so metadata alone is
15*(67+TAG_W) logical register bits. The six multiplication expressions and
eight quotient stages are simultaneous hardware, not physical sharing. No
mapping attribute, vendor primitive, clock constraint or timing exception is
used. Platform fit is UNKNOWN; arithmetic/register mapping risk is MEDIUM,
and physical camera/display throughput is UNESTABLISHED.
