# Frozen status

Implemented complete binary-edge center/radius Hough voting, synchronous full
accumulator, deterministic global peaks and Euclidean-center/radius NMS.
All work is confined to this directory. No shared files, existing cores,
JTAG or serial ports were touched.

Commands completed successfully from the repository root:

```powershell
python -B cores/system/common_scaffold/image/hough_circles/run_tests.py
python -B cores/system/common_scaffold/image/hough_circles/synth_hough_circles.py
```

Final simulation PASS (61.406 seconds with other local work active):25 main
frames across1×1,7×5,16×16,32×32, known single/multiple/concentric/partial circles,
radius31 and full radius15 score84, no circles, dense/noisy maps, marker errors
and recovery. Ten CE=0 reset phases each recover;11 healthy recovery frames,
9 invalid configs,8 invalid static cases, maximum32 outputs, and all140 RTL
accumulator bins pass. All31 ROM rings equal actual skimage unique perimeter
coordinates. Actual skimage Hough volumes match6380 bins after explicitly
accounting for its repeated symmetry-point voting convention.

Complete isolated synth_gowin/check-assert PASS:7×5/r4,16²/r8,32²/r31/max32.
LUT1..4=592/478/504,ALU403/364/372,FF202/203/216,DSP0. RAM mappings:
3SP+18RAM16SDP4,3SP+1SPX9,19SP, including geometry tables. No route, timing,
whole-system resource-fit or board validation claim.

RTL SHA256: `c500c10c0e30b1f5c3f367687100544c454b828b09aacc4bcea514cefaba4be9`.
Additional frozen hashes are in `freeze_hashes.json`. Actual public source
access/hashes are recorded in `references.json`. TemporaryDirectory cleaned
all generated simulators, testbenches and working files; retained artifacts
are small source/ROM assets and evidence only.
