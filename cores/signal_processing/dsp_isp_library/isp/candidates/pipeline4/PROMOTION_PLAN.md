# Production promotion preparation

State: preparation only. Default `isp/csc_stream.v` has not been changed.
Frozen candidate SHA256 must remain
`0ecd8f6416ef31cdcce3b9557b7972a310bba88006a101ce3f0458d347e9237a`.
Parent confirmation of10-bit physical/reprogram qualification is the explicit
sequencing gate. Staged manifest is not an installed production package.

Read-only reference audit identified these affected entry points:

| Entry | Required change at promotion |
|---|---|
| isp/csc_stream.v | archive one-cycle original, copy candidate byte-for-byte; assert hash |
| isp/test_csc_rtl.py | default oracle/test must use latency4/global pipeline; retain source+latency1 regression for archived old RTL |
| isp/synth_csc.py | source path remains same; refresh isolated8/10 metrics, attach latency/source identity |
| isp/CSC_SPEC.md | replace one slot/one cycle with four slots/four cycles, global-stall and stage-valid update behavior |
| isp/CSC_STATUS.md | distinguish old isolated reports, new same-hash build/board chain and default regression |
| board/block_harness/run.py | default CSC source now latency4; DC/identity stay1; explicit-source historical runs keep declared latency; fail on mismatch |
| board/block_harness/protocol.py | keep latency default1 for historical images; physical runner supplies saved image metadata |
| board/block_harness/README.md | avoid claiming all cores n+1; CSC pipeline4 uses n+4, no change to transport bandwidth claims |
| requirements.json, record_initial_progress.py, central status | parent-owned integration only; report mapping, do not edit here |

Proposed executable/default test implementation: make the numerical/protocol
driver accept an explicit source and latency, retaining its independent model
and old1-cycle contract while selecting the tested4-stage transaction queue
for production. Test all24 configurations, full-rate, random ready/gaps, reset,
config sequencing, illegal BITS/modes, X-invalid recovery and checker mutation.
Do not alter coefficients, float/bit-exact results or historical expected words.

Promotion sequence after gate:

1. Archive old canonical RTL and its one-cycle test/source hashes under a new
   legacy directory, leaving prior evidence intact.
2. Copy frozen candidate to canonical RTL and prove byte identity to both board
   build snapshots; install manifest referencing core/coefficients and evidence.
3. Update local specs/default runners/test latency policy, keeping explicitly
   selected old images on1-cycle expected counters.
4. Run independent model, default RTL regression, old-core regression, X-invalid
   recovery, default CSC8/10 real UART test, and affected DC/identity regression.
5. Bind production-source hash to qualified candidate build/image hashes and
   fresh board/reprogram verdicts; do not claim any different bitstream tested.
   Reuse unchanged physical evidence only with this explicit same-source link.
6. Report final manifest/default entry evidence and any remaining integration
   boundary to parent; parent updates shared capability/requirement ledger.

Observed physical evidence (read directly): CSC8 original failing vector replay
and both12-mode board runs are PASS for image SHA
`c1cfabbaaa67d71481b755c0f6a22adb6a56cef07c3e99ec2ceceaa501b5b843`, latency4.
10-bit board verdicts are not yet entered in the staged manifest. No physical
operations were performed by this subagent.
