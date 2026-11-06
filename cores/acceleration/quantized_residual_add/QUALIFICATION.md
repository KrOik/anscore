# B40 finite qualification

PASS: the first and only invocation executed11 children (three syntax checks and
four compile/simulation pairs), all passing. Four planning model calls preceded
source review; four archived vector preparations occurred after freezing inputs.
No automatic retry, repair or passed-profile rerun occurred.

Independent review A found NO_BLOCKER. All14 input files, the approved plan, four
vectors,22 raw streams and two tools remain hash-bound. The frozen README keeps
its pre-execution candidate statement; this file and QUALIFICATION.json record
the subsequent LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED.

The four simulations checked6684 numerical outputs,362 configurations,344 vector
commands,6711 complete input pairs including cancellation scenarios,58 resets
and5643 held clocks.2762 outputs clamped and6222 had nonzero discarded shift
bits.5485 pair-latency observations matched10 clocks to output retirement and
5324 adjacent-pair observations matched11 clocks without input/output stalls.
These counts qualify finite behavior, not physical MHz or throughput.

Coverage includes a4096-pixel frame, all64 configured channels, signed extrema,
RNE ties and shifts0..31, exact large-product cancellation, independent branch
skew, persistent config, failed-config preservation, early/missing LAST, held
outputs/completions and seven reset/cancellation phases. The actual signed8
wrapper contributed257 outputs and six cancellation scenarios. The legal maximum
262144-pair frame was not run as a single transaction; this is not exhaustive
input/metadata or formal coverage.

Four compiler logs retain missing-design-timescale warnings; the TB explicitly
uses1ns/1ps. There are no other stderr diagnostics. No RTL or executed source
was changed after this invocation. No synthesis/PnR/STA/board/PPA, combined
compile or inherited regressions ran.

Receipt: `reports/20261106T063219189655Z/results.json`, SHA256
`44c8d87b8ceea77baa414da8c51fff97918d9b3187b74a7ad93d41803b1e2b9e`.
