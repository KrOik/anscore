# B37 decision before RTL

Baseline46630205095a13ab95e1b5bebea0094c2a390390. New capability: normalize a
runtime-length signed8 activation vector about its own exact mean/variance,
then apply resident per-element affine quantization and emit signed8 outputs.
Repository actual-source searches covered144 released packages, operator_library,
ip_series, common_scaffold, DSP/ISP and YOLO. Existing block_vector_normalize
implements uncentered L2 scaling with no affine parameters; local image moments
and Wiener/Niblack operate on neighborhoods; none provides this inference service.
No old RTL is modified.

N1..256 (default64); normalization FRAC0..16(default12). An input code is a
signed integer; epsilon is unsigned16 in squared input-code units. Capture sums
S=sum(x), Q=sum(x*x), then form C=N*Q-S*S and T=C+N*N*epsilon exactly. The identity
(x-S/N)/sqrt(Q/N-(S/N)^2+epsilon)=(N*x-S)/sqrt(T) eliminates division of the
mean/variance and preserves sub-unit variance. No integer mean is rounded.

Selected serial design uses one existing unsigned32x32 CSA multiplier for four
moment products and each signed affine product (magnitude plus sign), a native
signed8 square, a bounded N*x product, existing fp_sqrt_iter/fp_div_iter and
stream_requantize. Fully parallel components would require replicated dividers
and memory reads; throughput requirements do not justify that structure here.
Each memory has separate capture/config and synchronous read phases, no reset
of payload and no read/write collision. Affine payload is37 bits/channel and
activation payload8; validity is1/channel. Default RAM2880 bits, max11520 bits,
plus scalar arithmetic and validity. BRAM inference and DSP mapping unmeasured.
Resource risk MEDIUM from serial service time, arithmetic paths and RAM granules.

RF=FRAC+2; r=RNE(sqrt(T)*2^RF); z=RNE((N*x-S)*2^(FRAC+RF)/r).
Output y=sat8(RNE(z*gamma/2^shift)+beta). Gamma/beta are signed16 and shift0..31,
resident per element. A32-bit clamp in the reused requantizer precedes beta;
any clamped magnitude remains outside signed8 after every legal signed16 beta,
so final y/clip equal this stated formula. Output inexact reports only affine
right-shift loss, not root/division approximation. T=0 uses z=0 with a degenerate
flag, yielding sat8(beta). This explicitly defined epsilon0 constant-vector
case is not a floating-point-framework equivalence claim.

C_W=max(0,ceil(log2(MAX_LEN))), sum width8+C_W, sumsq width16+C_W,
U width9+C_W, T width18+2*C_W. All products fit unsigned64; N*x-S fits U.
Division uses AW=U+RF, BW=ceil((T_W+2RF)/2)+1, FB=FRAC, OUT_W=FRAC+C_W+2.
Its positive denominator has a clear signed bit. Maximum iteration counts are
small enough for unchanged helpers (root<=35, divider<=51). Norm has magnitude
at most sqrt(N) plus staged rounding error, so the stated output width cannot
clip. No floating arithmetic or precomputed per-vector factor occurs in RTL.

Ordinary ready/valid, one clock, synchronous high public reset, no CE or CDC.
Private multiplier's CE is tied high; its asynchronous low reset follows !rst.
Config has priority over a simultaneous command and a held config response
blocks both new sources. The vector owns the service through its final output
retirement. Length/config errors emit one last marker without input admission;
malformed input LAST aborts with one marker and requires caller replay. Reset
invalidates affine parameters and cancels all in-flight work. There is no timeout.
An actual pipeline example combines an unchanged elastic32-to-signed8 RNE
requantizer and normalization, taking ownership before forwarding activations.
It permits one quantizer sample in flight, propagates LAST in the quantizer tag,
and accumulates input clip/inexact flags independently from affine flags. This
bounded adapter handles early-LAST aborts without buffering canceled suffixes.

No synthesis/PnR/STA/board/PPA or large regression. First finite check plan will
archive executable sources and deterministic vectors before any HDL tool call,
use20-second fail-stop children and preserve all raw evidence. No current PASS
claim: RTL_CANDIDATE/HW_UNVERIFIED until explicit first receipt exists.
