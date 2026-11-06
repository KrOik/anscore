# B46 delivery: OUCH4.2 server-message subset

The unchanged decoder and actual SoupBinTCP composition passed the independently
gated finite qualification. Supported OUCH messages are S/A/U/C/E/J, with the
exact field/validation/packed-event contract in README.md. Other server messages
return BAD_TYPE. This is a protocol subset, without order/account state or
venue business-rule validation.

Canonical production source: `rtl/nasdaq_ouch42_server_rx.sv` and
`example/soupbintcp_ouch42_rx.sv`. `files.f` and `example/files.f` remain valid
explicit source entries. The example references the unchanged B45 canonical
Soup followup RTL and its MIT upstream FIFO. The qualified testbenches and
finite helper are the independent copies under `followup01/`.

The initial attempt remains frozen FAIL_STOP at
`reports/20261106T141729488803Z/results.json`, SHA256
`55409040a0e92e00e8bf49b753ef283f10e91f12b015d422305c8aabdc78242a`.
One preparation, five syntax checks and first core compile passed. The first
simulation failed at its trailing-whitespace header read; it has no success
marker and is not counted as a successful simulation. No RTL/oracle/vector or
original TB/helper/control was changed after this attempt.

Independent followup01 changed only the two copied TB file-reading boundaries:
exact2557/29 records followed by a strict EOF scan. Extra tokens still fail.
Its unique reviewed plan ran zero preparations and ten HDL children, all PASS,
including five simulations. Receipt:
`followup01/reports/20261106T142727240782Z/results.json`, SHA256
`978fb13d7680ba9136aded27c1e4b8920fee78bfe4f774252cfc4093851a5d8f`.
The complete exact plan executed, all83 source/archive bindings and25 tool paths
remained unchanged, all child PID/exit/raw evidence was persisted before result
parsing, and no target/helper process survived. No cleanup was needed.

| Profile | Vector records | Checked results | Accepted bytes | Resets | Canceled owners | Held-result checks |
|---|---:|---:|---:|---:|---:|---:|
| Core TAG1 | 2557 | 2560 | 309738 | 4 | 3 | 10240 |
| Core TAG8 | 2557 | 2560 | 309738 | 4 | 3 | 10240 |
| Core TAG32 | 2557 | 2560 | 309738 | 4 | 3 | 10240 |
| Soup depth128/TAG8 | 29 | 35 | 1155 | 9 | 3 | 116 |
| Soup depth4096/TAG32 | 29 | 35 | 5123 | 9 | 3 | 116 |

Total7750 checked results,935492 accepted bytes,30 resets,15 canceled owners
and30952 held-result checks. Each Soup profile delivered669 actual payload bytes
through the original FIFO and decoder. Coverage includes every checked enum
byte, all nonempty truncations, unsigned extremes, unsupported types,65535/
65536/70000-byte drains, empty Soup S, held future-prefix rejection, sequence
exhaustion/capacity failures and reset/recovery at three ownership phases.

Maturity: LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED.
No synthesis, PnR, STA, inherited regression, board, timing, power or PPA result
is claimed. Source-only statements in the frozen initial README/manifest and
followup README describe their pre-execution state; this delivery and
QUALIFICATION.json provide the completed validation state.
