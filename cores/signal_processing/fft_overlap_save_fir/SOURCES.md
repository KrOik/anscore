# Discovery, originality and offline closure

Read-only discovery on2026-11-07 (Asia/Shanghai):

- Julius O. Smith III, Spectral Audio Signal Processing, Overlap-Save Method:
  https://ccrma.stanford.edu/~jos/sasp/Overlap_Save_Method.html (HTTP200).
  The primary author describes discarding M-1 aliased output samples, saving
  M-1 input samples and advancing by N-M+1. No text, RTL or software was copied.
- Official SciPy documentation:
  https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.fftconvolve.html
  and https://docs.scipy.org/doc/scipy/reference/generated/scipy.signal.oaconvolve.html
  (both HTTP200). These establish FFT/block convolution as useful algorithmic
  alternatives; their floating-point implementations are not the integer oracle.
- The web search connector returned HTTP500. Bounded read-only HTTP requests
  were used instead. A MathWorks frequency-domain FIR page returned403, and a
  DSP Guide page had a TLS failure; neither is relied upon. No remote script,
  installer, model, trained data or build was downloaded and executed.

Semantic deduplication examined the existing programmable FIR, rational
polyphase resampler, LMS, Farrow, Gardner/Costas, matched correlation, STFT,
FFT and related measurement packages. Targeted current-source/README/manifest
searches (excluding report/history/archive copies) found no overlap-save/add
or frequency-domain convolution implementation. This package adds the actual
filtering and finite-stream state machine rather than another spectral metric.

New control/datapath/model/test code is original ANSCORE work under Apache-2.0.
The only reused RTL is the explicitly admitted, byte-preserved workspace FFT
source described in DEPENDENCY_PROVENANCE.md. No generator or external ROM is
required to elaborate the core. No historical hardware conclusion is inherited.
