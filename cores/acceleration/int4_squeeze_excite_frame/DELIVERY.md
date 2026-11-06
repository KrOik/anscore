# B46 squeeze-and-excitation frame delivery

Maturity: **LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
The independent followup02 plan passed once: zero numerical preparations,
eight HDL children and four successful simulations. Receipt
`followup02/reports/20261106T142358608525Z/results.json`, SHA256
`874cde1e69e3cf246fccc3cdf2732025164810db8fc89df29b9d8a853d6154f4`.

The actual datapath caches an NHWC signed8 frame, reuses the resident signed8
GAP and two INT4 matvec engines, applies hidden ReLU and exact Q0.8 hard-sigmoid,
then replays the frame with nearest-even channel scaling. The real RGB example
boots two weight banks and runs this complete composition. Configuration commit,
precheck, early/missing LAST, unconfigured/error results, reset cancellation and
held output/completion ownership are asserted in the finite testbench.

| Profile | Frame responses | Scored outputs | Config replies | Resets |
| --- | ---: | ---: | ---: | ---: |
| C1/H1/P1/T1 | 38 | 22 | 112 | 7 |
| C9/H3/P7/T8 | 38 | 630 | 595 | 7 |
| C64/H32/P4096/T32 | 40 | 4790 | 12798 | 7 |
| Actual RGB C3/H1/P7/T8 | 14 | 105 | 0 | 6 |
| Total | 130 | 5547 | 13505 | 27 |

There are79 independent oracle frames from the original four preparations.
Other responses are deliberate error/ownership fixtures. The total includes
68 future BAD_OP configuration replies,11094 output-hold cycles,390 completion
holds and26874 configuration-response holds. Scored outputs include4710
inexact scalings,401 zero gates,311 exact unity gates and188 half gates.
The maximum profile exercises P4096/C1 and P1/C64/H32 separately; it does not
qualify a complete simultaneous maximum frame or sustained video throughput.

Two failed attempts remain frozen. The original had four successful preparations,
two successful syntax checks and one example syntax failure from recursive
nested file-list resolution. Followup01 passed explicit example syntax and tiny
compilation, then its simulation failed only at the final fixture suffix scan.
Icarus returned0 at trailing whitespace/EOF while the original check required-1.
Neither failure is counted as a successful simulation. Followup02 copies the TB
and changes only that suffix check to require return0/-1 AND EOF; extra tokens
are still rejected. It reuses the unchanged explicit source closure, all RTL,
oracle and four original vector files. There was no vector regeneration,
automatic retry, old-helper execution or source modification after execution.

Root and independent worker_a audits matched67 current/archive input pairs,
three control pairs,25 tool string keys (24 physical files),four vector files,
eight child JSON records,16 raw streams and four original images. Every child
exited0 with complete capture, no cleanup helper and no surviving PID. Compile
stderr contains only the same809-byte notices about missing explicit time units
in the RTL closure; all four simulation stderr streams are empty.

Executed README/manifest/source/control bytes retain their pre-execution wording.
This new delivery note and QUALIFICATION.json record the final finite evidence.
Frame storage is32Kbit at defaults and up to2Mbit at maximum parameters; resource
risk remains MEDIUM at defaults and HIGH at maximum. No synthesis, PnR, STA,
board, physical throughput, power or PPA evidence was generated. All source,
failed evidence and original binary images are retained; binaries stay out of Git.
