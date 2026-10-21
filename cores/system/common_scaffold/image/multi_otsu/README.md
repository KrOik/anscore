# Exact three-class multi-Otsu segmentation

`multi_otsu.sv` captures one 8-bit grayscale frame, computes its histogram, finds two thresholds that globally maximize the three-class Otsu between-class variance, and replays the same frame as three configured output levels. This is exhaustive objective optimization, not quantiles or fixed thresholds.

## Exact objective and ties

For candidate t0<t1 the classes are pixels <=t0, t0<pixel<=t1, and pixel>t1. All three classes must be nonempty. Let each class have count Ni and pixel sum Si. Maximizing between-class variance is equivalent, for the fixed frame, to maximizing:

```
score = S0²/N0 + S1²/N1 + S2²/N2 = A/D
A = S0²*N1*N2 + S1²*N0*N2 + S2²*N0*N1
D = N0*N1*N2
```

Each comparison uses the exact unsigned cross-products `A*best_D > best_A*D`. There is no division, floating-point comparison, fixed-point objective approximation or numeric error in the selection. Equal scores keep the lexicographically smallest (t0,t1). Thresholds inside an empty histogram gap define the same partition; the smallest threshold in each such equivalence interval is the preceding occupied intensity. The implementation therefore compresses nonzero histogram bins into cumulative records, and exhaustively visits all `(K-1)*(K-2)/2` distinct nonempty three-class partitions in ascending threshold order. K is stored in 9 bits so all 256 occupied levels remain valid.

At most 1024 pixels are supported. Histogram/prefix counts use 11 bits (including count 1024), sums 18 bits (max 261120). Pair-count factors are <=1024²/4=262144<2^19. D<=floor(1024³/27)<2^26. Since score<=1024*255²=66585600<2^26, A<2^52 and comparison cross-products are <2^78. A is stored in 64 bits, D in 32, and serialized products in 96 bits, so all declared operations are exact. The reused shift-add multiplier executes 11, 18, 20 or 32 steps according to the proven operand bounds.

Actual scikit-image may choose a different exactly optimal partition on a tie. For equal-frequency [0,80,160,240], this core picks (0,80), while installed skimage returns (80,160); both have the same exact optimal score, but some class labels differ. On uniform 0..255, this core picks (84,169), skimage (85,170); the exact objectives again tie, with two differing class labels. A threshold lying at a different position within an empty gap can also preserve every class. These cases are recorded, not hidden by changing the exact tie rule. Floating-reference equivalence on all inputs is not claimed.

## Configuration, pixels and metadata

MAX_SIDE is an elaboration parameter supporting 1..32 (default 32). Runtime cfg_width/cfg_height are each 1..MAX_SIDE. cfg_level0/cfg_level1/cfg_level2 are 8-bit output values that must be strictly increasing; all geometry and levels are snapshotted on accepted START.

Stream input is s_data/s_valid/s_sof/s_eol/s_last/s_ready. Stream output is m_data/m_class/m_valid/m_sof/m_eol/m_last/m_ready, where m_class is 0, 1 or 2 and m_data is the corresponding configured level. threshold0/threshold1 become valid before the first output and remain stable through successful DONE. Public control is clk/rst_n/ce, start_valid/start_ready, abort, done_valid/done_ready/done_error/error_code/busy.

Segmentation compares inclusive lower thresholds exactly as above. For host comparison use `np.digitize(image, thresholds, right=True)`. Output markers are regenerated in raster order.

START, source, output and DONE transfers require CE=1 and valid/ready. START is blocked while abort is asserted. Source readiness includes CE; output valid can remain high during CE=0, so receivers must only count enabled transfers. Output tokens hold through backpressure and CE pauses. Successful DONE holds until acknowledgement; another frame can start without reset. Late abort does not change a held successful DONE.

Frame, histogram and compressed prefix storage all use synchronous read ports. Histogram clearing precedes capture; accepted pixels are followed by explicit histogram read/modify/write states, with input backpressure until the update completes. Prefix and frame replay also use address/wait/value stages. Optimization is intentionally serialized, with potentially millions of cycles for all 256 occupied levels; this core makes no real-time video-throughput claim.

## Errors and recovery

SOF marks only the first pixel, EOL each row end, LAST only the final pixel. A marker mismatch fails immediately, including on partial capture: the caller need not finish the malformed frame. Fewer than three occupied intensities returns error with no output pixels, rather than silently reducing class count.

Errors: `80` zero/oversize geometry or static MAX_SIDE outside 1..32; `81` marker mismatch; `82` non-increasing output levels; `90` fewer than three occupied gray levels; `93` active abort; `94` invalid internal state. Error DONE holds until enabled acknowledgement. A subsequent healthy START clears the histogram and does not require reset. All errors invalidate the entire frame, including any already emitted pixels. Threshold metadata is not valid on error and is cleared on every accepted START.

Abort immediately suppresses output valid but is sampled into failure only at CE=1. Keep it asserted through an enabled edge; a pulse confined to CE=0 is not remembered. Synchronous reset is effective irrespective of CE. Invalid static MAX_SIDE safely allocates one unused frame entry and explicitly rejects START.

## Reproduce evidence

From repository root:

```powershell
python -B cores/system/common_scaffold/image/multi_otsu/test_multi_otsu.py
python -B cores/system/common_scaffold/image/multi_otsu/test_errors.py
python -B cores/system/common_scaffold/image/multi_otsu/synth.py
```

Normal tests passed 10 fixtures / 11 actual frames. The independent Python Fraction oracle enumerates every intensity threshold pair, including empty histogram bins, and checks the exact optimum and lexicographic thresholds. Every output byte/class/marker is compared; internal winning rational score and histogram total count/sum are independently checked. Actual installed skimage.filters.threshold_multiotsu(classes=3) is run, and its selected score is checked for exact equality to the independent optimum. Tie-related threshold/classification differences are explicitly recorded.

Fixtures cover 3-value data, nonzero minimum and large empty gaps, equal-objective different partitions, sparse random levels, near-white 252..255, all 256 occupied levels, 32x32 three-mode data, extreme counts 1022/1/1, row/column geometries, arbitrary valid output levels, source/CE/output stalls, post-START configuration mutation, no-reset repetition and held DONE. The all-256 fixture verifies the 9-bit level count, and exact objective checks prevent a surrogate partitioning rule from passing.

Error tests passed 32 complete healthy recovery frames plus static MAX_SIDE=0/33 rejection. Coverage includes malformed partial frames; geometry/level errors; zero, constant and two-level images with no output; a 32x32 flat frame explicitly checking hist[255], prefix count and total count are all 1024; abort during clear/capture/prefix/multiply/cross-comparison/output; CE=0 abort through CE=1; CE=0 reset during clear/capture/histogram RMW/prefix/multiply/comparison/frame read/output/DONE; error and CE=0 acknowledgement holds; abort-high START blocking; and forced invalid state. Every recovery frame checks real pixels, class labels, markers and thresholds.

Isolated full hierarchy `synth_gowin -nodsp; check -assert; stat` passed at MAX_SIDE=32:

| LUT1..4 | ALU | LUT+ALU+MUX | FF | RAM | DSP |
|---:|---:|---:|---:|---|---:|
| 1549 | 550 | 2164 | 1257 | 2 DPX9B + 2 SDPX9B | 0 |

ALU/mux are included in the budget. Source hashes agree across all evidence. references.json records fetched scikit-image documentation and actual installed function provenance. Large intermediate compilation, download and synthesis files use automatically cleaned TemporaryDirectory; only compact evidence/logs are retained. No routing, timing or physical-board acceptance is claimed.
