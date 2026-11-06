# REPAIR01 loader environment recovery

The first authorized run stopped at sim_core_1x1_d8, exit0xC0000135 with empty
stdout/stderr: vvp.exe could not load dependencies from the suite lib directory.
Read-only import-string inspection found vvp -> bin/libvvp-1.dll ->
libgcc_s_seh-1.dll,libstdc++-6.dll,libreadline8.dll; the latter DLLs and their
libwinpthread-1.dll/libtermcap-0.dll dependencies reside in suite/lib. Original
child PATH had no suite entry. No HDL numerical output was observed.

This new standalone runner imports/dot-sources no previous runner or model. It
prepends suite/bin and suite/lib to each child PATH and preserves the inherited
PATH suffix. All other environment values are inherited; Python bytecode writes
remain disabled. No RTL/model/prep/TB/source-seal/original-plan byte is changed.

Exactly seven HDL children are authorized by the proposed plan: reuse the exact
compiled1x1 image for its simulation, then compile/simulate the other three
profiles. No successful syntax/compile child is repeated. The original literal
vectors and archived source are reused after raw hash gates; there is no new
model import or preparation. All original source/archive/vector/raw/receipt and
image bytes, new repair source/proofs and relevant runtime DLL/tool bytes are
frozen. Every input is rechecked before each child and at closeout. New compiler
images and all success/failure evidence are retained. If1x1 passes, its physical
image has both the original loader-failure evidence and successful simulation.

Process ownership is record-first: an active receipt is durably written before
launch and the completed raw receipt before counters are interpreted. Every
child has20s execution,5s tree termination and one joint2s primary/helper drain;
finally handles partial start/exception paths. First failure stops the repair.
An execution lock forbids retry. Source-only Freeze performs metadata hashing
only. Independent B review and explicit root gate precede unique -Execute.
Pending review proof is immutable; current review proof is separately written
after review and bound to the exact frozen plan hash. No cleanup/staging/commit,
inherited runner/model imports or synthesis/PnR/STA/board/PPA are permitted.
