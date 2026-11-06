# Explicit support-source admission

Baseline:05b9614c3962e9d4ae934c4b9c7bd315cc01aed4 (B48 final).

The necessary support source is the original workspace file
`cores/acceleration/stream_fft/rtl/stream_fft.sv`:

- SHA256:e40a46cb051b2efbdf504221c91779a65e1787dffb5fbcf7db28b87ee660b535
- Bytes:17313
- baseline_absent:true. Root inspected the B48 final tree and found no committed
  stream_fft.sv object or equivalent alias. This is an explicit unchanged support
  admission, not a claimed baseline dependency.
- Origin:Original workspace RTL. The source has no third-party copyright/license
  header. Its manifest and README describe the original local standalone design.
  The repository root LICENSE is Apache-2.0; root NOTICE applies that license to
  the authors' original contributions and preserves file-level notices. There
  is no local FFT LICENSE or SOURCES file. No third-party FFT implementation is
  copied into this package.
- Scope:Only this source is necessary/admitted. Its embedded257-entry Q2.16
  quarter-cosine case table is the full ROM closure. No existing FFT generator,
  helper, formal/synthesis/physical driver, report or historical evidence is a
  dependency or qualification input.
- Reuse rule:Keep its original path and exact bytes. The new finite plan must
  seal the file and both reviewers must read it in full. New acceptance rests on
  this composite's fresh finite execution, never the old FFT package's claims.

The original workspace reference/source.json identifies FFTW's primary DFT
convention page, solely for forward-negative/backward-positive unnormalized
conventions. The new model does not import or execute that package's Python.
