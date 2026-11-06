# Delivery

The complex programmable overlap-save FIR and actual real-input adapter passed
the single approved finite RTL suite. Full numerical scope, counters and limits
are in QUALIFICATION.md/QUALIFICATION.json. Hardware remains unverified.

Use `rtl/fft_overlap_save_fir.sv` with the unchanged support source
`../../acceleration/stream_fft/rtl/stream_fft.sv`. From this package directory,
`files.f` closes the core; `example/files.f` closes the real-input adapter.
Keep those relative paths when copying the reusable bundle. The support source
contains the complete ROM; no table generator, old driver or network access is
needed for RTL elaboration. Its explicit original-workspace admission and
baseline absence are documented in DEPENDENCY_PROVENANCE.md.

Configuration publishes on successful reply retirement and clears prior stream
history. Normal commands advance B=N-M+1 samples; end commands automatically
zero pad and emit the remaining FIR tail. Respect ordinary ready/valid and busy.
The output is the documented staged integer FFT/product/IFFT result, with
cumulative clipping/inexact flags. It has no continuous one-sample-per-clock
service guarantee.

The immutable acceptance receipt is
`reports/20261106T185726607567Z/results.json`,
SHA256:`404c920f9609d6371e8023a386c56b8e00155914b4e33090827875ca611db718`.
The retained4 images and15 initial/terminal/validated record sets are bound to
the frozen sources/tools/controls. The once guard prevents replay of this
attempt; do not rerun or overwrite its outputs. A future qualification needs a
fresh, explicitly reviewed plan/guard and separate output namespace.

The formal bundle excludes review_revisions/01: its8 unapproved, unexecuted
candidate metadata/text files remain preserved in the workspace and are not
pass evidence. No sealed input or original execution evidence was edited after
the attempt. Author, independent root and independent worker_a post-audits are
separate; the author audit is not represented as independent peer review.
The completed POST_PEER_AUDIT.json has status PASS_AUDITED and SHA256
`192c1841f3623e5083554b91982245da8644e8b2dcc82bf18c97b2f0e3bdf670`.

Complete M=N tail closure is limited to N2/N8/N64. N256 complete M=N tail,
arbitrary fault injection, synthesis/PnR/STA/board/PPA and device fit remain
outside acceptance. Resource budgets are source estimates only.
