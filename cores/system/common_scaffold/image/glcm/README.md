# Four-direction gray-level co-occurrence matrices

`glcm_frame` builds four exact GLCMs from a grayscale frame, emits every matrix
entry including zeros, and emits contrast, dissimilarity and angular-second-
moment numerators with exact normalization denominators. This is a texture
statistics core, distinct from the existing LBP core.

## Quantization, pairs and configuration

Static BITS is 8–12, WIDTH/HEIGHT 1–4096 and LEVELS 16 or 32. Quantization keeps
the most significant log2(LEVELS) bits: `q=pixel>>(BITS-log2(LEVELS))`.
The runtime cfg_distance (12-bit unsigned) and cfg_symmetric are sampled only
with the first accepted pixel. Changes during capture or processing are ignored
until the next frame. Distance 1–4095 is valid; zero latches config_error,
consumes the fixed frame and emits four all-zero matrices and zero features.

With x increasing right and y increasing down, direction codes and offsets are:

| Code | Name | Neighbor offset |
|---|---|---|
| 0 | 0 degrees | (+d,0) |
| 1 | 45 degrees | (+d,+d) |
| 2 | 90 degrees | (0,+d) |
| 3 | 135 degrees | (-d,+d) |

Each actual source pixel contributes only when its neighbor is inside the
frame. There is no replicate/mirror/zero-padded pair. Increment C[qsource,qneighbor]
once. When symmetric is true, also increment C[qneighbor,qsource], **including
two increments to the same diagonal entry when levels are equal**. pair_total
is the sum of all emitted counts, so symmetry doubles the physical pair count.
Before symmetry, totals are H*max(W-d,0), max(W-d,0)*max(H-d,0),
W*max(H-d,0), and max(W-d,0)*max(H-d,0), respectively. Thin or tiny frames can
have zero pairs in some or all directions without an error.

## Exact features and output order

For a direction, let T=sum(C) and i,j denote the quantized matrix levels:

```
contrast_numerator = sum(C[i,j]*(i-j)^2)
dissimilarity_numerator = sum(C[i,j]*abs(i-j))
energy_numerator = sum(C[i,j]^2)
energy_denominator = T*T
feature_pair_total = T
```

For T>0, normalized contrast and dissimilarity divide their numerators by T.
`energy_numerator/energy_denominator` is ASM, also called energy squared.
Standard scikit-image `energy` is sqrt(ASM); this core does not compute that
square root. The raw energy port name must not be confused with the normalized
square-root feature. Matrix probability is C/T. Homogeneity, correlation and
entropy are not implemented. For T=0 all numerators and denominator are zero,
zero_pairs is true, and normalized features are undefined; the consumer must
check the flag rather than divide by zero.

Directions run in code order. For each direction, matrix outputs traverse
row i then column j, both increasing. m_direction_last marks its final entry,
and m_last marks the final entry of direction3. m_pair_total is stable throughout
that matrix. A separate feature_valid/feature_ready transfer follows the entire
matrix. feature_direction and feature_last identify it. The next direction
starts only after feature acceptance. DONE follows all four accepted features.
No simultaneous matrix/feature transfer is required from the consumer.

## Protocol, faults and reset

All transfers require ce && valid && ready. Synchronous active-high reset
overrides CE and cancels capture, arithmetic and pending outputs. Source stalls
while processing/output/DONE is pending. m_valid and feature_valid payloads
remain stable under their independent backpressure and CE pauses. DONE and
error flags are held until done_ready. busy covers partial input and later
states. Ignore payload outside its valid handshake.

SOF must mark only the first pixel; EOL every last pixel of a row. Incorrect
markers latch marker_error, but fixed geometry still consumes the entire frame
and emits all results. At DONE the consumer must discard the whole erroneous
frame. This is not fail-stop/abort behavior. Lost transfers require completing
the fixed input count or reset. The first accepted pixel clears prior frame
errors and snapshots new configuration. arithmetic_error catches a counter
overflow, excluded by legal bounds below. Runtime distance0 is a separate
configuration error with explicit zero-result behavior, not silent distance1.

## Architecture and integer bounds

The frame stores only quantized levels in synchronous RAM. One synchronous
counter RAM is cleared and reused across directions, with serial read-modify-
write including a second transaction for symmetric pairs. All frame and count
reads are synchronous. Arrays are not reset; capture and clear write every
required location before use. A single shift-add serial multiplier computes
the three feature terms and denominator; small squared differences use bounded
shift-add logic. Zero-count bins bypass multiplication but still emit their
matrix entry. There is no precomputed host matrix or placeholder statistic.

Let P=W*H, LB=log2(LEVELS), CW=ceil(log2(2*P+1)), FW=2*CW+2*LB+1.
Counts and T are at most 2*P and fit CW. Contrast <=T*(LEVELS-1)^2 fits
CW+2*LB; dissimilarity <=T*(LEVELS-1) fits CW+LB. Sum(C^2)<=T^2 fits
2*CW, including intermediate prefix sums. Thus every product and sum fits FW
without intended truncation or saturation. LB/CW/FW are exposed only to derive
Verilog port widths: initial guards require their exact derived values and reject
arbitrary overrides. Maximum supported geometry stays within parameter integer
arithmetic, but may exceed a chosen device's RAM capacity.

Storage is P*LB + LEVELS^2*CW bits. This is a frame-buffered, resource-conscious
serial processor, not a one-pixel-per-clock video-rate pipeline. Per direction,
work is O(P+LEVELS^2+z*FW), with z the number of nonzero matrix entries;
backpressure and CE pauses add latency. Hardware division, logarithms and
floating point are not used.

## Validation

```
python -B cores/system/common_scaffold/image/glcm/test_glcm.py
python -B cores/system/common_scaffold/image/glcm/synth_glcm.py
```

Regression requires NumPy and scikit-image (tested actual version0.25.2).
Six profiles/48 frames PASS: 98304 exact matrix counts and 192 exact feature
records, including 108 zero-pair records. Scalar Python pair enumeration and
independent NumPy grid/masked scatter agree. 168 valid-distance directional
matrices also match actual graycomatrix. On 84 nonempty directional records,
actual graycoprops contrast/dissimilarity/ASM/energy match the normalized
integer numerators to floating tolerance 1e-12.

Coverage includes BITS8/10/12, both LEVELS values, flat black/full-scale,
ramps/checkerboard/random/diagonal texture, distance1/2/4095, symmetric/asymmetric
and diagonal double count, single pixels/rows/columns, first-pixel runtime
configuration snapshot, invalid distance0, SOF/EOL faults, input gaps,
independent matrix/feature stalls, CE pauses, held DONE, and CE-low reset during
capture, matrix read/arithmetic and stalled output. Nine illegal parameter
sets including LB/CW/FW overrides are rejected. Temporary hex/binaries/testbenches
are removed; only small evidence JSON files persist.

Isolated synth_gowin and CHECK PASS:

| Profile | LUT1–4 | LUT5 mux | ALU | FF | RAM primitives | DSP |
|---|---:|---:|---:|---:|---|---:|
| B8,32x32,LEVELS16 | 591 | 33 | 315 | 378 | 1 DPB + 1 DPX9B | 0 |
| B12,64x48,LEVELS32 | 664 | 40 | 357 | 426 | 2 DPB + 1 DPX9B | 0 |

No timing closure, integrated budget, board or application acceptance is claimed.

## Public reference and offset compatibility

Successfully accessed 2026-10-19:
https://raw.githubusercontent.com/scikit-image/scikit-image/v0.24.0/skimage/feature/texture.py
(`graycomatrix` mathematical/protocol documentation). No implementation was
copied. scikit-image specifies polar radius/angle with rounded sine/cosine
offsets. Our distance d is an integer coordinate displacement: a diagonal
offset has Euclidean length sqrt(2)*d. Actual-package tests therefore use
radius d for axis directions and sqrt(2)*d for diagonal directions. Using
the same numeric polar radius d at 45/135 degrees is not generally equivalent.
Graycomatrix input is the already-MSB-quantized image, levels explicit,
symmetric as configured and normed=False. The distance0 rejection behavior
is our interface policy, not a claim about scikit-image's distance0 behavior.
