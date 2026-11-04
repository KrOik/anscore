# Frozen C15 finite plan — before first compiler/simulator

No synthesis, PnR, STA, hardware or expanded regression. Every native compiler
or simulator child has a20-second limit. Any timeout is terminal: retain it,
mark the matrix INCOMPLETE_TIMEOUT/NOT_RUN and stop without retry, shrinking
fixtures or increasing the limit. Ordinary failures retain original records
and source hashes before repairing and rerunning this same plan.

Nine numerical profiles `(WIDTH,HEIGHT,PIXEL_W,GRAY_W,TAG_W)`:

```text
1,1,1,1,1
1,7,4,2,3
7,1,8,3,8
2,2,2,2,8
3,3,1,1,8
8,5,8,3,8
32,24,12,4,8
128,1,16,4,32
1,128,16,4,32
```

Each profile has16 deterministic good frames and four framing-error frames.
Add every256 four-gray2x2 image and every512 binary3x3 image. Main totals:
948 frames,27472 input pixels,3568 dense output bins. Largest numerical area
is768. The maximum128x128/P16/G4/T32 square is compile-only from this plan;
its numerical simulation is NOT_RUN.

Independent Python Fraction oracle enumerates clipped coordinate sets without
line buffers or padding. Check every dense count and exact120-scaled rational
difference, every output marker/tag/error, sum-count conservation, all internal
center gray/count/neighbor-sum/delta/scaled contributions, per-frame work and
exact tail latency. Quantization noise, zeros, maxima, impulses, ramps,
checkerboards and fixed seeded randoms exercise all reachable neighbor counts.
Good1x1 emits zero statistics. Bad SOF/EOL independently drain the fixed image
and emit a complete zero matrix; errors may combine.

Each profile probes reset at idle/middle clear, partial capture, line read,
window, absolute-difference, scaling, histogram read/write, output read,
held normal/error with blocked source, warmup, bottom-right drain and repeated
bin update when reachable. Each observed target is canceled before another
active edge and followed by a complete analytic bright-corner fresh frame.
Unreachable geometry-specific targets are explicitly skipped and counted.

Commands: version; production/example/max-square syntax checks; nine compile/
simulation pairs; eleven named invalid-profile rejects (W0/W129,H0/H129,
P0/P17,G0/G5,G>P,T0/T33):33 total. Freeze full fixture SHA256 receipts before
the first tool. No source or numerical evidence is inherited from GLDM.
