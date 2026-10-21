# Zero-mean normalized template matching

`template_match_zncc.sv` implements full grayscale ZNCC, not SAD or an
unnormalized correlation substitute. The full-project RTL/manifest duplicate
search found only the distinct `wave2_ip_20k/match_sad` kernel.

Image WIDTH/HEIGHT parameters are 1..32 each. START atomically snapshots
runtime template width/height, each 1..8 and no larger than its image axis.
First supply exactly template_width*template_height bytes on `t_pixel`, then
exactly WIDTH*HEIGHT image bytes on `s_pixel`. Each stream has independent
valid/ready, SOF, EOL and LAST. SOF occurs only on its first sample, EOL on
each corresponding row end, and LAST only on its final sample. Image ready
is low during template capture. A new template is supplied for every START;
there is no hidden template persistence across transactions.

All legal windows are processed in raster order, without host-precomputed
moments or scores. For a window A and template B with N samples:

```text
numerator = N*sum(A*B) - sum(A)*sum(B)
VA = N*sum(A*A) - sum(A)^2
VB = N*sum(B*B) - sum(B)^2
denominator_q16 = floor(sqrt((VA*VB) << 32))
score_q15 = sign(numerator) * floor(
    ((abs(numerator) << 31) + floor(denominator_q16/2)) / denominator_q16)
```

The exact integer moments use the full template, with no mean rounding.
The 88-bit radicand and 44-step restoring square root preserve 16 fractional
denominator bits. This avoids the large relative bias that simply flooring
an integer square root would create for low-variance templates. A shared
32-cycle unsigned multiplier handles all products; a shared 64/44 restoring
divider normalizes scores. Input image and template memories have synchronous
clocked reads. Large resettable/asynchronous coefficient arrays are not used.

`m_score` is signed 17-bit Q15 in [-32768,+32768], representing [-1,+1].
It includes exact ±1. Halfway score magnitudes round upward (away from zero).
If either variance is zero, output score is exactly zero and `m_invalid=1`;
this is not a control-flow error. A 1x1 template consequently produces an
all-invalid map. OpenCV's constant-template policy can instead return 1;
it is deliberately not adopted or described as equivalent.

Output coordinates `m_x/m_y` name the window's upper-left pixel. The map
dimensions are WIDTH-template_width+1 by HEIGHT-template_height+1. Its SOF,
EOL and LAST refer to this map, not to the input image dimensions. Every
legal position emits a token, including invalid positions. The best match
only considers valid scores; signed scores are maximized, and exact score
ties choose the first raster position. `best_valid=0` with best score/x/y=0
means no valid match. Every accepted START, including invalid configuration,
clears all best metadata to prevent reuse of a preceding transaction.
Final best metadata is stable at held DONE until the next accepted START.

Transfers require CE and valid/ready. Result data/markers hold through CE
stalls and output backpressure. DONE follows consumption of the last map
token and remains held until CE-qualified done-ready. Busy includes pending
output and DONE. Active-low synchronous reset overrides CE, cancels the
transaction and gates ready low. It is the explicit abort mechanism. RAM
need not be cleared: every needed image/template sample is captured anew.

Error codes:

| Code | Meaning and recovery |
|---|---|
| 1 | Invalid image parameter or template geometry. No template/image/map transfer; best metadata is cleared. Acknowledge DONE, then START again. |
| 2 | Template SOF/EOL/LAST mismatch. Fixed-length capture and map computation still complete; every map token is marked invalid and best_valid stays zero. |
| 3 | Image SOF/EOL/LAST mismatch, same fixed-length recovery. Image error takes precedence if both streams were malformed. |
| 4 | Invalid internal control state; pending output is dropped and held error DONE is emitted. |

Missing samples wait for completion or reset. Acknowledge any terminal error
before another START; no reset/reconfiguration is required for recovery.
Scores computed from marker-invalid traffic are not valid match estimates.

Run from repository root:

```powershell
python -B cores/system/common_scaffold/image/template_match/run_tests.py
python -B cores/system/common_scaffold/image/template_match/run_synthesis.py
```

The independent integer oracle checks every score, coordinate, invalid bit,
map marker, final best location/score, and completion code. Fixtures cover
50 completed frames / 2313 map tokens, including maximum 32x32 image / 8x8
template and maximum 1024-token 1x1 map; random and near-constant inputs,
negative/perfect correlation, all-zero variance, ties, eight CE-low reset
phases with full recovery, six template/image marker error patterns,
configuration snapshot, backpressure, held DONE, and successful matching
followed by rejected configuration and no-reset healthy recovery. Invalid
configuration tests include template sizes within 1..8 that exceed the image.

Actual NumPy centered floating dot products independently check every valid
numerical fixture. The asserted score error is <= **1/32768** (one Q15 LSB).
The bound includes Q16 denominator flooring and score rounding, not merely
output quantization. A directed N=4 near-constant case has VA*VB=12 and
exposes the failure of low-precision integer-sqrt normalization. Actual
OpenCV TM_CCOEFF_NORMED is also executed; valid fixtures must differ from
the floating score by <0.002, with measured RTL/OpenCV error retained in
JSON. Its zero-variance behavior is explicitly excluded from equivalence.
The OpenCV and scikit-image template-matching sources were fetched; actual
URLs, bytes, UTC times and SHA256 are in `references.json`. No upstream code
is copied.

Measured maximum score errors are 0.00001525524 versus NumPy and
0.00001528860 versus OpenCV on the frozen fixtures, including the directed
low-variance case. These observed values do not replace the stated one-Q15-LSB
core numerical bound.

Isolated Gowin mapping passes `check`: 7x5 uses 1739 LUT1..4, 118 MUX5,
1026 FF and 14 RAM16SDP4; 32x32 uses 1709 LUT1..4, 103 MUX5, 1050 FF,
1 DPX9B and 8 RAM16SDP4. Both use zero DSP, far below 15K LUT-class /4 DSP.
Exact cells and RTL hash are in `synthesis_evidence.json`. This serial frame
engine does not claim video rate, subpixel output, arbitrary image/template
size, routed timing closure or board validation. Generated testbenches,
vectors, simulators and netlists are automatically removed with
TemporaryDirectory; only source, documentation and small evidence remain.
`freeze_hashes.json` freezes source/scripts/docs/reference metadata; mutable
test/synthesis reports have separate archival `snapshot_evidence_hashes.json`
and may be regenerated by the common regression.
