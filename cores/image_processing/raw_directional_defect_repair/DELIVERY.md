# Delivery

`raw_directional_defect_repair` is an original Apache-2.0 adaptive RAW hot/dead
pixel repair core. Its original gated finite simulation suite passed; see
[QUALIFICATION.md](QUALIFICATION.md) for the exact receipt, coverage and pins.
Hardware status remains **HW_UNVERIFIED**.

## Delivered interfaces

| File | Purpose |
| --- | --- |
| `rtl/raw_directional_defect_repair.sv` | Same-phase envelope detector and four-direction repair with ordinary ready/valid |
| `files.f` | Explicit core compilation closure |
| `example/directional_bayer_rgb.sv` | Actual repair-to-production-demosaic composition |
| `example/files.f` | Explicit composition closure |
| `sim/prepare_vectors.py` | Direct independent integer oracle and finite vector preparation |
| `sim/tb_raw_directional_defect_repair.sv` | Scoreboard, stalls, marker-error and reset checks |
| `PRECHECK_PLAN.json`, `SOURCE_SEAL.json`, `ROOT_REVIEW.json` | Immutable execution identity and separate pre-execution reviews |
| `reports/20261106T164623_121013Z/` | Original terminal receipt, source snapshot and raw child/vector evidence |
| `.build/20261106T164623_121013Z/` | Eight retained, execution-bound VVP images |
| `POST_AUTHOR_AUDIT.json` | Read-only post-execution author evidence audit |

The unchanged reused modules are `stream_window.v`,
`stream_window_padded.v` and `bayer_demosaic.sv` at the exact paths and hashes in
SOURCE_SEAL.json. No dependency source was changed.

## Integration contract

The core supports WIDTH and HEIGHT1..512, their product at most65536,
BITS8/10/12 and TAG_W1..32. START captures enable, base threshold, shift and tag.
The eight original donor samples have the center's exact Bayer phase. Repairs
use the first minimum-gradient opposing pair in H, V, backslash, slash order,
a half-up pair mean and the published unsaturated adaptive threshold. The
two-pixel outer border passes unchanged. See the sealed [README.md](README.md)
for the exact numerical and streaming contract.

START owns a frame through DONE retirement. Hold output and DONE ready/valid
handshakes normally; reset cancels the current epoch. Input marker mismatches
set sticky error while fixed-length processing continues. The consumer must
discard the complete error epoch, including any output prefix already retired.
A new command does not fall through on the same edge as DONE retirement.

The real Bayer wrapper supports RAW8/10. It maps public RGGB/GRBG/GBRG/BGGR
patterns0/1/2/3 to the unchanged legacy engine's0/2/3/1 ABI. Public completion
waits for repair completion and final RGB retirement. The core has no hidden CE
connection.

## Evidence preservation

The original execution slot is consumed and guarded by EXECUTION_LOCK.json.
Its ATTEMPT_STARTED value is the immutable exclusive-attempt guard; the PASS
outcome is recorded in the terminal results.json. No rerun, source change,
evidence rewrite or cleanup was performed for this delivery.

The sealed README and manifest preserve their earlier authoring-time pending
status. QUALIFICATION.md supplies the later execution result without rewriting
executed inputs. POST_AUTHOR_AUDIT.json is explicitly the author's self-check;
the separate POST_PEER_AUDIT.json records worker_b PASS_NO_DISCREPANCY and
POST_ROOT_AUDIT.json records root PASS / NO_BLOCKER. Both bind the original
receipt. QUALIFICATION.json provides the structured finite qualification.

The finite result covers the recorded fixtures and parameters. Logical storage,
arithmetic widths and local pipeline service are documented in
[ARCHITECTURE.md](ARCHITECTURE.md); physical resources, timing, power and sensor
image quality remain unmeasured.

