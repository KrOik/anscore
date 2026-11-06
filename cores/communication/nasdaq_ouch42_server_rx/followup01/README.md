# Independent EOF followup01

The initial exact attempt is frozen at
`../reports/20261106T141729488803Z/results.json`, SHA256
`55409040a0e92e00e8bf49b753ef283f10e91f12b015d422305c8aabdc78242a`.
Its single preparation, five syntax children and first core compilation passed;
the first simulation exited1 with `vector header rc=0` while attempting to read
beyond the finite vector records. No simulation received a success marker.
The failed attempt remains FAIL_STOP, without timeout or surviving PID.

Icarus can return0 for the failed conversion at trailing whitespace/EOF. The
old TB assumed only-1 meant EOF after a `while(!$feof)` loop. The new TB copies
change only that file-reading boundary: exactly2557 core or29 Soup records are
required; a final integer scan must return0 or-1 with `$feof` true. A valid extra
integer or any noninteger suffix is rejected. Existing cases, bytes, assertions,
reset phases and marker counters are unchanged. No RTL, oracle, original TB,
original runner, original control or vector is edited.

The new independently gated runner has its own plan/seal/review, exclusive guard
and output directories. It compiles the two new TB files against the unchanged
original source closures and runs five profile simulations: ten HDL children,
zero preparations/imports, no new vectors and no syntax repetition. It binds
the original failed receipt, terminal JSON/raw evidence, source/archive pairs,
controls and all five vectors with exact hashes and bytes. It never executes
an old runner or imports a project helper. Any new failure stops immediately;
there is no retry, cleanup deletion, synthesis, PnR, STA, board or PPA run.

Pre-execution status: SOURCE_ONLY / NOT_RUN / HW_UNVERIFIED.
