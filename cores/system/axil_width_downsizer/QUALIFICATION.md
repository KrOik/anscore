# Qualification status

Current production status: **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**.

Authoritative execution: `reports/20261105T171040310508Z/results.json`.
Ten child commands passed on the first execution: two syntax/elaboration
checks and four compile/simulation pairs. All six executable/file-list inputs
and their exact pre-execution copies still match the recorded SHA-256 values.
No executable source or runner edit followed these checks. This qualification
text and descriptive manifest are metadata, not tested program inputs.

| Actual check | Scope | Result |
| --- | --- | --- |
| Icarus `-g2012 -Wall -tnull` | Default production top, 16-bit addresses /32-to8 | PASS |
| Icarus `-g2012 -Wall -tnull` | Complete default example and source closure | PASS |
| Compile plus vvp | ADDR_W=1, S_DATA_W=16, M_DATA_W=8 | PASS,278cycles |
| Compile plus vvp | ADDR_W=9, S_DATA_W=32, M_DATA_W=8 | PASS,397cycles |
| Compile plus vvp | ADDR_W=16, S_DATA_W=64, M_DATA_W=8 | PASS,669cycles |
| Compile plus vvp | ADDR_W=64, S_DATA_W=64, M_DATA_W=32 | PASS,370cycles |

The four simulations checked 184 AW,184 W and144 AR transfers in total,
producing 74 upstream B and36 upstream R retirements. Additional completed
parts whose upstream responses were intentionally reset are not represented
as retired upstream accesses. These counts describe the recorded TB cases,
not exhaustive parameter-space coverage or measured hardware throughput.

The TB independently derives the expected narrow transaction sequence from
the original command, compares every address/protection/data/strobe field,
and predicts read bytes from full byte addresses. Cases cover independent
concurrent read/write operation, both AW/W arrival orders, all byte lanes in
isolation, alternating strobes and zero-strobe omissions, two-bit response
preservation and severity precedence, highest legal aligned addresses,
misalignment with zero downstream dispatch, held output responses and
downstream request stability. Shared reset is exercised with an unmatched
write half, active downstream work and held read/write responses. No protocol
fault detector, atomic wide access, eventual reply from a stalled target,
or untested configuration is certified by these cases.

Each TB compile reports Icarus's warning that the production module has no
explicit time unit. Production RTL contains no delays; TB clock timing is
explicit1ns/1ps. Raw warnings/stdout/stderr are retained. No functional failure,
compiler failure, missing dependency or watchdog timeout occurred. Cleanup
failure branches and missing-tool handling are source-reviewed, not forced
or executed as extra tests. Successful simulator images remain task-local and
ignored for root-owned review/cleanup.

Static source review checked fixed-width unsigned address/data behavior,
bounded part indices, full combinational assignments, one sequential writer
per register, held payload ownership, no array reset/BRAM dependency and no
simulation-only production constructs. The wide-alignment rule proves every
narrow address is inside the accepted ADDR_W domain. Existing RTL was not
modified. Architecture risk LOW remains a qualitative structural judgment.

Synthesis, placement/routing, STA, board execution, formal verification,
full regression, resource/power/Fmax measurement: **NOT_RUN**. No hardware
validation or device-fit result is claimed.
