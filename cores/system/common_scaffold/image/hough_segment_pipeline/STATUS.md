# Status

PASS, staged outside the existing 80-core regression closure. No board/P&R/timing PASS is claimed.

Real hierarchy: binary-frame capture -> full polar Hough peak RAM -> per-candidate segment START -> synchronous source-frame replay -> candidate-associated finite support endpoints. Both frozen child RTL files are instantiated and mapped, without modifications or blackboxes.

Main tests: 8 fixtures, 2052 source pixels, 28 candidates, 3151 replay pixels and 38 segments. Every emitted token and every replayed source bit match independent expected results. Cases include all 16 candidate entries, multi-candidate cross lines, non-four-direction slopes, eleven separate segments, no peaks, full 32x32 dense input and noisy step-five angles. Actual OpenCV PPHT is invoked, with exact merged-line endpoint assertion.

Protocol: 40 healthy recovery frames; 6 frame-marker errors; 13 invalid runtime configurations; 12 CE-low reset phases; 6 child/internal error scenarios. Error during input capture and during frame replay terminates explicitly. Error on a real valid/ready output edge and error on a later candidate preserve the exact externally accepted prefix count. Artificial coincident final peak/DONE and final segment/DONE boundaries both pass. Internal/external output handshakes are compared at every rising edge. Eight invalid static parameter profiles pass with explicit configuration error.

Full flattened dependency synthesis plus check -assert PASS at 7x9/step5,16x16/step1,32x32/step1. Largest profile: 1600 LUT1..4,88 MUX2_LUT5,866 ALU,807 FF,196 RAM16SDP4,11 SP,2 SPX9 and 0 DSP. This is a complete hierarchy resource measurement, not a sum of isolated components.

No frozen child, shared runner, original 48 project, cryptographic module, board port or JTAG interface was edited. All large temporary files are automatically cleaned. Local sources/docs/ROM plus external child RTL/oracle/ROM/freeze hashes are recorded; mutable result reports remain reproducible rather than frozen.
