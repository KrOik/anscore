# Isolated resampler timing repair

`case_v3` preserves the original signed polyphase FIR outputs and packet tail.
It registers product, accumulation, and saturation in separate states, and
sizes nonnegative phase/tap/remaining/address counters to their elaborated bounds.
Each output now needs two enabled cycles per history tap plus one quantization
cycle, in addition to the existing preparation and output handshake cycles.
Coefficient loading, reset cancellation, CE, output backpressure and saturation
semantics are retained. Production integration must use this exact frozen core.

The isolated fixture registers configuration/input/expected ROM outputs. Its
CE_DIV=4 allows three physical clocks to settle each changed address. Both
normal and corrupted-pixel fixture variants receive the same pipeline; original
UART golden digest `72584D68` is unchanged.

Commands:

```
python run_candidate_tests.py
python prepare_case.py --case resampler --output case_v3 --verify
python ../../build_case.py case_v3 --no-lutram
python ../../functional_board.py case_v3 --attempt accept_20261018_224626
```

Fourteen core/public parameter configurations passed original independent
references, including CE, stalls, signed saturation, tail and reset. Case v3
setup is 63.62/57.50 MHz. Three real SRAM loads and exact UART comparisons
passed; see its retained `functional_board_*.json`. Hold timing remains unproven,
so this is bounded functional evidence, not timing signoff. Earlier failed
v1/v2 cases remain preserved. Test binaries/fixtures use temporary directories.
