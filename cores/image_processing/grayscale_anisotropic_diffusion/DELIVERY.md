# Offline delivery dependency

The current `files.f` and `example/files.f` are invoked from the repository root. Both use the package-local `rtl/deps/integer_divider.v`: an unchanged 1797-byte copy of the dependency used by the finite B29 tests, SHA256 `e09b6e9501a02fbcb0a89be50b5a0b787c71e9180b934b32d446601a299c5f6c`.

The original dependency path belongs to pre-existing untracked work and remains untouched. `PACKAGING_RELOCATION.json` binds the two source-list path substitutions, preserved original lists and original 143-file inventory. All computational RTL, Testbench, prepared inputs, sealed metadata and raw evidence retain their tested bytes. No preparation, numerical model or HDL check was rerun for this packaging-only relocation. Existing seals describe the original tested paths; they are historical evidence and are not resealed as newly executed delivery checks.

The copied divider inherits the repository Apache-2.0 license (included as this package's `LICENSE`). It is the same local restoring divider documented in `SOURCES.md`; no new divider capability or inherited synthesis/physical/board qualification is claimed. The delivered composition remains `LINT_PASS`, `UNIT_SIM_PASS`, `HW_UNVERIFIED` within its documented finite evidence scope.
