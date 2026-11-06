# Retained first-attempt failure

The first attempt remains **FAIL_STOP**. Its receipt is
`reports/20261106T184434034464Z/results.json`, SHA256
`afa70ae8be75c8f96a4496f892dd400caf69d008bf1f2515afd6eef6debaba92`.
No original source, control, guard, raw stream, vector, sidecar or image is
replaced, removed or retried.

Actual execution was five successful preparation children, two successful
syntax children, one successful minimum-profile compile and one failed
minimum-profile simulation. The simulation exited with code1, no cleanup or
active process, and the raw diagnostic:

```text
FATAL: sim/tb_multistop_linear_gradient.sv:148: extra vector rows
       Time: 677970000  Scope: tb_multistop_linear_gradient
```

The failing statement requires a final `$fscanf(file_handle,"%d",offset_value)`
to return exactly -1. Independent raw-byte and text-grammar inspection consumes
all15 case headers and635 query rows in each original vector, with the declared
stop rows and no extra logical row. All five files end in exactly one LF after
the final query. Their row counts are666/714/780/714/780. The false extra-row
assertion is therefore localized to this EOF predicate. The actual return value
was not printed; an inferred return of0 is not a measured result.

Control flow establishes that the minimum-profile main query checks preceding
line148 returned without an earlier fatal. It does not establish a completed
simulation: the later directed management, reset, recovery and pending-offer
checks did not execute, and no `GRADIENT_PASS` or `$finish` marker was emitted.
The other four compile/simulation pairs were not run. There is no wrapper PASS
or whole-suite qualification from this attempt.

`POST_AUTHOR_AUDIT.json` independently rechecks129 file bindings, all21 source
and archive pairs as exact bytes,24 tools, the original controls and guard,
the exact nine-child planned prefix,18 raw streams,9 immutable starts,
9 immutable terminals,8 validated sidecars, all five vectors and preparation
receipts, and the retained original simulation image. Its checks find no
discrepancy in the retained failure evidence. This audit runs no model, project,
AST, HDL, Git or helper.

Root authorized a separate source-only `followup01` candidate. Its copied TB
changes only the EOF-consumption statement to `$fgetc` until -1, accepting only
ASCII space, tab, LF, vertical tab, form feed and CR and rejecting every other
trailing byte. Separate runner, plan, seal, review and once-only gate are
required. It reuses the original five vectors and five preparation receipts as
explicit read-only hash pins, with zero new preparation or oracle execution.
Its finite sequence is two syntax checks and five compile/simulation pairs.
The original failure remains part of any later combined qualification.
