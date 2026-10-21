# Niblack local grayscale binarization

`niblack.sv` implements same-frame Niblack thresholding with local mean and standard deviation. The convention matches scikit-image:

```
T = mean - k * standard_deviation + bias
foreground = 255 if center_pixel > T else 0
```

The comparison is strictly greater: exact equality is background. This is distinct from Sauvola and from mean-only thresholding. Positive k lowers the threshold; negative k raises it.

## Configuration and numerical definition

Input grayscale is unsigned 8-bit. Runtime width/height are 1..MAX_SIDE; the elaboration parameter MAX_SIDE supports 1..32 (default 32). `cfg_window5=0` selects 3x3, and 1 selects 5x5. Borders replicate the nearest input pixel. Signed `cfg_k_q8` is Q8, valid -1024..1024 inclusive (k=-4..4); signed `cfg_bias_q8` is Q8 with its full 16-bit range (-128..127.99609375). All configuration is snapshotted at accepted START.

Let n=9 or 25, S=sum(pixel), Q=sum(pixel²), V=n*Q-S². The mean is exactly S/n, variance exactly V/n², with no premature mean rounding. A serial integer square root computes `R=floor(sqrt(V*65536))`, retaining sqrt(V) in Q8. The hardware tests the signed scaled inequality:

```
center*n*65536 > S*65536 - k_q8*R + bias_q8*n*256
```

No pixel-domain threshold rounding is introduced. For k=0, the mean comparison is exact; constant frames with bias=0 produce all background. The standard deviation error is less than 1/(256*n), and threshold error is less than abs(k_q8)/(65536*n), at most 0.00173612 gray levels over the supported configuration. Error is one-sided according to k's sign. A pixel closer than this bound to the real threshold can classify differently from a floating reference; arbitrary-input floating binary equivalence is not claimed.

Directed measured example: 3x3 `[[254,250,253],[249,255,248],[250,253,248]]`, k_q8=1024, bias_q8=3570 has center 255. Floating T=254.9997938342 gives foreground; fixed T=255.0008680556 gives background. This intentional precision boundary is tested, recorded as exactly one reference classification difference and bounded numerically. All outputs remain exact relative to the declared integer contract.

S uses 13 bits, Q 21 bits, V 32 bits, sqrt radicand 48 bits, root 24 bits, and scaled signed threshold/product arithmetic 48 bits. These bounds cover full pixels and supported configuration. Generic products use a reused 16-cycle shift-add unit; square root uses 24 restoring steps. Pixel squaring is a narrow 8-bit operation.

## Stream and error contract

The public stream ports are s_data/s_valid/s_sof/s_eol/s_last/s_ready and m_data/m_valid/m_sof/m_eol/m_last/m_ready. Control ports are clk/rst_n/ce, start_valid/start_ready, abort and done_valid/done_ready/done_error/error_code/busy, plus the configuration ports above.

START, input, output and DONE transfers require CE=1 and valid/ready. START is blocked while abort is high. Source readiness includes CE; output valid may remain high while CE=0, and receivers must only count enabled transfers. Output data and markers hold through backpressure and CE pauses. A full frame is captured into synchronous RAM, then neighborhoods are read using explicit address/wait/sample states. No asynchronous frame read or one-pixel-per-clock claim is made.

SOF marks only the first pixel, EOL each row end, LAST only the final pixel. Malformed markers fail immediately, even on a partial frame; the caller need not supply the rest of that frame. All errors invalidate the whole frame, including any pixels already emitted before an abort. DONE/error remains held until enabled acknowledgement; the next healthy frame requires no reset. Held successful DONE ignores late abort.

Abort immediately suppresses output valid, but failure is sampled at CE=1. Hold abort through an enabled edge; a pulse confined to CE=0 is not remembered. Synchronous reset works regardless of CE. RAM is not reset and a healthy capture overwrites every address subsequently read.

Errors: `80` invalid geometry or static MAX_SIDE outside 1..32; `81` marker mismatch; `82` k outside the supported signed range; `93` active abort; `94` invalid internal state. Illegal static parameters allocate only one unused RAM entry and explicitly reject START; they cannot silently truncate an image.

## Verification and resource evidence

Run from the repository root:

```powershell
python -B cores/system/common_scaffold/image/niblack/test_niblack.py
python -B cores/system/common_scaffold/image/niblack/test_errors.py
python -B cores/system/common_scaffold/image/niblack/synth.py
```

Normal verification passed 18 fixtures / 19 actual frames. Every binary pixel and marker, and every local sqrt(V) Q8 value, is compared with an independent Fraction/isqrt oracle calculating centered variance directly. Actual installed skimage.filters.threshold_niblack is run on explicitly edge-padded input and cropped output, matching replicate borders; its default reflect boundary is not silently assumed equivalent. The first 17 fixtures match floating binary output exactly; the additional deliberate quantization fixture records the single bounded classification difference described above.

Coverage includes 3x3/5x5, signed k extremes, both bias extremes, 32x32, positive/negative k, low-contrast 254/255 and other near-white patches, constants, strict equality with k=0/bias=0, black, impulse, singleton/row/column, source/CE/output stalls, configuration mutation after START, no-reset repetition and held DONE. Changed outputs versus k=0 mean-only filtering explicitly demonstrate standard-deviation influence.

Error verification passed 22 complete healthy recovery frames, plus explicit static MAX_SIDE=0/33 rejection: zero/oversize geometry, illegal positive/negative k, partial marker errors, capture/multiply/sqrt/output abort, CE=0 abort through CE=1, CE=0 reset during capture/RAM/multiply/sqrt/output/DONE, held errors and CE=0 acknowledgement, abort-high START blocking and forced invalid state. Every recovery pixel/marker is checked.

Isolated full hierarchy synthesis `synth_gowin -nodsp; check -assert; stat` passed at MAX_SIDE=32:

| LUT1..4 | ALU | LUT+ALU+MUX | FF | RAM | DSP |
|---:|---:|---:|---:|---|---:|
| 1019 | 579 | 1659 | 460 | 1 DPX9B | 0 |

ALU/mux are included in resource accounting. Evidence and freeze files bind source hashes. references.json records fetched scikit-image documentation and the actual installed reference-function provenance. Large intermediate simulation/synthesis/download artifacts use automatically cleaned TemporaryDirectory; compact logs/evidence are retained. There is no routing, timing or board acceptance claim.
