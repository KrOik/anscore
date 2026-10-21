# Six public DSP board cases

All six frozen cases passed normal, corrupt-expected-output and forced-command-timeout UART simulations. The root simulation hash gate also passed for each. No synthesis or JTAG programming was performed.

| Case | Public module | Commands | Inputs | Outputs |
|---|---|---:|---:|---:|
| fir_20261018_1400 | `cip_fir_stream` | 14 | 26 | 26 |
| iir_20261018_1400 | `cip_iir_biquad_stream` | 18 | 26 | 26 |
| cic_20261018_1400 | `cip_cic_decimator` | 7 | 27 | 11 |
| cordic_20261018_1400 | `cip_cordic_stream` | 14 | 20 | 60 |
| fft_20261018_1401 | `cip_fft_stream` | 10 | 113 | 224 |
| resampler_20261018_1402 | `cip_resampler_stream` | 22 | 26 | 49 |

Each case freezes complete public adapter RTL, dependent production arithmetic RTL, ROM-driven board top, generic acceptance driver/report/UART, CST, vectors and expected UART. case.json and build_status.json are compatible with acceptance48/build_case.py.

All transfers use CE4. Every output word and last bit is compared, and responses check original command tags/errors and transfer counts. Coefficient commands and deliberate unsupported/invalid commands are covered. This is bounded finite-vector acceptance; default parameter sizes and all possible inputs are not claimed.

Oracles: FIR direct convolution; IIR direct-form-I integer recurrence; CIC binomial-integral checkpoint differences; resampler zero insertion, convolution and decimation; CORDIC and FFT use the existing independent fixed-point Python references. The case metadata records oracle/generator hashes.

To create a fresh case:

```powershell
python cores/system/common_scaffold/board/tang25k/acceptance48/make_dsp_case.py --case fir --output <new-directory> --verify
```

Then root may build the selected frozen case through build_case.py. Board acceptance requires a later actual SRAM load and exact UART comparison. Failed attempts remain listed in HANDOFF.json; no baseline logs were deleted.
