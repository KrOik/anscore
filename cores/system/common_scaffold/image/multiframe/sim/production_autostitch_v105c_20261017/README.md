# Guarded autostitch production integration runner

This directory keeps its original v105c task name. The explicit `--candidate`
argument selects the final frozen d or compatible successor; the current
default is v105d_addrpipe. No command here invokes synthesis, PNR, pack, JTAG,
SRAM programming or a serial port. Hardware qualification remains root-owned.

The default is read-only freeze gating and a concrete mutation plan:

```powershell
python -B cores/system/common_scaffold/image/multiframe/sim/production_autostitch_v105c_20261017/integrate_and_verify.py --candidate cores/system/common_scaffold/board/tang25k/build/image_autostitch_frame_selftest_25k_20261017_v105d_addrpipe
```

Add `--preflight` to test a disposable proposed production copy. This reports
`PASS_STAGED_ONLY_NOT_APPLIED`, never production or board PASS. The regression
uses the frozen eight SAD, three divider, three store, six address-boundary
and six board simulation cases, followed by the original MF group bench with
its original checker and watchdog. Numeric goldens are unchanged. Only module
identifiers, source paths and staged source-hash inventories are adapted.

The entire original production reference app/store/SAD branch receives its
own namespace, avoiding collision with proposed public names. The unchanged
old-b app and old-c store remain local unit-test references. An exact private
SAD copy only resolves the inactive registration dependency of the old-b
divider reference; it is not used as the proposed application's SAD.

After actual50MHz setup+hold/resource gates and three distinct strict58-byte
SRAM loads PASS, root may call `--apply` with the final candidate. Optional
`--build-summary` and `--board-summary` name retained JSON files inside that
candidate; defaults are `build_qualified_scope_summary.json` and
`board_validation_summary.json`. Gate checks bind frozen source, retained
netlist, route/bitstream and three JTAG/UART records, including IDCODE1281b and
at least0.1s post-line silence with zero extra bytes. Missing/failing board
evidence prevents RTL writes. Simulation cannot substitute for those records.
The accepted build CE is exactly `1 of 4 physical edges; no timing exception`
or integer4, paired with actual50MHz/setup/hold/no-multicycle checks. Board
summary CE must be exactly `1/4; no timing exception`; no prefix matching is
used. The original route summary, three records and final scope must agree.

Exactly four RTL targets are in scope:

- Replace `img_mf_auto_stitch.v`: restore its public declaration and public
  SAD dependency names, changing no other bytes.
- Replace `img_mf_translation_sad.v`: restore its public declaration name.
- Add `img_mf_dual_frame_store_bram_read.v`, exact candidate bytes.
- Add `img_mf_signed_floor_divider.v`, exact candidate bytes.

The existing v101b `img_mf_dual_frame_store.v` stays unchanged. Root separately
integrates the two added module paths in `image/rtl_sources.f` and
`rtl_functional_sources.f` (each exactly once) before `--apply`. README and
manifest updates also belong to root; this runner never edits those shared
files. The apply gate rejects existing unexpected helpers or baseline drift.

Every apply first backs up original target bytes plus README, manifest and
both source lists, recording absent new files explicitly. It then writes
only the four RTL targets and runs all regressions against actual production
paths; this is recorded in executed command arguments. `APPLIED.json` binds
the candidate, target hashes, board evidence and backup. A failure retains
the backup, logs and failing run summary; it is not silently labelled PASS.
Subsequent `--verify` rechecks the retained board evidence and actual
production RTL without writing RTL. Existing production VVP/baselines and
unassigned RTL are hash checked and preserved by avoiding output writes there.

Every invocation uses a distinct `run_<UTC timestamp>` evidence directory.
New generated bench/VVP/large memory fixtures live under a disposable local
stage; only compact JSON/log diagnostics are retained, including on failure.
The frozen candidate is never modified by the runner. Broader scalar/simulation
coverage does not extend the physical RGB8884x3/shift1/6x5-canvas/CE1/4 scope.

Current status is intentionally supplied by the retained run summaries; no
production application or physical PASS is asserted by this README.

The first staged run's numerical regressions all passed, but its final gate
mistakenly compared mutable parent build progress as part of frozen evidence.
The retained failing run is `run_20261016_222419_834047`. The runner now calls
the actual official gate on every check and compares its immutable source,
simulation and freeze fields across a run. Parent RUNNING-to-PASS progress
does not alter those inputs. Frozen hashes and later board gates remain strict.
