# Four-direction Census SGM

`stereo_sgm.sv` implements real semi-global matching over four cardinal paths: left→right, right→left, top→bottom, bottom→top. Inputs are already computed left/right Census descriptors, not grayscale pixels. See the repository integration for grayscale Census frontends. Existing `stereo_census_match_frame` implements local WTA; this new core preserves it and adds path regularization.

For each pixel p and disparity d, `C(p,d)=popcount(left(p) XOR right(x-d,y))`. A geometrically unavailable or flagged-border candidate has cost 1024. Each direction computes the exact integer Hirschmueller recurrence:

`Lr(p,d)=C(p,d)+min(Lr(prev,d),Lr(prev,d-1)+P1,Lr(prev,d+1)+P1,min_k Lr(prev,k)+P2)-min_k Lr(prev,k)`.

At each path boundary `Lr=C`. Out-of-range disparity neighbors are excluded. The output score is the **sum of all four Lr**, including four copies of the data term. Raster output chooses the smallest disparity among equally minimal scores, restricted to geometrically valid candidates whose left/right Census borders are clear. If no candidate is valid, disparity=0, score=16383 and invalid=1. No uniqueness, subpixel interpolation, left-right consistency, speckle filtering or depth calibration is claimed.

OpenCV StereoSGBM is a conceptual reference, not a bit-exact oracle: its default costs, path count, refinements, aggregation and numeric scaling differ. Here the independent Python oracle directly constructs all four full directional volumes. RTL tests compare **every aggregate bin**, as well as every selected disparity/score/invalid output. An explicit dataset differs from local WTA in 10 pixels, preventing a local-only algorithm from being mistaken for SGM. References and retrieved source hashes are in `references.json`; no reference code is copied.

## Interface and recovery

- Parameters: WIDTH/HEIGHT 1..256, frame pixels<=4096, DESC_BITS 1..64, DISPARITIES 1..min(WIDTH,64), output DISP_BITS sufficient for D-1. Larger legal configurations can exceed device RAM: synthesis only certifies the profiles below.
- `start_valid && start_ready` latches unsigned cfg_p1/cfg_p2; P1>P2 ends with error_code=1. P1/P2 each 0..255; P1=P2 and zero penalties are legal.
- After start, feed exactly WIDTH*HEIGHT paired descriptors and border flags using s_valid/s_ready, raster order. s_sof/eol/last must mark first pixel, end of each row, final pixel. A marker error stops immediately with error_code=2. No partial output is emitted on capture errors.
- Output m_valid remains asserted with stable disparity, score, invalid and markers until `ce && m_ready`. m_sof/eol/last describe raster position. done_valid appears after the last accepted output, or after an error, and is held until `ce && done_ready`.
- All state changes/handshakes require ce=1. Input/start ready are low during CE pause. Output/done valid remain asserted during CE pause; receivers must also respect ce. Synchronous active-low reset takes priority over CE, returns to idle, and discards incomplete frames. RAM is not reset; a complete subsequent capture overwrites descriptors, and first-path initialization overwrites all aggregate/path state before use.
- error_code=3 is an illegal FSM recovery path. There is no timeout for absent input or downstream backpressure. Start configuration changes during capture/traversal do not alter the latched penalties.

## Architecture, numerical bounds and limitations

Frame descriptor RAMs, one directional path volume RAM and one aggregate volume RAM have synchronous registered reads. The four passes reuse the same path RAM; traversal order guarantees each predecessor vector has been overwritten for the current direction before use. Candidate processing scans predecessor disparities serially to find the minimum and adjacent values, with no asynchronous coefficient array or RAM reset. Runtime is O(W*H*D²), with one slow serialized arithmetic engine; this prioritizes small resources over video-rate throughput. Default 16x8/D8 fixture takes about 110604 cycles including deterministic randomized CE/output stalls. No real-time or full-resolution throughput claim is made.

The minimum expression contains minprev+P2 and cannot be below minprev, so L lies in [C,C+P2], at most1279; four-path sum<=5116. A missing neighbor sentinel 3584 plus P1 cannot win against minprev+P2<=1534. 12-bit path and14-bit sum arithmetic are therefore exact. All tested profiles use0 DSP. Costs of invalid candidates remain finite to define path continuity across borders, but invalid candidates are excluded from final selection.

## Verification

```
python -B cores/system/common_scaffold/image/stereo_sgm/run_tests.py
python -B cores/system/common_scaffold/image/stereo_sgm/test_protocol.py
python -B cores/system/common_scaffold/image/stereo_sgm/test_numeric_limits.py
python -B cores/system/common_scaffold/image/stereo_sgm/synth_check.py
python -B cores/system/common_scaffold/image/stereo_sgm/freeze.py
```

10 functional frames/510 output pixels cover 1x1,1x9,9x1,full-width disparity,64-bit descriptors,maximum255 penalties,zero penalties,ties,all-invalid,shifted data and mixed border flags. All aggregate bins are checked; randomized CE and output backpressure are enabled. Protocol tests cover4 malformed configuration/marker errors, reset during capture/traversal/output stall and idle, plus2 complete recovery frames without reset. 11 invalid parameter sets are rejected. Test/synthesis result JSONs contain exact current RTL SHA256. Temporary simulations and Yosys outputs use TemporaryDirectory and are removed automatically.

Isolated `synth_gowin -nodsp` profiles are recorded in synthesis_result.json. Conservative LUT-class totals include ALU/MUX and4 LUT equivalents per RAM16SDP4: 8x6/D4=1579;16x8/D8=1265;32x16/D8=1288. BRAM primitive counts are preserved in the artifact. This is synthesis evidence only; no PNR, frequency, hold-time or board acceptance is claimed.
