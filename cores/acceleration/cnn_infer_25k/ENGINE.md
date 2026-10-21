# Complete scalar CNN scheduler

`rtl/cnn_serial_engine.v` executes the complete SPEC network through one
`int8_dot_stream`. It reuses that arithmetic boundary for both convolutions and
dense output. Tensor,weight and bias memories have registered reads; tensor
arrays have no asynchronous read. Two byte arrays hold the input/pooled tensor
(784bytes) and current quantized feature map (3136bytes). Weights4244bytes and
22signed32biases are host-loaded. No full32-bit accumulator frame is stored:
each result is quantized and written before computing the next dot.

Loader region0 is input,1 weights(conv1,conv2,dense concatenated),2 biases.
Addresses must be sequential from0; writing0 restarts completeness for that
region. Invalid region/address/order returns a one-cycle load_error without
writing. Loader ready is low during inference,held completion or simultaneous
start. A run requires every region complete. Weights/biases survive runs;
each run consumes input completeness because pooling reuses that RAM. Reset
invalidates all completeness,without needing to clear tensor/weight memories.

Every layer value is exported as a ready/valid tap: stages0/1 conv1 accumulator/
quantized byte,2 pool1,3/4 conv2 accumulator/quantized byte,5 pool2,6 scores,
7 Top3. Index is the HWC/score index in SPEC. Data is signed32 (byte taps are
zero-extended). Taps hold all fields while stalled and pause scheduling.
Completion is held until done_ready. done_error1 means incomplete loads;
dot errors map to4+dot_error (overflow7). Early dot overflow is consumed before
the scheduler attempts further operands,preventing a deadlock.

Commands after scripts/env.ps1:

```powershell
python cores/acceleration/cnn_infer_25k/tools/test_engine.py
python cores/acceleration/cnn_infer_25k/tools/synth_engine.py
```

Current simulation `engine_20261020T190201402467Z` PASS: ramp,checker and impulse
inputs,31791exact accumulator/quant/pool/score/Top3 values; one loaded weight
set reused without reset. Random tap stalls,held completion,invalid loader,
incomplete/stale input and deliberately overflowing bias are exercised.
All registers run at CE=1. Dot supports II1; scheduler intentionally fetches
one term in three clocks and is not a one-MAC-per-clock network engine.
run_cycles includes tap stalls and excludes host loading; it is simulated
latency,not measured board performance. No physical Fmax is established.

Initial failure `engine_20261020T185947349537Z` is retained: the uncontextualized
10-bit feature-map write index wrapped above1023. Explicit16-bit write addresses
fixed it; expected values were unchanged. `engine_20261020T190116719398Z` then
passed; current evidence above additionally uses constant-divisor address
arithmetic to avoid inferring variable dividers.

Frozen isolated synthesis `engine_synth_20261020T190239082611Z` PASS:
1419LUT1..4,785FF,783ALU,77MUX2_LUT5,16RAM16SDP4,2DPB+4DPX9B,zeroDSP.
RAM-mapping out-of-range warnings still require inspection; macro counts are
not final routed physical BSRAM usage.
CSR and supplementary UART binding are implemented;current25K P&R passes,
see CSR.md and HOST.md. Hard scan binding,per-layer physical readback,
measured latency/throughput and the work-order physical gates remain open.
