# v105d production integration handoff

Prepared by `/root/awb_board_candidate`. Production RTL and shared metadata
have not been written by this agent. Root owns source-list changes, apply,
README/manifest changes and authoritative board records. There are no active
preflight jobs or disposable `.stage_*` directories in this task directory.

## Frozen inputs and executable runner

- Candidate: `cores/system/common_scaffold/board/tang25k/build/image_autostitch_frame_selftest_25k_20261017_v105d_addrpipe`.
- Candidate freeze SHA256: `9716b7f6596f4018e1b9043016cede36385bd9bf8055a60589a1a5806e13714f`;
  all 45 entries verified again after staging and physical qualification.
- Runner: `integrate_and_verify.py`, SHA256
  `72b5cda430d831a1bb8bd8b3997301e369894968a0170551ca54d9a96e371f0f`.
- Final staged run: `run_20261016_222734_354442/summary.json`,
  `PASS_STAGED_ONLY_NOT_APPLIED`, SHA256
  `b5cd274ecce9e0c8e2185ec6cc0c9101325abf89910bcaedbd68a2f824032867`.
- Final lightweight plan: `run_20261016_223121_257207`.
- Strict read-only board gate: `board_gate_precheck_20261016_223122_343529.json`,
  `PASS_READ_ONLY_BOARD_GATE_NOT_APPLIED`.

The preflight passed eight SAD, three divider, three store, six address-boundary
and six board simulations plus the original MF group. Its before/after production
snapshot, including RTL, README, manifest, source lists and existing group VVP,
is byte-identical. Numerical goldens, checkers and watchdog were not changed.
`APPLIED.json` does not exist at handoff. Both successful and failed prior runs
are retained. The first preflight's final gate failure was caused by comparing
mutable parent build progress; its regressions passed. This was repaired to
compare immutable source/simulation/freeze evidence, while still invoking the
official verifier and retaining strict physical evidence checks.

## Root integration sequence and exact root-directory commands

First add the two missing helper paths to each of:

- `cores/system/common_scaffold/image/rtl_sources.f`
- `cores/system/common_scaffold/rtl_functional_sources.f`

The apply gate requires all four exact entries below to occur once in each
list; retain their existing surrounding source order and other entries:

```text
cores/system/common_scaffold/image/multiframe/img_mf_auto_stitch.v
cores/system/common_scaffold/image/multiframe/img_mf_translation_sad.v
cores/system/common_scaffold/image/multiframe/img_mf_dual_frame_store_bram_read.v
cores/system/common_scaffold/image/multiframe/img_mf_signed_floor_divider.v
```

From `D:\sipeedTANG20K`, root then runs:

```powershell
python -B cores/system/common_scaffold/image/multiframe/sim/production_autostitch_v105c_20261017/integrate_and_verify.py --apply --candidate cores/system/common_scaffold/board/tang25k/build/image_autostitch_frame_selftest_25k_20261017_v105d_addrpipe --build-summary build_qualified_scope_summary.json --board-summary board_validation_summary.json
```

The command rechecks the frozen candidate and three real-board records before
writing, backs up all four targets plus README/manifest/source lists, writes
only the four target RTL files, then compiles actual production paths through
all regressions. Expected final result: `PASS_PRODUCTION_REGRESSION`,
`production_pass: true`, and all four actual paths recorded in commands.
`APPLIED.json` is created with the backup inventory and target/board hashes;
the retained run summary is authoritative for completed regression status.
If a failure follows the writes, preserve its backup/logs and inspect it; do
not use `--apply` again or silently label that partial state complete.

After successful apply, root updates README/manifest and its authoritative
ledger to describe the implemented behavior and bounded board scope. A later
read-only actual-production regression, only if needed after further changes,
uses:

```powershell
python -B cores/system/common_scaffold/image/multiframe/sim/production_autostitch_v105c_20261017/integrate_and_verify.py --verify --candidate cores/system/common_scaffold/board/tang25k/build/image_autostitch_frame_selftest_25k_20261017_v105d_addrpipe --build-summary build_qualified_scope_summary.json --board-summary board_validation_summary.json
```

Do not rename the task directory for this integration; it intentionally keeps
its original v105c name. The selected and default candidate is final v105d.

## Four permitted RTL outcomes

| Production target | Action | Final SHA256 |
| --- | --- | --- |
| `img_mf_auto_stitch.v` | Replace; private declaration/dependency names restored to public names only | `dbf6c6db33766702a587ecb349cdec702e3a173df7380cf1c034434d92b1b42f` |
| `img_mf_translation_sad.v` | Replace; private declaration restored to public name only | `ca92cb353faa48c6a6cb9b4ecc1aaa805e72e409ec231a8758c5af51e40e1359` |
| `img_mf_dual_frame_store_bram_read.v` | Add exact candidate bytes | `94ab31cf07fd340b690af4e4b90b4b96e8598110d9724478b54867f0c829f0c1` |
| `img_mf_signed_floor_divider.v` | Add exact candidate bytes | `0f203a774e8a955c9bb4f0b46ed8964d3b99a57ef62526bf7319d8ef8b6b5ea4` |

The existing public `img_mf_dual_frame_store.v` remains the integrated v101b
implementation, SHA256 `b70b3bb7cb54f5be268b6a568a66909cbf74fbdf2432893f1312bd6c06d55d8a`.
No other production RTL may change during this runner's apply.

## Physical evidence and scope

Root independently routed and programmed the candidate; this agent ran only
simulation and read-only verification of those physical records in this phase.
Qualified route: 7,804 LUT, 1,862 FF, eight physical BRAM primitives, zero DSP;
reported Fmax 59.85/60.67 MHz with actual 50 MHz setup and hold passing, CE 1/4,
and no multicycle exception. Bitstream SHA256:
`2af204973b9b3abb2cb9c4c9cb6d2f087180cbacd6860fa3370b1579efd06360`.
Qualified-build SHA256:
`b8f2f41d085314b150bc13e326a0a24e0892249428b7467442e4a43df66ced22`.
Board-summary SHA256:
`59ad5677fed55ba086737fcac4a67193a7fbd710abda5cd27ba56a23622fa7b8`.

Three distinct real SRAM loads, each JTAG ID `0x1281b`, return code zero,
exactly 58 UART bytes and at least 0.1 seconds post-line observation with no
extra bytes:

- `board_uart_20261017_062851_495459.json`
- `board_uart_20261017_062858_083024.json`
- `board_uart_20261017_062903_333836.json`

```text
STC PASS F=20 I=003E A=004B O=012C E=0000 D=64FB8FCF C=F\r\n
```

Physical qualification covers the isolated RGB888 4x3 registration/stitch
chain, shift 1, two ROI samples, nine ordered trials and 6x5 output canvas:
32 commands, 62 main/75 auxiliary inputs, 300 outputs and 14 expected errors.
Broader scalar/address/simulation coverage does not qualify larger-frame
timing or continuous-video throughput. The read-only gate binds frozen
sources, retained netlist, original/qualified route, bitstream and three
UART records, including clock/CE/scope consistency.

## External references, cleanup and status

The frozen candidate includes successful HTTP audits of OpenCV/Vitis/ELAS and
FPGADesignElements references, commit/license/hash provenance, local design
differences and bounded-address mathematical contracts. No downloaded source
cache was kept. The d address-pipeline additions reference synchronous RAM,
bounded counters and registered transaction ownership rather than copying
an implementation without reconciling collision/CE/reset semantics.

New staged benches, VVP images and large fixtures were removed automatically.
Only compact diagnostic logs/JSON, failed evidence and source code remain
here (approximately 0.5 MB at handoff); existing baseline artifacts were
preserved. No claim is made that unrelated preexisting system TEMP files
have been removed. Root may now change the shared source lists and run the
exact apply command above; this agent's read-only preflight is finished.
