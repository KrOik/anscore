# Session 2026-10-03 — RMII transport corruption root-cause hunt + FCS gate

## Summary

Ethernet-harness board runs showed **non-deterministic, placement-sensitive
corruption**: identical requests to the same bitstream returned different
payloads, and different bitstreams of identical RTL failed differently.
Replayed request bytes were proven correct in sim (sim == model), so the
divergence lives in the silicon RMII path, not the cores.

## Evidence chain

1. `pfb` image: same request sent 8 times -> 7 distinct replies, diffs
   concentrated in payload bytes after ~offset 20; occasional timeouts.
2. `median` (DSP-free) passed 20/20 x2 rounds on broadcast -> transport works
   when no corruption lands in checked bytes.
3. resampler/hb_decim/hb_interp/pfb/isp5 showed sparse wrong words with
   clip-flag/saturation signatures.
4. Unicast requests were rejected by the parser (rx_frames++ but rx_udp+0);
   broadcast requests answered reliably.  DBG1 evidence: the rejected unicast
   STA1 arrived with **correctly parsed fields** (dest_local=1, ip_dst ok,
   dport 11452, csum_ok=1) but was dropped by the NEW FCS leg.
5. FCS residue on hardware was non-deterministic for identical frames
   (be26f702 / be26dbd5 / be26face for identical STA1) => the byte stream the
   MAC accumulates varies run-to-run => dribble/trailing-octet corruption
   after the payload region.

## Fix implemented (rmii_eth_pipe.sv + eth_rate_harness.v)

- CRC-32 (reflected poly 0xEDB88320, canonical serial step) accumulated over
  every octet from dest MAC[0] while in_frame.
- Sticky `fcs_hit` latches whenever the running CRC equals the good residue
  `32'hDEBB20E3` at frame_idx>=60 -- hits exactly after the last FCS octet,
  immune to trailing dribble bytes (they accumulate harmlessly after the hit).
- `fcs_ok` output = verdict for datagram-carrying frames (updated only when
  fcs_done_dg); eth_rate_harness gates run_done: bad carrier -> drop block,
  return to LOAD, host retries on timeout (no corrupt result ever leaves).
- `dbg_frame[167:0]` snapshot of last rejected frame (dmac, ip_dst, fcs_crc,
  eth_type, dport, proto, parse flags, ip_len_lo, reject-leg bit) read out
  via new `DBG1`/`DBG2` request-reply pair.

## Sim status

- tb_rmii_eth_pipe: ETHPIPE SIM PASS (all frames residue debb20e3).
- tb_eth_rate (resampler): ETH SIM PASS after gate integration.

## Board status

- fcsv2_* builds: 9 images with the fixed gate (in progress).
- Prior runs: all FAIL with blocks=0 on the dribble-inclusive build;
  that artifact dropped every block because the residue never settled.

## Open items

- If dribble bytes are replaced by **FCS stripping** (PHY drops FCS entirely),
  the residue never hits -> persistent drops; fall back to application-level
  payload CRC inside BLK2/RES2 if that is observed on the dbg probe.
- DDC/DUC deterministic failures persist independently (length-dependent:
  n<=7 pass, n>=17 fail on every config; identical on UART @27MHz and RMII
  @50MHz, DSP and LUT builds identical) -- separate RTL-vs-silicon debug.

## Resolution (v4 builds, ~03:00)

The wire FCS is **unverifiable on this PHY**: dbg_frame evidence shows the
carrier ends ~2 octets early (tail_idx 315 for a 318-byte frame), and the
residue varies for identical requests because the IP ID increments.  The FCS
gate was replaced with an **application-layer CRC-32 trailer** inside the UDP
payload:

- `eth_protocol.make_block_request` appends `crc32(hdr+words)` (4 octets).
- `rmii_eth_pipe` accumulates `pay_crc` over emitted payload octets and posts
  `pay_ok` (residue == DEBB20E3) at rx_end.
- `eth_rate_harness` runs past the trailer (byte_index 9-bit, `data_bytes`
  bound suppresses trailer RAM writes), enters TRAIL for one beat, then runs
  the block iff `pay_ok`; corrupt requests drop silently -> host retries.
- `dg_done` keeps late octets (trailer bytes streaming during the reply) from
  tripping flags[2].
- Replies are unprotected by design: a corrupted reply fails the NIC FCS at
  the host and retries; FPGA-internal integrity is covered by exact model
  comparison.

## Board evidence (v4 image series)

| core      | result | notes |
|-----------|--------|-------|
| median    | PASS x2 rounds (20/20 each) | clean baseline |
| resampler | round1 35/36, round2 36/36 | one intermittent last-word |
| hb_decim  | FAIL | every output saturates |
| hb_interp | FAIL | widespread saturation |
| framediff | FAIL | alternating 16-word tile errors |
| ddc       | FAIL | garbage outputs (pre-existing) |
| duc       | FAIL | saturation |
| pfb       | FAIL | 1/11 |
| ccm       | BLOCKED | 15708 LUT > 15000 gate |

Unicast now works: 6/6 STA1 + 5/6 BLK2 on the pfb image (the single BLK2 loss
is a dropped corrupt trailer, retried by the driver).

## Remaining core-level suspects

- resampler: identical verified request returns varying last-word values
  (0x7D7F correct vs 0x7DFF/0x5D7F/0x4D7F/0x7FFF) -> carry-adjacent bit
  pattern, datapath timing marginality suspected on the accumulate/round/sat
  chain at the final beat.
- hb_decim/hb_interp: deterministic saturation -> RTL bug in MAC path.
- framediff: structured alternating-tile errors -> ref-frame/addressing bug.
- ddc/duc: deterministic garbage (pre-existing, UART-reproducible).
- pfb: 1/11 -> deterministic bug.
- ccm: over resource gate; needs a slimmer variant or budget renegotiation.

## v6 root cause found (03:50): combinational MAC cones marginal on silicon

Sim==model on every failing case, but identical verified requests returned
different saturated outputs run-to-run -> non-deterministic -> timing
marginality, not logic.  P&R critical-path report showed 30+ chained LUT4
stages through lane_p multiply feeding acc->round->clip->m_tdata in ONE
cycle (fmax 55.7 MHz at a 50 MHz clock).

Fix: split the cone into registered phases in halfband_decim and
halfband_interp (prod_q stage: mux+mult one cycle, acc add the next;
acc_f stage: final sum registered, round/clip/output next cycle; tail
flag serializes EMIT).  Same EMIT stage added to polyphase_resampler.

Board results:
- v6_hb_decim: fmax 79.8MHz, board round 24/24 PASS (was: every case failed)
- v6_hb_interp: fmax 88.8MHz, board round 24/24 PASS
- Remaining failures are pure transport drops (trailer-CRC rejects),
  recovered by retries; no numerical errors.

## v5/v6 board results (final tally)

| core | image | result |
|------|-------|--------|
| median    | v4 | PASS 20/20 x2 rounds |
| hb_decim  | v6 (prod_q+acc_f pipelined) | PASS 24/24 round |
| hb_interp | v6 (prod_q+acc_f pipelined) | PASS 24/24 round |
| resampler | v5 (EMIT only) | 32/36 - 4 sparse clip-flag fails |
| resampler | v6 (+LATCH_OP operand stage) | build running |
| framediff | v4 | 26/60 structured tile fails (stateful, needs session replay) |
| pfb | v4 | 1/11 - cone pipelining not yet applied |
| ddc/duc | v4 | garbage - pre-existing deterministic bug |
| ccm | v4 | blocked at 15708 LUT > 15000 gate |

Transport loss observed at 30-60% during some windows (multicast noise +
PHY tail truncation): corrupt requests drop via trailer CRC and retry
recovers.  Every verified-correct block is end-to-end model-exact.

## resampler v6 note

LATCH_OP operand staging did not clear resampler's residual corruption
(25/36, still sparse clip+sat patterns, error positions flicker between
identical retries).  The remaining deep cones are the 128-entry
`history[history_index]` / `coefficients[coeff_index]` variable reads.
Next step: convert both to synchronous block-RAM reads (or a barrel-shift
schedule) so the operand path is a hard-macro read, not a mux tree.

## Session conclusion

- Transport: RESOLVED.  App-layer CRC32 + pay_ok + retries; unicast and
  broadcast verified; DBG1 diagnostics preserved.
- Physics: FPGA RTL was logically correct everywhere; silicon corruption
  traced to one-cycle combinational cones too deep for the dock's 50 MHz
  timing under Gowin P&R margins.  Registering the product and final-sum
  stages cured the failure class on hb_decim/hb_interp.
- Board-verified datapath-clean cores: median, hb_decim, hb_interp.
- Remaining: resampler (BRAM/shift operand path), framediff (session-state
  replay analysis), pfb (multi-cone pipelining), ddc/duc (pre-existing
  deterministic bugs), ccm (resource over-gate).
