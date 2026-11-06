# Quantized resident ReGLU projection

B38 baseline: `816d461b12fd402f6a146ca74c7491c7afbd3091`.

The existing resident INT4 matvec performs a single linear projection; attention
adds a softmax/value reduction and LayerNorm adds centered normalization. Neither
implements two learned projections joined by a nonlinear gate. Local filename
and source review found no ReGLU/GEGLU/SwiGLU implementation. Existing generic
ReLU/multiply operators alone do not schedule persistent paired projections.

One unchanged matvec caches the U8 query once. Its rows are interleaved: gate
row `2*j`, value row `2*j+1`. For each pair, original control stores only one
gate, captures the value, applies ReLU, multiplies, scales and uses the unchanged
elastic RNE requantizer. It blocks the next result pair while an output is held.
There is no second projection engine, duplicated query RAM or hidden-vector RAM.
This serial architecture trades task latency for a bounded reusable datapath.

For each branch b, the existing matvec contract remains:

```
a[b,j] = bias[b,j] + sum_c((U8(x[c])-U8(x_zero))*S4(W[b,j,c]))
v[b,j] = sat8(RNE(a[b,j]*U16(scale[b,j])/2^shift[b,j])+S8(zero[b,j]))
y[j]   = sat8(RNE(max(0,v[gate,j])*v[value,j]*U16(out_scale[j])
                  /2^out_shift[j])+S8(out_zero[j]))
```

Output shifts are 0..31 and rounding occurs before adding the signed8 zero.
Gate projection quantization precedes ReLU. Branch clipping/inexactness is
reported separately from final quantization. No approximation to sigmoid or
GELU is introduced. This is a specified integer ReGLU operation, not an accuracy
claim for any trained model, or the final down-projection of an entire MLP.

MAX_HIDDEN 1..32, MAX_COLS 1..256, TAG_W 1..32; defaults 8/64/8. Matrix payload
is `2*H*ceil(C/8)*32`, cached query is `8*C`, additional output metadata is 29*H
bits. These total 4840 bits by default and 68512 at maximum, excluding the
unchanged child branch metadata/valid bits and scalar/pipeline registers. New
gated multiply is signed8x8 (signed16 product), then signed16x17 (signed33).
Absolute unscaled gated product is at most 16256; scaling at most 1065336960.
There is no division, square root, wide parallel dot array, CDC or external RAM.
Architecture risk MEDIUM; FPGA area/Fmax/BRAM mapping remain unmeasured.

The wrapper first checks all required output metadata, then the existing child
checks all required branch rows/weights before accepting query samples. Invalid
shape, missing metadata or malformed LAST cannot emit an ordinary output prefix.
Configuration has priority at idle and every response can be held indefinitely.
Reset cancels ownership and invalidates all configuration without clearing RAM.

The actual example first uses the unchanged signed32-to-signed8 requantizer,
then adds 128 by toggling the sign bit to supply asymmetric U8 with x_zero=128.
One prefix sample may be in flight; its LAST, clip and inexact flags remain
attached until the core accepts it. This adds a usable 32-bit accumulation input
path and explicitly handles reset while that prefix slot is occupied.

Finite check design will cover H/C/T 1/1/1, 3/9/8, 32/256/32 and the actual
4/16/8 prefix example. Exact plan/source/vector archival precedes any HDL child;
20 seconds per child, fail-stop, no automatic retries. No HDL has run at this
architecture checkpoint. No synthesis/PnR/STA/board/PPA is authorized.
