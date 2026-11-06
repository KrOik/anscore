# Independent file-list followup01

The original reviewed B46 plan stopped after four successful oracle preparations,
default/max syntax PASS, and example syntax FAIL: Icarus resolved nested
`-f files.f` in `example/files.f` back to itself. Original source, controls,
vectors, raw evidence and receipt are frozen at
`reports/20261106T141135822729Z/results.json`, SHA256
`1e7eb2ca0e068a2a42bf88215cfed5a2413a588ea352caedb449aaac4a6f09f4`.
No RTL, model, testbench or existing file list is changed.

This independently reviewed followup replaces only the active example file-list
entry with `followup01/example/files.f`, an explicit six-source closure, resolved
from the original package directory. It references the same unchanged RTL and
dependencies. Standalone `files.f` is still the ordinary core entry.

Its own runner/plan/seal/review/guard execute nine HDL children: example syntax,
then four isolated compile/simulation pairs. There are zero preparations or
model imports. All four original vector files and their original profile
summaries are used at their exact original paths and hashes, never regenerated.
The old failed attempt's controls, terminal records, raw streams and source
archive bindings are checked as immutable inputs. The original failure is not
a successful simulation; no simulation was reached there. First new failure
stops this followup and preserves all artifacts without retry or deletion.

Pre-execution state: SOURCE_ONLY / NOT_RUN / HW_UNVERIFIED.
