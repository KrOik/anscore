# B40 finite qualification

**LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED**.
This supplement gives the final status; README.md, original plan/seal, runner,
model, RTL and TB remain byte-identical to their precheck archives. One later
packaging-only exception changes current .gitattributes from `* text eol=lf` to
`* -text` so Git preserves the exact CRLF evidence bytes. The old attributes
remain in both executed source archives and all original seals stay untouched.
Each archived control file is now named `.gitattributes.executed.txt` in its
original directory, with an explicit `archive_path_aliases` entry. Its original
bytes and SHA-256 are unchanged; the data filename prevents the historical rule
from overriding the current package's byte-preserving Git attributes.

First attempt `reports/20261106T063315_715768Z/results.json` prepared and archived
all four vector sets, then ran core syntax PASS and example syntax FAIL. Icarus
resolved the example list's nested `-f files.f` recursively. The attempt stopped
immediately. This syntax-only `-tnull` child had no `-o` argument and produced
no simulation image: **NO_IMAGE_SYNTAX_CHILD_FAILURE**. Original plan/seal,
all16 source archives, four vectors and four raw log streams remain intact.

Root reviewed and explicitly authorized one minimal repair: expand that first
file-list line into its three canonical source entries. No RTL, model, TB,
original runner, original plan or original seal changed. The separate frozen
repair plan/runner/seal reused all four original vectors without importing or
preparing the model and skipped the already passed core syntax check.

`repairs/repair01/reports/20261106T063818_810437Z/results.json` records9/9 PASS:
example syntax plus four compile/simulation pairs. Each child had a20s deadline,
fail-stop and no automatic retry. Cumulative evidence is **10 PASS /1 retained
FAIL /4 successful simulations**, four original numerical preparations and
zero repair preparations. Four successful VVP images remain for root handling;
there is no failed VVP image to retain or invent. Simulation stderr is empty;
compile stderr contains only missing-timeunit/precision warnings.

| Profile D/cap/tag/example | Records | Accepted samples | Commands | Max result wait |
| --- | ---: | ---: | ---: | ---: |
| 8/3/1/core |42|131|53|91 clocks|
| 12/97/8/core |54|516|65|108 clocks|
| 16/4096/32/core |55|4612|66|8294 clocks|
| 12/256/8/trigger capture |51|14739|62|364 clocks|

Totals:202 checked responses,19,998 samples,246 commands,48 resets, four injected
divider faults with clean recovery,554 held-output clocks and17,943 II1 input
checks. Counts include reset-cancelled records. The maximum profile filled and
scanned all4096 samples around a long flat maximum; its simulation took0.204s.
The measured8294-clock tail is within the conservative2N+112 budget at D16/N4096.
The TB uses a broader bounded watchdog; it does not assert an exact tail formula
for every record or qualify continuous frame service at a physical clock rate.

The actual capture example checked early triggers with less than64 samples of
prehistory, ring wrap after excess prehistory, configuration mutation, stable
output ownership, reset in all eleven active core phases and helper-fault flush.
Exact vector comparisons cover signed extrema/baselines, both polarities, earliest
flat and separated peak ties, threshold plateaus, missing/censored sides,
minimum amplitude boundaries, fractions1/128/255, even/odd half-Q16-LSB RNE ties,
strict LAST and invalid full-width commands. These finite cases do not prove
exhaustive parameter coverage or physical arrival-time accuracy.

Independent hash/argv/cwd/marker auditing is recorded in QUALIFICATION.json.
Its original212-check functional audit is retained as QUALIFICATION_FUNCTIONAL.json.
The post-qualification metadata record identifies .gitattributes' before/after
hashes and checked archive. Current functional inputs still match the repair
receipt; the primary receipt's sole current-source exception is .gitattributes,
while the prior failed attempt additionally differs in example/files.f. This
attribute change does not alter any HDL/preparation input bytes or rerun checks.
The follow-up metadata proof compares Git raw/clean object IDs for every formal
file under this package, including the two archived attributes as data, preserving
archived CRLF logs and JSON verbatim.
FAILURE_ARCHIVE.json preserves the syntax-failure classification, and
B40_DELIVERY.json maps current sources, both evidence sets, unchanged helpers,
raw logs, vectors and successful images. No synthesis, PnR, STA, board work,
old regression, cleanup, staging or commit was performed by this worker.
