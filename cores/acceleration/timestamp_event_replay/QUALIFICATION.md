# B50 finite qualification

Finite syntax/elaboration and unit simulation passed for the exact source bytes
sealed by FINITE_PLAN.json. The actual dual-feed composition simulation also
passed. HW_UNVERIFIED. Earlier source-draft NOT_RUN labels describe the freeze;
this additive note records the subsequent observed finite checks.

The separately reviewed one-attempt suite completed 19 targets: one isolated
preparation, two syntax checks, five compiles, five simulations and six expected
static rejections. The 13 positive targets exited 0. Each rejection retained its
actual raw FAIL status and exit 1, with a separate validated record accepting the
intentional undefined-parameter diagnostic. The rejected values were TIME_W 0/65,
DATA_W 0/1025 and TAG_W 0/33; no exit was rewritten to zero.

The outer supervised runner exited 0 in 19.469 s including capture, within 20 s.
Every inner target completed within its 20 s bound. No timeout, termination helper,
cleanup action or unconfirmed process remained. Both once guards are retained;
neither execution path may be invoked again. No retry occurred.

Root and independent worker_b reviewed the exact source gate. Worker_b then
independently audited 19 current/archived source pins, 32 tool pins, 19 initial,
19 terminal and 19 validated sidecars, 40 raw captures including the outer pair,
five retained images, seven generated fixture files, and the actual 19-command
order/argv/cwd/budgets. All hash/byte/count comparisons matched. The run retains
125 inner evidence files and five outer evidence files, plus the five images.

Each simulation's immutable STARTING record has PID null and its checked image
SHA before process creation, as required by the reviewed source order. The
preparation terminal/raw evidence was persisted before validation. All seven
fixture hashes are retained in results.json/preparation_files; a separate
preparation validation sidecar records the accepted 797 rows and seven files
before the first HDL launch. Preparation is labeled PREPARED_ONLY and is not
itself an HDL pass.

| Core profile | TIME_W | DATA_W | TAG_W | Cases | Rows | Accepted events | Emitted | Completions | Held-output cycles | Flush cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|tiny|1|1|1|12|148|12|8|11|26|6|
|ragged|9|37|5|12|195|20|17|11|22|5|
|wide|64|577|8|14|227|26|23|13|22|5|
|payload_max|64|1024|32|14|227|26|23|13|22|5|

The four standalone profiles total 52 cases, 797 rows, 84 accepted events,
71 emitted events and 48 completions; four cases deliberately cancel by reset.
Raw simulator counters agree with independently counted 27-field vector rows.
The actual wrapper test additionally checked four decoded ITCH Add events from
two complete MoldUDP64 packets, full payload/feed/sequence preservation,
anchored 1000-tick offer spacing, held output, EOS closure, sticky bad-session
poison and explicit held-output abort. Its exact composition PASS marker and
normal finish are retained.

Coverage includes fractional/minimum/maximum rate, equal timestamps, unsigned
extreme timestamps, missing source while time runs, pause, backwards-time error,
narrow-time overflow, overflow-held ownership, terminal-edge priority, abort,
reset and recovery. These are finite witnesses, not exhaustive correctness or
dependency requalification. Compiler captures retain inherited/missing timescale
warnings; preparation and simulation stderr are empty.

Evidence:

- reports/20261106T203507904088Z/results.json
  SHA256 `c439cb9b7d28684baee9e14086a438c8de1c91427828c28c9d3252b3bc0c0ac0`
- repository-local .git/anscore-b50-timestamp-event-replay-launch/results.json
  SHA256 `d3b95e7f4577eb92b937e9c43a690479e71fb0d1e558b2e0471ff04979638888`
- SOURCE_REVIEW.json, root plus worker_b exact gate
  SHA256 `93c890b24340537ba91cc510fd6b40ed0e9345448a1f83d6f27471545b6e3107`

This note changes no sealed source, plan, review, original result or capture.
No synthesis, PnR, STA, board test, PPA or historical regression was run. No
device fit, clock frequency, timing accuracy, power or hardware claim follows.
