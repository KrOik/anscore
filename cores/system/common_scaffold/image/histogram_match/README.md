# Exact discrete grayscale histogram matching

`histogram_match_frame` loads a reference histogram, measures each input frame,
constructs a monotone lookup table and emits the entire remapped grayscale
frame. It implements histogram specification, distinct from histogram
equalization and CLAHE. Static BITS is 8–12, WIDTH/HEIGHT 1–4096 and
REF_COUNT_W 1–24. All 2^BITS bins are represented.

## Mathematical contract

Let reference bin counts be H[j], reference population M=sum(H)>0,
current frame population N=WIDTH*HEIGHT, and current bin counts G[i]. Define
inclusive CDF counts R[j]=sum(H[0:j+1]), C[i]=sum(G[0:i+1]). The exact LUT is

```
L[i] = lowest j minimizing abs(R[j]*N - C[i]*M)
output_pixel = L[input_pixel]
```

All representable target intensities j=0..2^BITS-1 participate, including empty
bins. Ties always choose the lowest intensity. In particular, leading zero-CDF
bins can make j=0 the closest candidate even if reference intensity zero never
occurred. Flat CDF plateaus choose their first intensity. This deliberate
discrete closest-CDF definition does not guarantee an exactly equal output
histogram: finite source counts and deterministic per-intensity mapping impose
quantization. LUT is nondecreasing, including unused source intensities.
Cross products use exact unsigned integers, without division or float error.

## Atomic reference interface

1. Present ref_begin_valid until ref_begin_ready. Begin is accepted only at a
   frame boundary after histogram clearing; source capture yields to begin
   when both are eligible on the same cycle.
2. Send exactly 2^BITS ref_count values in increasing intensity order using
   ref_valid/ref_ready. Zeros must also be sent. ref_last must be true only on
   the final bin. Counts may describe an arbitrary-sized reference frame and
   need not sum to the current frame population.
3. Present ref_commit_valid until ref_commit_ready after the final count.
4. Read held ref_result_valid/ref_error and acknowledge with ref_result_ready.
   error bit0 means empty reference; bit1 means invalid ref_last framing
   (or arithmetic overflow, excluded by legal width bounds). A nonzero error
   rejects the candidate and preserves the previously committed table.

CDFs are accumulated into an inactive RAM bank during load. Only a complete,
nonempty, correctly framed commit flips the active bank and population.
Source input remains stalled through loading and the held commit response.
An invalid early/missing ref_last does not shorten the fixed bin count; supply
the remaining bins or reset. No reference is valid after reset, so source
input remains blocked until the first successful commit.

Reference parameters and table bank are fixed throughout a current frame.
An upstream begin request may be held during a partial frame, processing,
output and held DONE. It does not block source progress and is accepted at
the next boundary. The test specifically covers this pending-request case.

## Frame protocol and recovery

All transfers require ce && valid && ready. Synchronous active-high reset
overrides CE, cancels pending work and invalidates reference state. Arrays
are not reset; no location is read before capture, clear, complete reference
commit or LUT construction writes it. First input must carry SOF and every
last-row pixel EOL; no other pixel may carry those markers. Fixed frame
geometry controls termination. A bad marker latches marker_error while
processing and all outputs continue. The downstream consumer must discard
the whole frame when DONE reports an error; this is not an abort policy.
Reset or supplying missing transfers is required if a frame is incomplete.

m_x/m_y are raster coordinates; m_sof/m_eol/m_last accompany valid data.
Payload remains stable during CE pauses and output backpressure. DONE and
frame errors are held until done_ready. After acknowledgement, the current
histogram clears before the next frame. The first accepted pixel clears old
frame flags. Reference commit flags have their separate result handshake.
arithmetic_error catches an unreachable failure to bracket the normalized
source CDF; no such event is expected for legal, committed counts.

## RAM, widths and throughput

Frame, current histogram, dual-bank reference CDF and LUT all have synchronous
RAM reads. Histogram updates use serial read-modify-write. A single bit-serial
shift-add multiplier computes both cross products, with zero DSP. Monotone
bracketing visits at most 2^BITS reference bins over the entire LUT; tracking
the first index of a lower CDF plateau preserves exact lowest-intensity ties.
No precomputed host LUT or asynchronous frame/coefficient RAM is used.

CW=ceil(log2(N+1)) holds all current counts and CDFs, including a completely
constant frame. RW=REF_COUNT_W+BITS holds every reference sum because
M<=2^BITS*(2^REF_COUNT_W-1)<2^RW. PW=RW+CW holds both CDF cross products
and all distances. Geometry up to 4096 squared is within integer parameter
arithmetic, but not necessarily within a selected FPGA's memory budget.
Storage bits are N*BITS + 2^BITS*(CW+BITS+2*RW). Reference load needs one
accepted beat per bin. LUT generation takes O(2^BITS*PW) enabled cycles;
full frame capture precedes output. This is a compact frame processor,
without a one-pixel-per-clock video-rate claim.

## Validation and limitations

```
python -B cores/system/common_scaffold/image/histogram_match/test_histogram_match.py
python -B cores/system/common_scaffold/image/histogram_match/synth_histogram_match.py
```

Python regression requires NumPy. Seven profiles/56 frames PASS: 664 exact
output pixels and all 51200 LUT entries checked. Used source intensities are
independently brute-force minimized over every target bin using Python big
integers, and NumPy object-integer argmin independently cross-checks each.
Full LUT uses a separate binary-search oracle. Coverage includes 8/10/12 bits,
REF_COUNT_W24 and >32-bit cross products, unequal populations, equal-distance
ties/empty bins, maximum reference counts, constant/ramp/bimodal/random
distributions, thin frames, atomic zero/invalid-last rejection, reference
begin priority and held mid-frame request, SOF/EOL faults, CE/input gaps,
output stalls, held reference result/DONE, and CE-low resets during reference
load, capture, active arithmetic and stalled output. Six invalid parameter
sets are rejected. Generated binaries, hex files and testbenches are temporary.

Isolated synth_gowin and CHECK PASS:

| Profile | LUT1–4 | LUT5 mux | ALU | FF | RAM primitive | DSP |
|---|---:|---:|---:|---:|---|---:|
| B8,32x32,reference count16 | 526 | 35 | 261 | 501 | 3 DPX9B + 1 SDPX9B | 0 |
| B12,64x48,reference count16 | 631 | 51 | 322 | 607 | 23 DPB | 0 |

No timing closure, whole-design resource, board or application acceptance
claim is made. Small JSON evidence is retained; all build intermediates are
removed. Baseline artifacts elsewhere in the repository were untouched.

## Public reference and compatibility

Successfully accessed 2026-10-19:
https://raw.githubusercontent.com/scikit-image/scikit-image/v0.24.0/skimage/exposure/histogram_matching.py
Its mathematical pipeline forms normalized cumulative counts, omits empty
reference bins and uses np.interp for continuous target intensity values.
This module instead minimizes exact discrete CDF error over all bins. It is
not bit-compatible with skimage. Regression computes the published
interpolation formula separately using NumPy: 212/664 fixture pixels differ,
with maximum absolute intensity difference 1024 (a 12-bit bimodal reference
with discrete tie selection). That audit runs the formula, not the installed skimage package.
The reference was consulted for comparison; no source implementation was
copied. Use this exact discrete contract when validating this hardware.
