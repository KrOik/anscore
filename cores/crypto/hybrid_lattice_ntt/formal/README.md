# Glitch-Safety Formal Harness

This directory contains Task 7 prototype formal artifacts for glitch-sensitive
composition checks. These files do not claim side-channel protection is proven;
they provide test-gated harnesses for the current butterfly, masked-boundary,
randomness, and control-randomizer RTL.

## Current Scope

- `glitch_safety_harness` instantiates two `fused_butterfly` copies with
  identical public control inputs and independent symbolic coefficient inputs.
  Assertions check that registered control outputs (`busy` and `done`) do not
  diverge from secret coefficient differences.
- `glitch_masked2_harness` instantiates two `fused_butterfly_masked2` copies
  with independent symbolic shares and shared public control/randomness inputs.
  It checks missing-randomness error behavior, random-ready/busy/done/error
  agreement, accepted randomness registration, and output random-share reuse.
- `glitch_randomizer_harness` checks `control_flow_randomizer` valid/ready
  stability, invalid opcode handling, and no unsupported non-dummy opcode issue.
- Reusable checker modules cover valid/ready persistence, registered
  randomness use, and supported-opcode boundaries for future bind-style use.

## Commands

From the repository root:

```powershell
. .\scripts\env.ps1
sby -f .\cores\crypto\hybrid_lattice_ntt\formal\glitch_safety.sby butterfly
sby -f .\cores\crypto\hybrid_lattice_ntt\formal\glitch_safety.sby masked2
sby -f .\cores\crypto\hybrid_lattice_ntt\formal\glitch_safety.sby randomizer
```

The direct Yosys SAT fallback used for the deeper masked-boundary check is:

```powershell
. .\scripts\env.ps1
yosys -q -p "read -formal -sv -DGLITCH_ABSTRACT_BUTTERFLY cores/crypto/hybrid_lattice_ntt/formal/glitch_safety_harness.sv; read -formal cores/crypto/hybrid_lattice_ntt/src/fused_butterfly_masked2.v; prep -top glitch_masked2_harness; async2sync; flatten; chformal -remove -cover; select -module glitch_masked2_harness; sat -seq 16 -set-assumes -prove-asserts -verify"
```

The repository simulation regression remains:

```powershell
.\scripts\test_hybrid_lattice_ntt_sim.ps1
```

## Current Status

- `sby`, `yosys`, and `iverilog` are provided by the repo-local OSS CAD Suite
  after sourcing `scripts/env.ps1`.
- On 2026-06-06, `sby ... butterfly` passed bounded BMC at depth 32.
- On 2026-06-06, `sby ... masked2` passed bounded BMC at depth 10. The deeper
  direct Yosys SAT fallback above also passed at depth 16.
- On 2026-06-06, `sby ... randomizer` passed with k-induction at depth 16.
- The standard simulation regression was also run, but failed outside Task 7 in
  the shared `tb_top_uart_report` UART string expectation after earlier tests
  passed. These formal files are not compiled by that script.
