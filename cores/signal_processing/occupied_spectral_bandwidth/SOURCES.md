# Sources, license and capability review

The new RTL, wrapper, runner, oracle, testbench and documentation are original
ANSCORE Apache-2.0 contributions covered by the repository LICENSE and NOTICE.
No external source, executable, coefficient table or generation dependency was
imported. The mathematical definitions are not claimed as novel algorithms.

Primary/upstream read-only review completed on 2026-11-06 before implementation:

- eCFR, 47 CFR 2.202, technical occupied-bandwidth definition:
  https://www.ecfr.gov/current/title-47/chapter-I/subchapter-A/part-2/subpart-C/section-2.202 .
  Its equal low/high power-tail definition motivated the 99% instrument use.
  This package defines its own discrete whole-bin semantics, rather than claiming
  compliance with a regulated measurement procedure or an analog RF instrument.
- SciPy **v1.16.2**, `scipy/signal/_spectral_py.py`, `periodogram` documentation
  and implementation:
  https://github.com/scipy/scipy/blob/v1.16.2/scipy/signal/_spectral_py.py .
  Reviewed the distinction between equal-width spectrum and PSD units, and the
  handling of positive/negative spectrum values. No SciPy code is adopted or run.
- SciPy v1.16.2 license:
  https://github.com/scipy/scipy/blob/v1.16.2/LICENSE.txt .
  BSD-3-Clause redistribution/notice and endorsement terms were inspected before
  authoring. No SciPy distribution is required or included.
- The MathWorks official `obw` page
  https://www.mathworks.com/help/signal/ref/obw.html and its Spanish-domain endpoint
  returned HTTP 403. They were not used as verified implementation evidence.
  The general web tool was unavailable; the successful primary/upstream reads
  used direct HTTPS text retrieval. No remote project/script was executed.

## Internal semantic deduplication

Production RTL/README searches covered standalone signal-processing packages,
the DSP/ISP library, common_scaffold and operator_library. Terms included CFAR,
noise floor, occupied bandwidth, cumulative spectrum, power percentile, spectral
quantile, frequency/period measurement, waveform trigger and burst detection.
The relevant implementations were read before selection:

| Existing asset | Existing capability | B35 decision |
| --- | --- | --- |
| block_ca_cfar | Complete local training/guard noise-adaptive detection | Preserve; no repeated CA/OS numerical variant |
| spectral_band_monitor | Runtime fixed band bounds; energy/moment/peak/threshold counts | Preserve; it cannot invert cumulative energy to find coverage bounds |
| dsp_isp_library/dsp/stft/stft_welch | Window/FFT/power plus block/exponential averaging | Preserve; consume its ordered power values, no transform/averager duplicate |
| dsp_isp_library/dsp/spectrum/peak_search | One maximum and threshold flag | Preserve; a peak does not determine occupied-power width |
| event_interval_recorder | Real clock reference/observation intervals and FIFO overflow | Preserve; no repeated timestamp instrument |
| common_scaffold/peripherals/frequency_counter | Gated synchronized pin-edge counts | Preserve; no repeated frequency counter |
| common_scaffold/peripherals/pulse_measurement | Complete high/low/period measurement | Preserve; no repeated pulse-width instrument |
| dsp_isp_library/dsp/spectrum/mag_squared | Exact signed16 complex-bin power pipeline | Reuse unchanged in the actual I/Q example |

Histogram and order-statistic blocks operate on value distributions, rather than
frequency-ordered integrated power. B35 stores powers in spectral order and
returns a power-weighted equal-tail frequency interval; it does not sort sample
values. This adds a concrete spectrum-instrument measurement after existing
FFT/Welch stages, with an exact explicit service/quantization contract.

## Canonical unchanged support source

The example references one existing Git-tracked support source:

```text
cores/signal_processing/dsp_isp_library/dsp/spectrum/rtl/mag_squared.sv
SHA256 43ba24b43046a80b32bb1a2bc7e71c23181ab4ca7a6fbb58d7756e9cb86489da
```

The DSP-05 header and repository Apache-2.0/NOTICE identify it as an original
repository contribution; there is no file-level third-party dependency/notice.
The same canonical path is already present in the B34 cumulative source snapshot.
It is referenced from package-root `example/files.f`, not copied or modified.
Current bytes are snapshotted with B35 inputs and tested in the actual composed
example. Older DSP-05 or B34 physical/functional evidence is not substituted for
this package's current finite checks. No include, package, ROM or external IP is
required. `files.f` and `example/files.f` are both resolved from this package root.
