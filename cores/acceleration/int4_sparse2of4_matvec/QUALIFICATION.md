# B48 finite qualification

Current capability: **LINT_PASS, UNIT_SIM_PASS, INTEGRATION_CANDIDATE,
HW_UNVERIFIED**. These labels apply only to the exact sealed sources and finite
tests below. No synthesis, PnR, STA, board test, PPA or historical regression ran.

The original one-shot attempt is retained at
`reports/20261106T163626853644Z/results.json`, SHA256
`4bbcc6d6feadaa18317baaaa89195acd5d4fc28495c4ac6b2f2509a99713aafa`.
Four vector preparations and four HDL children passed. Its fifth HDL child
completed ten numerical frames, then failed the TB's numeric EOF assertion.
The failure, nine terminal records, eighteen raw streams and original image
remain unchanged. It was not rerun.

The separately reviewed `followup01` changes only the two TB EOF probes to a
token scan with explicit EOF confirmation. It reuses all four original vector
files, performs no preparations, and passed four compilations plus four
simulations. Receipt: `followup01/reports/20261106T164333302842Z/results.json`,
SHA256 `40ff70cec921726ade2d504732c1c75e0cb35e24a3ad94055700a10c2661df0c`.
The core checked 10/26/166 vector outputs at tiny/small/maximum configurations,
plus four recovery outputs each. The actual Top-2 wrapper checked 128 vector
outputs and six recovery outputs. Error responses, configuration rejection,
reset cancellation and held output checks passed at the recorded counters.

Root and worker_a reviewed each complete source set before execution. Root and
worker_a independently rehashed the execution evidence afterward; see
`POST_ROOT_AUDIT.json`, `followup01/POST_ROOT_AUDIT.json` and
`followup01/POST_PEER_AUDIT.json`. Every child used the 20/5/2 second limits;
none timed out or needed cleanup. All five original VVP images are retained in
ignored task directories and excluded from Git.

The sealed README and manifest record authoring-time pending state. This
additive qualification supplies the later evidence without altering executed
inputs. Numerical and protocol checks do not establish timing, area or board
readiness.
