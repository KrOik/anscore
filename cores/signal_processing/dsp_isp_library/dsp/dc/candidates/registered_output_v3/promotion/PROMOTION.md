# Prepared v3 promotion (historical plan, now applied)

Promotion executed after parent confirmed all gates. Current state and regression
evidence: `../../../evidence/promotion_20260925_035430_563461/` and active manifest.
The staged manifest beside this note remains the pre-promotion record.

Current default source remains3237, latency1. Archived byte-identical source,
manifest and README in `../../../legacy/latency1_3237f607/`; historic failures stay.
The manifest beside this note is staged, not the active metadata. All paths inside
it will be relative to the DC package root after explicit promotion.

After parent confirms repeat board, regular matrix and chain gates:

1. Copy frozen `../dc_stream.sv` into package `rtl/dc_stream.sv`; hash must remain
   9f69a02caaa165d8136250421f252e95af39ec4f1daadd48a0cbc11d90a73f97.
2. Publish updated manifest with actual gate evidence, latency2, capacity2 and
   per-stage elastic ready equations. Update README/SPEC, retaining bounded scope.
3. Run package model/RTL/long-window/host-vector tests. Their production default
   latency now reads active `ip_manifest.json`. Alternate source defaults to
   legacy latency1 unless `--latency 2` explicitly supplied; historical evidence
   remains reproducible. `test_mean_long.py` defaults to active production source.
4. Parent owns board/chain integration: block_harness default latency must change
   for DC only; standalone other cores retain their own latency. DC→statistics
   chain becomes nominal3 cycles (DC2+statistics1), with independent per-stage
   ready propagation rather than a single global-stall assumption.
5. Rebuild/retest from production path; candidate physical qualification alone
   must not be silently renamed final production-image qualification.

Both slots being full and stalled stops algorithm state; if front is empty it
can accept one sample even while final output stalls. Config commit requires
both empty. This distinction caused the parent's first chain oracle error and
must be preserved in all examples/scoreboards. No RTL or golden changed for it.
