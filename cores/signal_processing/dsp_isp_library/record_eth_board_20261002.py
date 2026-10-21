"""Record 2026-10-02 eth_rate_harness (RMII / BLK2) gate builds and board rounds.

Evidence classes:
  A) OSS gate builds: board/eth_rate_harness/evidence/<run>/build_summary.json
     (reported Fmax against the 50 MHz target, lut/dsp, bitstream sha256) and
     the matching hashes.json + eth.fs that the build produced.
  B) real-hardware rounds: board/eth_rate_harness/evidence/<run>/round_NN/
     verdict.json (BLK2 sweep verified against the independent Python model),
     plus the run's .boardlock_released.json reprogram bookkeeping.

This supersedes the 2026-09-27 blocker text for DSP-01/03/10.  Those rows said
"needs multi-count harness adapter", but BLK2 declares per-block in_count plus
host-computed out_expect, which is exactly the rate-change shape, and it has
now run on silicon: the resampler swept 6 configs x 8 stall codes x 12 block
lengths (36 cases) and reached 36/36 in a round, twice.  What actually gates
those rows now is core numerics on hardware, not transport framing.

Nothing here promotes a status.  board_test for the resampler is PARTIAL on
purpose: the 36/36 sweep is real and bound to bitstream 28255a53... (which
itself passed the 50 MHz gate), but it is round_02 - the first programming of
that same image fails two config-0 cases, so the cold-start behaviour is still
unexplained and acceptance needs >=2 clean rounds from power-up.
"""
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
EV = Path('cores/signal_processing/dsp_isp_library/board/eth_rate_harness/evidence')
ABS = ROOT / EV                      # same directory, absolute

LUT_BUDGET, DSP_BUDGET, TARGET_MHZ = 15000, 4, 50.0

# harness CORE_IDS -> goal.md requirement ids
REQ_OF_CORE = {'resampler': 'DSP-01', 'hb_decim': 'DSP-10',
               'hb_interp': 'DSP-10', 'ddc': 'DSP-03', 'duc': 'DSP-03',
               'median': 'ISP-03', 'pfb': 'DSP-16', 'framediff': 'ISP-17',
               'ccm': 'ISP-14'}

# gate builds whose build_summary.json is the reported evidence
GATES = {
    'resampler': ['resampler_ramfix', 'resampler_gate_20261002', 'v9_resampler'],
    'hb_decim': ['foldcenter_hb_decim', 'x1_hb_decim'],
    'hb_interp': ['reslice_hb_interp', 'x2_hb_interp'],
    'ddc': ['revert_ddc', 'x2_ddc'],
    'duc': ['abpre_duc', 'x2_duc'],
    'median': ['median_build_20261002_025516', 'x1_median'],
    'pfb': ['pfb_gate1', 'pfb_gate2', 'pfb_gate3', 'x2_pfb'],
    'framediff': ['fd_gate1', 'fd_persist1', 'rt_framediff'],
    'ccm': ['ccm_gate1'],
}

# board round run dirs (each holds round_01/ and, when it got that far,
# round_02/).  Order is oldest first; the newest is what gates the row.
ROUNDS = {
    'median': ['board_x1_median_20261004'],
    'hb_decim': ['board_x1_hb_decim_20261004'],
    # only the retimed-harness rounds: the earlier image carried the un-retimed
    # store-completeness comparator, whose false flags[1] made every numeric
    # block fail the host verdict even though its words matched the model.
    'framediff': ['board_rt_framediff_20261004'],
    'pfb': ['board_x2_pfb_20261004'],
    'resampler': ['boardfix_resampler_20261002_020732', 'boardram_resampler_20261002_021454', 'boardram_resampler_repeat', 'board_v9_resampler_bc_20261003'],
    'duc': ['board_duc_20261002_020205', 'boardram_duc_20261002_021545', 'board_x2_duc_20261004'],
    'ddc': ['board_ddc_20261002_020247', 'board_x2_ddc_20261004'],
    'hb_interp': ['board_hb_interp_20261002_020124', 'board_w2_hb_interp_20261004', 'board_x2_hb_interp_20261004'],
}

NOTE = {
 'DSP-01': ('multi-count BLK2 adapter exists and ran on silicon; resampler swept '
            '36/36 (6 configs, 8 stalls, 12 lengths, negative checks clean) on '
            'round_02 of two separate sessions, on bitstream 28255a53ad85e3bc '
            '(built+gated in evidence/resampler_ramfix: 100.17/79.63 MHz vs the '
            '50 MHz target, lut 7306, dsp 1).  Held at PARTIAL, not board-signed '
            'off, because round_01 of that same image fails 2 config-0 cases '
            '(sw00_r0_c0_n1 -> sticky clip flags=128; sw02_r0_c0_n7 -> word 25 '
            '= 32767 where the model says 0) and only the second programming '
            'passes; a sweep that needs a re-program to pass is a cold-start '
            'anomaly, not an acceptance.  Close it by explaining/removing the '
            'first-round failures and repeating >=2 clean rounds, on the current '
            'harness RTL (evidence/resampler_gate_20261002, sha 28f06e00908a7a4f, '
            '89.09/73.94 MHz, which differs from the board image only by the '
            '02:50 eth_rate_harness.v edit).'),
 'DSP-03': ('BLK2 ran on hardware for ddc and duc; both are numerically wrong on '
            'silicon while sim-clean (ddc 12/24 verified on image 9544674c556b, '
            'duc 1/24; failures saturating to the clip constants with sticky '
            'flags[7]).  The blocker is core arithmetic on hardware, not packet '
            'framing -- and two board-free experiments have now excluded the RTL '
            'and the synthesis as the cause: replaying a failing round\'s own '
            'archived request bytes through tb_eth_rate gives sim==model 24/24 '
            'while board==model is 1/24 (evidence/replay_duc_cold1), and '
            'dsp/ddcduc/tests/netlist_diff_duc.py diffs the post-synth_gowin '
            '-noalu gate netlist of duc_stream against the behavioural run with '
            'differing=0 on all four configs.  '
            'The RNE bit-slice + center-fold treatment that closed hb_decim WAS '
            'tried here on 2026-10-02 and was FULLY WITHDRAWN (commits 8112934 '
            'apply, 6302d57 + 458e9bd revert): bit-identical over 1.6M vectors '
            'per accumulator width and cycle-exact regression PASS, but timing-'
            'negative on both cores -- ddc 131.61 -> 70.95 MHz, duc 69.61 -> '
            '38.00 MHz (FAIL), and 46.56 MHz (FAIL) with only the shared '
            'ddcduc_iq_fir.sv changed.  Shipped RTL is the original cones.  '
            'Both cores now have a highest-margin gate image to program: ddc '
            'evidence/revert_ddc 131.61/100.88 MHz sha 763313c0, duc '
            'evidence/abpre_duc 69.61/68.64 MHz sha 777c357d.  Note what that '
            'implies: the exact RTL that failed 12/24 routes at 2.6x the 50 MHz '
            'target, so a marginal-cone explanation is now disfoured; the next '
            'discriminating image to prepare is synth_gowin -nodsp (pure-LUT '
            'multiply, tests whether the hard DSP block honours combinational '
            'use on silicon).  Blocked since ~03:00 2026-10-02 only by dock '
            'power: 192.168.137.16 unreachable, JTAG chain empty.'),
 'DSP-10': ('halfband rate change now runs on BLK2 (hb_interp 9/24 verified on '
            'image 85c520ccb801, before the cone rewrite).  hb_decim route/timing '
            'gate is closed by the two algebraically identical rewrites '
            '(80.55/62.85 MHz vs 41.74 MHz FAIL before), hb_interp 82.28/72.05 '
            'MHz; both are BUILD_PASS_NOT_BOARD and neither rewritten image has '
            'been programmed yet.  hb_decim has never had an eth board round.'),
 'DSP-16': ('the old blocker text ("pfb emits M-channel interleaved output - needs '
            'multi-channel adapter") was stale: BLK2 already carries this core '
            '(32-bit {im[15:0],re[15:0]} beats, one output per input, <=64 words '
            'per block), so pfb_stream is harness CORE 6 now, with the block '
            'cases driven through the core\'s own cycle-accurate model '
            '(dsp/pfb/models/model.py).  Proven over the RMII/UDP path in '
            'simulation: 10 numerically verified blocks + 7 config-reject paths + '
            'count-mismatch + STAT poll (evidence/pfb_sim2), and the throughput '
            'runner plans and verifies 60/60 blocks on it (evidence/tp_pfb_dry, '
            'dry-run so that rate describes this PC, not silicon).  M=8/P=8 is '
            'pinned at elaboration; other M/P need their own CORE ids.  NOT '
            'covered: the per-channel gain commit port is tied inactive, so the '
            'cfg_addr>=M error and atomic-gain paths are untested here, and clip '
            'is unreachable at signed16 (passband gain ~0.13) so flags[7] stays '
            'low as the model predicts.  board_test stays BLOCKED - not by the '
            'adapter any more but because the dock has been unpowered since '
            '~03:00; program evidence/pfb_gate3 (97.59 MHz, lut 11645, dsp 4), '
            'which is pfb_gate2 plus the config_word reject fix.'),
 'ISP-17': ('the old blocker ("framediff needs 2 frames - needs two-image '
            'adapter") was about the block shape, not the arithmetic.  The '
            'harness resets the core between blocks and this core\'s reference '
            'RAM *is* the state under test, so one block now carries FOUR 4x4 '
            'frames -- 64 words, the same budget CORE 5 already spends on one '
            '8x8 image -- and the cross-frame behaviour lives inside it.  '
            'framediff_stream is harness CORE 7.  Proven over RMII/UDP in '
            'simulation (evidence/fd_sim1, re-run in fd_gate1): 32 numerically '
            'verified blocks covering all 16 fd_cfg bundles, 7 malformed/'
            'config rejects, count-mismatch and STAT poll all clean, 64 words '
            'in = 64 out, cycles 66 at stall 0 (64 pixels + the core\'s '
            '2-cycle latency, tail-stripped report).  25 of those result words '
            'carry the scene_change bit, so seeding, a mid-block scene change '
            'and BOTH recovery policies (RESET and FAST_ADAPT) were checked '
            'against isp/framediff/models/model.py, never against the RTL.  '
            'Gate: evidence/fd_gate1 91.58/78.65 MHz against the 50 MHz floor, '
            'lut 4960, dsp 0, bitstream fefc15ea2e40.  '
            'CROSS-BLOCK PERSIST has since been built into the harness (rsvd '
            'byte: bit0 leaves the core unreset and steps over CONFIG, bit1 '
            're-commits a new bundle on that unreset core; rsvd=2 and rsvd>3 '
            'are malformed), so the same four frames also travel as four '
            'one-frame blocks.  evidence/fd_persist1 proves that in '
            'simulation: 8 session blocks plus 4 unpersisted controls of the '
            'identical frames, every one flags 0 with 16 words in and 16 out '
            'at cycles 18.  The differential is the evidence, not the pass '
            'count: the controls answer the seed value 0, the persisted blocks '
            'answer the real frame-to-frame difference, and the mid-session '
            're-config group answers the running background (50, 49, 58) -- '
            'three mutually exclusive answer sets, so an image that ignored '
            'rsvd could satisfy at most one.  build_plan refuses to emit a '
            'persisted case whose model answer equals the unpersisted one, '
            'which keeps the check from silently going vacuous, and a session '
            'block gets one attempt only (a re-send would advance the '
            'reference frame again).  NOT covered, and not claimed: a '
            'mid-session GEOMETRY change (the harness drives one fixed 4x4 '
            'raster with a table-free config word, so W/H cannot vary), any '
            'frame larger than 4x4, BITS=10, and the core\'s o_error path '
            'beyond "never fires" (reported sticky in result bit 10, model '
            'predicts 0, so a marker violation surfaces as a numeric '
            'mismatch).  Gate of the session-capable image: evidence/'
            'fd_persist1 106.54/85.68 MHz, lut 4975, dsp 0, bitstream '
            '4459e1ab548d.  board_test is blocked by dock power only '
            '(192.168.137.16 unreachable at 2026-10-02T03:56Z: ping exit=1, '
            'no ARP entry while the host self-ping answers); program evidence/'
            'fd_persist1 for the first round -- fd_gate1 predates PERSIST and '
            'answers a session request as malformed, which the host uses as '
            'the image-version probe.'),
 'ISP-14': ('ccm_stream is harness CORE 8, and the 2026-10-02 port-level audit '
            'underestimated its adapter need by 202 writes: "only the 3x3 matrix '
            'needs cfg_addr/cfg_wdata table writes (9 words)" is true of the '
            'matrix alone, but ccm_stream validates the WHOLE shadow image at '
            'commit, so a 9-word load either leaves the node banks at their '
            'identity default (making every tone-curve case vacuous) or is '
            'rejected.  The harness therefore writes ctrl + 9 matrix + 3 bias + '
            '99 lin + 99 enc = 211 beats and then pulses cfg_commit.  '
            'CONFIG also cannot wait for cfg_done the way the other seven cores '
            'do: a legal commit applies only at a presented SOF with an empty '
            'pipe, which here is the block\'s FIRST RUN beat -- strictly after '
            'CONFIG ends.  So the loader leaves on a bounded legality window '
            '(the core scans 99 flat node indices one per cycle) and requires '
            'cfg_pending still high at that point, because pending_apply is what '
            'a legal commit sets; a core that neither errored nor armed a '
            'pending apply is held until the 4095-cycle CONFIG window and comes '
            'back as config-rejected instead of hanging.  '
            'The core has NO saturation output port -- quantize() clamps to '
            '[0,MPX] silently -- so flags[7] is structurally 0 here and clip '
            'coverage is impossible by construction.  What replaces it: every '
            'case is asserted clamp-free against the model\'s PRE-clamp '
            'quantization (protocol.expected_clip), so a saturating case fails '
            'loudly rather than agreeing with a low flag, and the generated '
            'sweep band [96,160] per channel is the range all eight bundles are '
            'provably clamp-free over.  '
            'Simulation evidence/ccm_20261002_140446_225060: 42 requests = 32 '
            'numerically verified blocks (bundles 0-7 x 8/16/32/64 pixels, '
            'stalls rotated 0/1/7, every one flags 0, words in == words out) + '
            '6 malformed + 2 config-reject (cfg 8, i.e. the bundle index the '
            'table does not have, and a high-bit poison) + 1 count-mismatch + 1 '
            'STAT poll.  Throughput: 64 pixels in 70 cycles at stall 0 (~1.09 '
            'cycles/pixel = II 1 plus the 5-stage latency), consistent with the '
            'SPEC.  Gate evidence/ccm_gate1: 62.50/70.44 MHz against the 50 MHz '
            'floor, lut 14691 (routed LUT4 14755) of the 15000 budget, dsp 0 -- '
            'so ISP-14\'s "no multiplier primitive" claim holds inside a full '
            'harness image, not just standalone; bitstream 51e1157aefa4, and its '
            'eth_rate_harness.v is byte-identical to the RTL the session run '
            'below simulated.  '
            'CROSS-BLOCK SESSIONS are proven in simulation too, and the argument '
            'is a differential, not a pass count: evidence/'
            'ccm_20261002_145109_629663 is 54 requests = 32 blocks + 12 session '
            'cases (three phases of four: rsvd=0 controls, a rsvd=1 phase whose '
            'blocks ASK for bundle 5 while still running bundle 0, and a rsvd=3 '
            'phase that re-commits mid-session) + the same rejects.  What '
            'persists here is the APPLIED BUNDLE, which changes what a session '
            'block must differ from: on a streaming, stateless core a rsvd=3 '
            'block gives the same numbers as a fresh reset under that bundle, so '
            'the old "must differ from the unpersisted answer" guard would have '
            'rejected a perfectly good RECONFIG case; each case now names the '
            'interpretation it falsifies (rsvd=1 vs an image that configures '
            'every block, rsvd=3 vs an image that skips CONFIG), build_plan '
            'raises if the two answers coincide, and framediff\'s sim still '
            'passes on the same shared check_reply.  NOT covered, and not '
            'claimed: session cases on HARDWARE (run_eth_round only models '
            'CORE 7\'s reference RAM, and it now refuses --sessions for any '
            'other core rather than silently emitting an empty session group -- '
            'note the trap it refuses: a PERSIST block on CORE 8 runs the '
            'PREVIOUS bundle while the oracle would use that block\'s own '
            'config_word), the cfg_addr>=0x0D / >0x72 / >0xE2 address-error '
            'paths (the loader only ever writes legal addresses), and BITS=10.  '
            'board_test stays BLOCKED by dock power only; program evidence/'
            'ccm_gate1 for the first round.'),
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def read_gate(core, run):
    d, rel = ABS / run, EV / run
    bs, hs = d / 'build_summary.json', d / 'hashes.json'
    for p in (bs, hs):
        if not p.exists():
            raise FileNotFoundError(p.as_posix())
    g = load(bs)
    fmax = g['fmax_reported_mhz']
    bit = d / 'eth.fs'
    return dict(core=core, run=run, rel=(rel / 'build_summary.json').as_posix(),
                status=g['status'],
                fmax=fmax, worst_fmax=min(fmax), lut=g['lut'], dsp=g['dsp'],
                sha=g['bitstream_sha256'],
                on_disk=sha256(bit) if bit.exists() else None,
                sources={k: v[:12] for k, v in load(hs).items()})


def read_rounds(core, runs):
    out = []
    for run in runs:
        d = ABS / run
        lock = d / '.boardlock_released.json'
        # the board runner writes a session verdict.json that binds the run to
        # the exact bitstream it programmed
        sv = d / 'verdict.json'
        sess = load(sv) if sv.exists() else {}
        for rnd in sorted(d.glob('round_*')):
            vp, cp = rnd / 'verdict.json', rnd / 'capture_summary.json'
            if not vp.exists():
                continue                      # interrupted session, no result
            v = load(vp)
            s = v.get('summary') or {}
            rec = dict(core=core, run=run, round=rnd.name,
                       rel=(EV / run / rnd.name / 'verdict.json').as_posix(),
                       status=v['status'],
                       planned=s.get('planned'), verified=s.get('verified'),
                       failed=s.get('failed'),
                       configs=s.get('configs_covered'),
                       uncovered=s.get('configs_uncovered'),
                       lengths=s.get('lengths_covered'),
                       captures=s.get('negative_check_failures'),
                       image_sha=sess.get('sha256'),
                       image_build=sess.get('build'),
                       reprogram=(lock.exists() and len(list(d.glob('round_*'))) > 1))
            rec['ledger'] = load(cp).get('delivery_ledger') if cp.exists() else None
            rec['counters'] = load(cp).get('counters_delta') if cp.exists() else None
            out.append(rec)
    return out


def stage_for(rounds):
    """board_test for a requirement, from the rounds of one digest-bound image.

    PASS needs a full-sweep PASS round whose session records the programmed
    bitstream digest, with no round of that same image failing: a sweep that
    only passes after the second programming is not a board sign-off, it is a
    cold-start anomaly that still has to be explained.
    """
    if not rounds:
        return None, None
    best = [r for r in rounds if r['status'] == 'PASS']
    newest = rounds[-1]
    if best and all(r['image_sha'] for r in best):
        same_image = [r for r in rounds if r['image_sha'] == best[-1]['image_sha']]
        if all(r['status'] == 'PASS' for r in same_image):
            return 'PASS', best[-1]
        return 'PARTIAL', best[-1]
    if best:
        return 'PARTIAL', best[-1]
    return 'FAIL', newest


def main():
    led = json.loads((HERE / 'requirements.json').read_text(encoding='utf-8'))
    rows = {r['id']: r for r in led['requirements']}

    gates = {}
    for core, runs in GATES.items():
        for run in runs:
            g = read_gate(core, run)
            if g['worst_fmax'] < TARGET_MHZ:
                raise AssertionError('gate build below target: %s %s MHz'
                                     % (run, g['worst_fmax']))
            if g['lut'] > LUT_BUDGET or g['dsp'] > DSP_BUDGET:
                raise AssertionError('budget exceeded: %s lut=%d dsp=%d'
                                     % (run, g['lut'], g['dsp']))
            if g['on_disk'] and g['on_disk'] != g['sha']:
                raise AssertionError('bitstream does not match its summary: ' + run)
            gates.setdefault(REQ_OF_CORE[core], []).append(g)

    rounds = {}
    for core, runs in ROUNDS.items():
        rounds.setdefault(REQ_OF_CORE[core], []).extend(read_rounds(core, runs))
    for rid in rounds:
        rounds[rid].sort(key=lambda r: (r['run'], r['round']))

    report = []
    for rid in sorted(set(gates) | set(rounds)):
        row = rows[rid]
        ss = dict(row.get('stage_status') or {})

        def add(field, rel):
            if not (ROOT / rel).exists():
                raise FileNotFoundError(rel)
            if rel not in row.setdefault(field, []):
                row[field].append(rel)

        for g in gates.get(rid, []):
            add('route_timing', g['rel'])
            add('synthesis', g['rel'])
        for r in rounds.get(rid, []):
            add('board_injection', r['rel'])
            caprel = (Path(r['rel']).parent / 'capture_summary.json').as_posix()
            if (ROOT / caprel).exists():
                add('board_capture', caprel)
            if r['reprogram']:
                add('board_reprogram', r['rel'])
        board, key = stage_for(rounds.get(rid, []))
        if board:
            ss['board_test'] = board
            ss['fx2_capture'] = board      # same rounds captured over RMII/UDP
        if rid in NOTE:
            ss['note'] = NOTE[rid]
        ss['transport'] = 'rmii-udp eth_rate_harness BLK2/RES2'
        row['stage_status'] = ss
        report.append(dict(id=rid, board=board,
                           board_run=(key or {}).get('run'),
                           board_round=(key or {}).get('round'),
                           verified=(key or {}).get('verified'),
                           planned=(key or {}).get('planned'),
                           fmax=[g['worst_fmax'] for g in gates.get(rid, [])],
                           status=row['status']))

    (HERE / 'stage_status_eth_20261002.json').write_text(
        json.dumps(dict(gates=[{k: v for k, v in g.items() if k != 'sources'}
                               for rs in gates.values() for g in rs],
                        rounds=[r for rs in rounds.values() for r in rs],
                        rows=report), ensure_ascii=False, indent=1),
        encoding='utf-8')
    (HERE / 'requirements.json').write_text(
        json.dumps(led, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    for r in report:
        print(json.dumps(r, ensure_ascii=False))


if __name__ == '__main__':
    main()
