# Independent fixture EOF followup02

The original attempt stopped at an Icarus nested-file-list error. Followup01
passed the explicit example syntax and tiny compile, then stopped at the final
fixture suffix check: Icarus returned zero while reaching EOF after whitespace.
All original and followup01 executed bytes and evidence remain frozen. Neither
failed simulation counts as a successful simulation.

This independent followup copies the original testbench and changes only its
last suffix scan. It accepts return zero or minus one only when `$feof` is true;
any extra integer, malformed nonwhitespace suffix, or unfinished input remains
an error. Every existing sample, output, error, reset and ownership assertion is
unchanged. Core/example RTL, the explicit followup01 file list, oracle and four
original vector paths/hashes are unchanged. Zero numerical preparations; four
isolated compile/simulation pairs, each with the reviewed 20/5/2 second limits.
Previously successful syntax checks are not repeated. No old helper is imported
or executed. The first new failure stops this independently gated attempt.

Pre-execution status: SOURCE_ONLY / NOT_RUN / HW_UNVERIFIED.
