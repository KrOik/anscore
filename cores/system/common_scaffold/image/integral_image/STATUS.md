# Implementation and evidence status

Only `image/integral_image/` was changed: new RTL, numerical/protocol/limits and
synthesis scripts, mature-reference fetcher, README, manifest, source list and
freeze/evidence JSON. Existing streaming integral and square-integral cores were
reviewed read-only. The added missing capability is persistent arbitrary queries.

Executed commands, all final results **PASS**:

```
python -B cores/system/common_scaffold/image/integral_image/run_tests.py
python -B cores/system/common_scaffold/image/integral_image/test_protocol.py
python -B cores/system/common_scaffold/image/integral_image/test_numeric_limits.py
python -B cores/system/common_scaffold/image/integral_image/synth_check.py
python -B cores/system/common_scaffold/image/integral_image/fetch_references.py
python -B cores/system/common_scaffold/image/integral_image/freeze.py
```

Main:28 frames/9324 queries, exact integer oracle and actual OpenCV integral2.
Protocol:21 clean recovery frames/queries,8 aborts,10 CE-off resets,3 marker errors.
Limits:7 illegal profiles rejected; full-max65536-pixel frame and maximum4096
axis frames each50 queries; arithmetic sum32/square40 bounds proved.
Synthesis:1633/1487/1940 conservative LUT-class for32×24/31×17/64×32 respectively,
all0 DSP and10/10/24 conservative BRAM9 units. RAM16 is charged4 LUT per primitive.

RTL SHA256:`a16194c1be7034a3be0d1c8606250ab20ee454ff9e8f8fa9734ef62879802a5c`.
All final evidence binds this exact source. An early multi-port inference was
replaced by explicit shared single-write/synchronous-read ports before the final
full tests and synthesis; no failed build artifacts remain. TemporaryDirectory
cleaned all netlists/simulator images/downloads. No board/JTAG/UART action or
shared integration edit was performed. Physical acceptance belongs to root.
