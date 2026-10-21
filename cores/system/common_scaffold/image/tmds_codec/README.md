# DVI-compatible TMDS lane codec

Two original narrow synthesizable cores provide the missing readable TMDS encoding and strict decoding algorithms. Repository-wide code/content search found only an encrypted Gowin DVI_TX reference IP and wrappers under references/mic_xcorr, with no accessible reusable encoder/decoder algorithm. That existing encrypted IP was not modified or decrypted.

Scope is one DVI-compatible lane, 8-bit video and four control symbols. There is **no HDMI data-island/TERC4/guard-band protocol, serializer, differential PHY, clock generation, electrical interface or board verification**. Three instances may process blue/green/red lanes; ordinary DVI uses blue control={VSYNC,HSYNC}, green/red control=0. Whole-lane synchronization and a physical link remain the integrator's responsibility.

## ABI and CE

`tmds_encoder(clk,rst_n,ce,s_data[7:0],s_de,s_control[1:0],s_valid,s_ready,m_symbol[9:0],m_valid,m_ready,running_disparity signed[5:0])`.

`tmds_decoder(clk,rst_n,ce,s_symbol[9:0],s_valid,s_ready,m_data[7:0],m_de,m_control[1:0],m_error,m_valid,m_ready,synchronized,running_disparity signed[5:0])`.

All stream transfers are CE-qualified: accept only when CE && VALID && READY. READY can remain high while CE=0; these are internal elastic stream ports, not ungated AXI ports. Active-low reset is synchronous and overrides CE. Every core has one output holding register; when it is consumed, a new input can replace it in the same cycle. No token is dropped or duplicated. Data/metadata/VALID hold under backpressure or CE=0. There is no start/abort/DONE interface: continuous stream tokens carry their own video/control state. Reset explicitly cancels pending output.

Each accepted input produces one output token. State advances on accepted **input**, which may be ahead of the consumed output by one token. The signed running_disparity and decoder synchronized status therefore report the current input-processing state, not metadata attached to an already held output. No state changes merely because an input is offered while not accepted. With CE=1 and ready consumers, both directions sustain one token per clock after initial latency.

## Encode/decode semantics

Video DE=1 applies the transition-minimizing XOR/XNOR stage, then disparity-guided inversion. Running disparity is the signed sum of emitted video symbol ones-minus-zeros, reset to0 on each blanking/control token. Exhaustive reachability from0 yields exactly {-8,-6,-4,-2,0,2,4,6,8}; six signed bits provide margin. Control DE=0 ignores video data and emits:

| Control {C1,C0} | Symbol [9:0] |
|---|---|
|00|1101010100|
|01|0010101011|
|10|0101010100|
|11|1010101011|

Symbols are represented as natural ten-bit words; a future DVI serializer would transmit bit0 first. No serialization or pin behavior is implemented here.

Decoder reset begins unsynchronized. Any one of the four exact control symbols acquires/reacquires synchronization and resets disparity0. A video symbol before such a control produces an error token. While synchronized, the decoder inverts the symbol's two coding stages to recover a byte, then checks that re-encoding the byte at the current disparity exactly matches the symbol. This rejects invalid transition coding, wrong inversion/disparity choices and unsupported HDMI symbols rather than silently returning plausible bytes. Successful video outputs `m_de=1,m_data=byte,m_control=0,m_error=0`. Control outputs `m_de=0,m_data=0,m_control=C,m_error=0`. Invalid input outputs deterministic `m_de=0,m_data=0,m_control=0,m_error=1`, clears synchronization and disparity, and later video symbols remain erroneous until an exact control arrives. Error tokens obey the same ready/valid hold contract. This is symbol-level checking, not guaranteed detection of all bit errors: a corruption into another legal symbol or a control can remain undetected.

## Independent verification

```
python -B cores/system/common_scaffold/image/tmds_codec/test_encoder.py
python -B cores/system/common_scaffold/image/tmds_codec/test_decoder.py
python -B cores/system/common_scaffold/image/tmds_codec/test_protocol.py
python -B cores/system/common_scaffold/image/tmds_codec/test_throughput.py
python -B cores/system/common_scaffold/image/tmds_codec/test_rgb_roundtrip.py
python -B cores/system/common_scaffold/image/tmds_codec/test_reference.py
python -B cores/system/common_scaffold/image/tmds_codec/synth.py
```

The two first scripts are separate narrow core cases; the others are dedicated suites. `run_tests.py` also provides an aggregate main and the independent oracle/helpers. Python chooses transition coding using integer bit operations and computes new disparity from the **actual output ten-bit population count**, independently of the RTL's disparity-update algebra. Breadth-first witnesses produce every reachable disparity from control-reset0 without forcing DUT registers.

Encoder:30656 tokens, including all256 bytes at each of9 reachable disparities (2304 byte/state pairs), all4controls and24000 long data/control tokens. Decoder:51933 tokens, all1024 candidate symbols at each reachable disparity (9216 symbol/state contexts), every illegal context followed by additional unsynchronized video then control recovery. Every output token and every accepted-input disparity/synchronization state is checked, with CE gaps/backpressure and token hold assertions.

Protocol: synchronous reset while CE0/output stalled for all4controls; CE0 input not accepted even if READY high; full output register rejects more input; decoder error remains held and exact control reacquires. Throughput:4096 consecutive output cycles per direction, explicit no-bubble assertion (initiation interval1).

Actual three-lane encoder→decoder RTL chain:25600 RGB pixels,27201 total tokens per lane and81603 emitted symbols, independent symbol oracle plus recovered RGB/control oracle, separate lane consumer backpressure and common CE gaps. It tests the real RTL path rather than a host codec shortcut.

`test_reference.py` actually retrieves the pinned ProjectF encoder implementation, verifies its SHA, compiles its functional RTL in TemporaryDirectory and compares all30656 encoder outputs bit-for-bit. Only diagnostic `$display` lines are removed in that temporary reference to limit output storage; no functional statement changes. The downloaded source and simulator are removed after the comparison. This external implementation comparison supplements the independent oracle.

## Resources and evidence

Isolated Gowin `synth_gowin -nodsp; check -assert`: encoder119 LUT-class, decoder127 LUT-class; both0 DSP and0 conservative BRAM9. LUT-class sums LUT+ALU+MUX+4*RAM16SDP4; each block RAM primitive including SP/SPX9/ROM would count as2 BRAM9. No RAM is used. No P&R/clock-rate/board/physical-link claim.

Actual pinned ProjectF and hdl-util/hdmi source URLs, commit, SHA, byte counts and small algorithm excerpts are in references.json; the latter is compared only for its DVI video/control subset. References are not a claim of full HDMI support. The RTL is independently written. All large vectors, downloads, compiled simulators and synthesis intermediates use TemporaryDirectory (current machine TEMP is C:, not storage-constrained D:); source/evidence on D: is small. source_freeze.json binds both RTLs, tests, docs and references, and final_validation.json verifies current report source bindings. Existing artifacts remain untouched.
