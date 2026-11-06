# B37 finite qualification

LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED. The first and
only invocation passed11 children: default/maximum/example syntax, then four
compile/simulation pairs. No failure, timeout or retry occurred.

Receipt: `reports/20261106T042321807275Z/results.json`, SHA256
`f21668b5a77b0eb2e220f9d191e247770debc24fb4bdb6215fed4b1a4a51eaad`.
Frozen plan SHA256
`24c60cef38cbd3ac0329e061cc16aff4d7231966482a949eb5c371317c0dbeec`.
Eleven exact executable inputs and the plan were archived before the first HDL
child. All current/archive source, plan,4 numerical-vector and22 raw-log hashes
were re-read and match. Successful VVPs remain ignored until root integration.

| MAX_LEN / FRAC / TAG / example | Config vector replies | Ordinary output comparisons | Error markers | Output holds | Resets including initial |
|---|---:|---:|---:|---:|---:|
| 1 / 0 / 1 / core | 15 | 27 | 15 | 148 | 8 |
| 9 / 12 / 8 / core | 55 | 245 | 15 | 910 | 8 |
| 256 / 16 / 32 / core | 547 | 2623 | 15 | 9236 | 8 |
| 8 / 12 / 8 / actual prefix | 56 | 257 | 16 | 956 | 9 |

These vectors cover204 completed commands,3152 ordinary comparisons and61 error
markers. Separately, each simulation executes one real pending config+command
priority flow with two checked output results:8 more ordinary outputs total.
The673 config vector replies exclude those4 priority config replies and the4
config replies canceled by reset. There are29 live resets plus4 initial resets,
11250 held-output clocks, and one explicitly asserted prefix-pending reset.
The first-result source-cycle budget is checked for finite core profiles.

Coverage includes invalid length/configuration, zero/positive/max epsilon,
constant/alternating extreme vectors, exact signed half ties, post-round beta,
affine signed extrema/clipping, offset invariance, malformed LAST, held replies
and outputs, persistent true future offers, and reset during capture, shared
multiply, root, divide, quantizer and output hold. Actual example also resets
an input quantizer sample in flight and checks input clip/inexact separately.
Source-only cross-review by worker A closed with no blocker before execution.
The independent Python oracle uses mathematical integer sqrt half-boundaries,
whole-vector sums and signed quotient/remainder RNE, without RTL/helper
recurrences or imported floating frameworks. Maximum256 length is actually
simulated in the F16 profile, but other legal parameter combinations and all
possible values are not exhaustively verified. Internal arithmetic-error guards
are not fault-injected. No merged/inherited regression, synthesis/PnR/STA/board,
physical frequency/throughput/power or floating-framework accuracy claim.
