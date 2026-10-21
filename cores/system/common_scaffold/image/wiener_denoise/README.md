# Local adaptive Wiener grayscale denoiser

`wiener_denoise.sv` implements actual local adaptive Wiener filtering on 8-bit grayscale frames. Runtime selection is 3x3 or 5x5, with replicate borders. Runtime width and height are 1..MAX_SIDE; MAX_SIDE is an elaboration parameter supported in 1..32 (default 32). Noise variance is supplied externally in integer squared-gray-level units, 0..65535. This core does not estimate noise automatically.

## Exact arithmetic

Let n be 9 or 25, S the neighborhood pixel sum, Q the sum of squared pixels, c the center pixel, and N the supplied noise variance. The exact central moment is `V=n*Q-S*S`, so local mean is S/n and local variance is V/n². There is no prematurely truncated mean or variance.

Define `T=N*n*n`. If V<=T, output is round(S/n). Otherwise output is:

```
round((S*T + (V-T)*n*c) / (n*V))
```

This is exactly `mean + max(var-N,0)/max(var,N)*(c-mean)`. All operations before final rounding are integer-exact. The flat zero-noise case V=N=0 is defined as the local mean (equal to c). Final nonnegative values round to nearest, with exact half ties upward; a defensive 0..255 upper saturation is included. Sum uses 13 bits, squared sum 21 bits, V/noise scaling/denominator 32 bits, numerator/products 48 bits. These bounds cover the supported sizes, full pixel range and noise range. Two generic products use 16-cycle shift-add multiplication; a 48-step restoring divider is reused. Sample squaring is a narrow 8-bit operation.

A high-gray 254/255 neighborhood therefore retains its true sub-unit variance and noise=1 correctly selects the local mean; it does not acquire the hundreds of false variance caused by truncating the mean before squaring.

## Interface and recovery

Inputs are clk/rst_n/ce, start_valid/start_ready, cfg_width/cfg_height/cfg_window5/cfg_noise_variance, abort, and s_data/s_valid/s_sof/s_eol/s_last/s_ready. Outputs are m_data/m_valid/m_sof/m_eol/m_last/m_ready plus done_valid/done_ready/done_error/error_code/busy. `cfg_window5=0` selects 3x3 and 1 selects 5x5. All configuration is snapshotted on accepted START. START is blocked while abort is high. Illegal static MAX_SIDE values (including 0 and 33) explicitly return error 80 on START; their RAM allocation is safely reduced to a single unused entry.

START, input, output and DONE transfers require CE=1 as well as valid and ready. Source readiness includes CE. Output valid can remain high at CE=0; a receiver must count a transfer only on an enabled edge. Output data/markers remain stable through CE pauses and backpressure. The complete frame is captured into synchronous RAM before raster output. Neighborhood addresses use explicit address/wait/sample states; no asynchronous full-frame read array is used. Processing is intentionally serial and has no one-pixel-per-clock claim.

SOF occurs only at the first pixel, EOL at each row end, LAST only at the final pixel. Marker failure terminates immediately, even on partial capture: do not finish sending the malformed frame. Errors invalidate the whole frame, including any pixels emitted before an abort. DONE and errors hold until an enabled DONE acknowledgement; another healthy frame can then start without reset. Successful held DONE ignores late abort.

Abort suppresses output valid immediately; failure is sampled on CE=1. Hold abort through an enabled edge: a pulse confined to CE=0 is not remembered. Reset is synchronous to clk and effective regardless of CE. RAM is not cleared by reset, and every accepted healthy frame overwrites all addresses it will use.

Errors: `80` zero/oversize geometry; `81` marker mismatch; `93` active abort; `94` invalid internal state. Invalid configuration clears output metadata on START and emits no output frame.

## Reproduce verification

From repository root:

```powershell
python -B cores/system/common_scaffold/image/wiener_denoise/test_wiener.py
python -B cores/system/common_scaffold/image/wiener_denoise/test_errors.py
python -B cores/system/common_scaffold/image/wiener_denoise/synth.py
```

Normal verification passed 14 fixtures / 15 actual frames: 3x3/5x5, both noise branches, 32x32, random high variance, 254/255 near-constant data at noise=1 and 0, low noise=1, constant/black/impulse, maximum noise, singleton/row/column, and exact 7/2 half-up output. Every byte and marker is checked against an independent Python Fraction oracle expressing mean, variance and gain directly. Actual installed scipy.signal.wiener is also run and every rounded selected-fixture pixel matches exactly. SciPy normally uses zero padding; we replicate-pad before calling SciPy and crop away that outer boundary. Its zero-variance/noise=0 NaN is replaced by the explicitly defined identity result. SciPy reference provenance and the fetched documentation hash are in references.json.

Tests also cover CE/source/output stalls, START configuration mutation and no-reset repetition. Error verification passed 20 complete healthy recovery frames, including static MAX_SIDE=0/33 rejection, abort-high START blocking, all invalid geometries, partial marker errors, capture/serial-multiply/divide/output abort, CE=0 abort through CE=1, held error and CE=0 acknowledgement, CE=0 reset in capture/RAM/multiply/divide/output/DONE, and forced invalid internal state. Every recovery frame checks all real output pixels.

Full standalone hierarchy `synth_gowin -nodsp; check -assert; stat` passed at MAX_SIDE=32:

| LUT1..4 | ALU | LUT+ALU+MUX | FF | RAM | DSP |
|---:|---:|---:|---:|---|---:|
| 1280 | 616 | 1970 | 628 | 1 DPX9B | 0 |

ALU and mux cells are explicitly counted. Evidence records source hashes. Temporary simulation/netlist/full synthesis logs use automatically cleaned TemporaryDirectory; only compact results are retained. No routing, timing or board acceptance is claimed.
