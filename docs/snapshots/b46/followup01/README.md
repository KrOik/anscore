# Independent static followup01

The original B46 static attempt is retained unchanged. Its only child exited1
after0.765s with complete terminal JSON/raw capture, no cleanup and no active
PID. It stopped at the strict canonical-closure check for the B package's
`files.f`, before writing a successful source or structure snapshot.

The omitted source is
`cores/acceleration/stream_phase_unwrap/rtl/stream_phase_unwrap.sv`:
1807bytes, SHA256
`d9a42f515702dd51507e401c85a231a0a7b41c01b84bd8741113d39779d344cc`.
It has one module, `stream_phase_unwrap`, and no include or module dependencies.
Both B filelists already use these exact frozen bytes. It has no entry or exact
byte alias in the B45 canonical, package, support or bridge metadata. Root's
baseline Git-tree check also found that it was not committed in that baseline.

This followup records one `existing_worktree_dependency_bridge` and delivers
the original source bytes with the batch. It is an existing implementation
dependency, not a new capability or an inherited committed source. All twelve
previous bridge objects remain unchanged; the thirteenth stores this source's
hash, byte count and module identity for future snapshots. The strict filelist
subset and declaration-collision checks remain in force. Final totals are
394 inherited canonical sources +8 new package sources +1 existing dependency
bridge =403 HDL files and405 module declarations. This corrects the original
402/404 static inventory recorded in the frozen batch documentation.

The independent helper/plan/review, once guard, bounded launcher and successful
outputs live under this followup. Exact original static controls, guard, launcher
receipt, terminal JSON and raw output are copied under `retained_initial_static`
and bound against their original paths before the new audit. The original false
`inputs_unchanged` flag is preserved and actual input hashes are checked.

The HDL qualification evidence is unchanged:8 receipts,15 preparation children,
57 HDL children (53 PASS,4 retained FAIL),19 successful simulations and22
original VVP images (19 successful,3 failed simulations). No model or HDL child,
old audit/helper, synthesis, PnR, STA, board or PPA is run by this followup.
It authorizes exactly one new static child after root+peer source review,
with20s execution,5s tree termination and the sole2s target-exit observation.

Pre-execution status: SOURCE_ONLY / NOT_RUN.
