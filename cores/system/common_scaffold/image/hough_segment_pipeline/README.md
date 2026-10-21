# Automatic complete Hough-to-segment frame pipeline

`hough_segment_pipeline.sv` implements an actual transaction chain:

1. Accept one complete binary edge frame. Store every accepted bit in local synchronous-read frame RAM while feeding the same transfers to the frozen complete polar Hough core.
2. Accept and store **all** selected polar peaks in a 16-entry candidate RAM. Wait for successful polar completion before starting endpoint extraction.
3. Read each stored theta/rho pair, start the frozen segment extractor with that candidate, and regenerate SOF/EOL/LAST while replaying the entire original frame from synchronous RAM. Repeat independently for every candidate.
4. Emit real support-point endpoints with their candidate index, theta, signed rho, segment index, support count and exact squared endpoint length. Hold each token under output backpressure. Complete only when the final candidate's segment extractor has completed.

This is automatic peak-to-endpoint composition, not two parallel independent IP instances. The caller sends the source frame exactly once and does not supply candidate angles or replay data. Every replayed bit and every emitted token is checked in full-hierarchy simulation. Candidate peaks that produce zero qualifying segments still consume one replay and advance normally. A no-peak frame returns successful completion without starting the segment extractor. Different candidates can describe overlapping segments; cross-candidate deduplication is intentionally not part of this interface.

## Configuration and numeric conventions

WIDTH/HEIGHT are each 1..32. THETA_STEP defaults to 1 for all 180 integer normal angles; legal values are positive divisors of 180 up to 90. `TRIG_FILE` is passed to both children; default is the local `trig.mem`. The ROM matches the frozen children exactly.

START snapshots all runtime configuration. Polar parameters: threshold 1..1024 raw votes, max_candidates 1..16, theta_nms/rho_nms 0..90 inclusive. Endpoint parameters: rho_tolerance 0..3 rounded bins, max_gap 0..31 missing dominant-axis positions, min_length 1..44 Euclidean pixels, min_support 2..32 representatives, max_segments 1..32 **per candidate**. Invalid values return explicit error without consuming a frame. Changes after accepted START have no effect on the current frame.

The frozen polar transform uses signed rho `round_away((x*cosQ14(theta)+y*sinQ14(theta))/16384)` with upper-left origin. It performs global maximum selection, deterministic theta/rho tie breaking, and theta-wrap/rho-sign-aware NMS. The segment extractor scans actual support pixels in dominant-axis order, chooses the minimum normal residual representative at each coordinate (lower perpendicular coordinate breaks ties), groups with max_gap, and tests real endpoint distance/support thresholds. See the frozen child READMEs for their complete numeric definitions. This pipeline does not substitute line-rectangle intersections for endpoints, probabilistically sample the edge image, or claim bit identity with OpenCV PPHT.

## Handshakes and errors

All transfers require a rising clock edge with CE high; input ready includes CE. Synchronous active-low reset overrides CE in the wrapper and both children. A reset held while CE is low cancels the transaction and clears counters/validity. Memories are not reset; each accepted source frame is fully overwritten before replay. START readiness requires the wrapper and both children to be idle.

Input binary edge tokens use SOF on exactly the first pixel, EOL on each row end, and LAST on exactly the final pixel. The full polar child validates markers and returns a frame error after consuming the complete frame, with no output prefix. Local capture and polar input share exactly the same valid/ready acceptance.

Output `m_valid/m_ready` carries `m_theta`, signed `m_rho`, `m_candidate_index` (0..15), `m_segment_index` (zero-based within candidate), `m_x1,m_y1,m_x2,m_y2`, `m_support` and `m_length_squared`. Internal child output readiness and external output validity use the identical reset/phase/error enable, so an error edge cannot secretly consume an internal token or falsely report an external transfer. `emitted_segments` counts actual CE-qualified external handshakes; `detected_candidates` counts stored peaks. Output tokens remain stable while stalled. Payload outside valid is not a token and becomes zero outside the output phase.

`done_valid` remains held until CE and done_ready. `busy` includes completion. No new source frame is accepted until completion is acknowledged. Every accepted START, including rejected configuration, clears counts, error and candidate metadata. There is no abort port.

Error codes: 0 success; 0x01 invalid wrapper/static configuration; 0x10 OR polar-child error code; 0x20 OR segment-child error code; 0x30 impossible candidate table overflow; 0x40 illegal wrapper controller state. Child errors are monitored during all active phases, including capture and replay, to prevent blocked child-ready from deadlocking the wrapper. FAILED resets both children even with CE low, allowing a healthy transaction after error acknowledgment without an external reset.

An internal failure on a later candidate may occur **after earlier endpoints were accepted**. Such tokens are provisional until successful DONE; consumers must discard the entire transaction on error. The accepted-prefix count remains truthful on failure and is tested at the exact error edge. The pipeline does not claim rollback of already accepted tokens. Natural children separate their final output and completion; the wrapper is additionally tested with artificial simultaneous final-token/completion events.

## Reproduce

From repository root:

```powershell
python -B cores/system/common_scaffold/image/hough_segment_pipeline/run_tests.py
python -B cores/system/common_scaffold/image/hough_segment_pipeline/test_protocol.py
python -B cores/system/common_scaffold/image/hough_segment_pipeline/test_invalid_parameters.py
python -B cores/system/common_scaffold/image/hough_segment_pipeline/synth_check.py
```

The independent end-to-end oracle composes the frozen bin-exhaustive polar oracle with the coordinate-sort segment oracle. It never reads RTL state to compute expected geometry. Main tests instantiate both real children and verify every accepted endpoint, candidate association, every bit of every RAM replay, candidate count and output count. Actual OpenCV HoughLinesP runs for every fixture; the merged-line fixture asserts exact endpoints. Other outputs are retained for comparison without claiming identical candidate selection/NMS/PPHT semantics.

Synthesis reads the wrapper and **both complete frozen children**, maps the flattened hierarchy and ROM/frame/accumulator/candidate memories, then runs check -assert. It does not sum unrelated estimates or blackbox the processing. Results are isolated area evidence; no P&R, timing or board PASS is claimed. This staged directory is not registered in the existing 80-core regression closure. No shared runner, frozen child, original 48-core project or board interface was modified. All large generated files live in TemporaryDirectory and are automatically removed. Only compact JSON/source/docs/ROM delivery assets remain.
