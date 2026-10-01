"""Local UDP round driver for eth_rate_harness: program separately, measure here.

Runs one measurement round against the FPGA endpoint over the dock's 100M RMII
link: liveness ping, pre-traffic STAT poll, a deterministic case sweep of
BLK2/RES2 blocks verified against the reused dsp_rate_harness model oracle
(never against DUT output), post-traffic STAT poll and transport throughput.

Evidence written to --output: verdict.json, driver.log, capture_summary.json
and frames/case_NN_{req,resp}.bin.  Exit 0 only on PASS.

Case list: the drate harness's own regression cases (clamped to this
transport's 60-word input cap) plus a seeded sweep covering every canned
config with block lengths 1 / 2 / 7 / 60 and stall 0..7.  A case is dropped
only when no prefix length is modelable within the 128-word capture; if that
leaves any config of the core unexercised the verdict is PARTIAL, not PASS.

Usage:
    python run_eth_round.py --core resampler --output artifacts/eth_r1 \
        [--bind-ip 192.168.137.1] [--target-ip 192.168.137.16] [--port 11452] \
        [--rounds 2] [--seed 1] [--timeout 2.0] [--attempts 2] [--clock-mhz 50] \
        [--dry-run]
"""
import argparse, json, locale, random, re, struct, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import eth_protocol as ep

FRAME_LEN_CLASSES = (1, 2, 7, ep.ETH_IN_CAP)
STALLS = tuple(range(8))
TAG_BASE = 0xE7100000


def now_iso():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


class Log:
    """Mirror progress to stdout and driver.log without hiding anything."""

    def __init__(self, path=None):
        self.fh = open(path, 'w', encoding='utf-8') if path else None

    def __call__(self, msg):
        line = '%s %s' % (time.strftime('%H:%M:%S'), msg)
        print(line, flush=True)
        if self.fh:
            self.fh.write(line + '\n')
            self.fh.flush()

    def close(self):
        if self.fh:
            self.fh.close()


# ------------------------------------------------------------------ words --
def make_words(core, n, rng):
    """Input vectors in the drate harness's packing: signed Q15 for the real
    cores, {q[15:0], i[15:0]} for the DDC/DUC streams, one unsigned 8-bit pixel
    in the low byte of each word for the ISP median frame, and a 24-bit RGB
    pixel for the ISP-14 CCM."""
    if core == 5:
        return [rng.randrange(256) for _ in range(n)]
    if core == 8:
        # Every channel stays in [96,160], the band protocol.cases() proves
        # clamp-free for ALL eight bundles.  It is not caution for its own
        # sake: ccm_stream has no saturation output, so flags[7] is structurally
        # 0 here, and a generated pixel that clamps would make the synthetic
        # board and the real silicon disagree about a case neither one got wrong.
        px = [96 + rng.randrange(65) for _ in range(3)]
        return [px[0] | (px[1] << 8) | (px[2] << 16) for _ in range(n)]
    if core < 3:
        return [rng.randrange(-30000, 30000) & 0xFFFF for _ in range(n)]
    return [((rng.randrange(-10000, 10000) & 0xFFFF)
             | ((rng.randrange(-10000, 10000) & 0xFFFF) << 16)) for _ in range(n)]


def plan_block(core, config, words):
    """Longest prefix of `words` that the model can evaluate inside the
    transport limits -> (words, out_expect) or None.  Interpolation-heavy
    configs exceed the 128-word capture on long blocks and some DDC configs
    need a minimum block length, so shrinking is the honest fix."""
    for n in range(min(len(words), ep.ETH_IN_CAP), 0, -1):
        w = list(words[:n])
        try:
            out = ep.model_oracle(config, w, core)
        except Exception:
            continue
        if len(out) <= ep.MAX_RESULT_WORDS:
            return w, len(out)
    return None


def build_plan(core, seed, rounds, sessions=False):
    """(planned, skipped, coverage_gaps).  Deterministic for fixed core/seed."""
    planned, skipped = [], []

    def add(case):
        planned.append(case)

    # 1) the drate harness's own regression cases, adapted to this transport.
    #    Their tags are kept verbatim so results stay comparable with the
    #    UART harness runs of the same core.
    for idx, (tag, config, words, stall) in enumerate(ep.protocol.cases(core=core)):
        got = plan_block(core, config, words)
        if got is None:
            skipped.append(dict(source='drate_cases', config=config,
                                requested_len=len(words), stall=stall,
                                reason='no block length modelable within '
                                       'the %d-word capture'
                                       % ep.MAX_RESULT_WORDS))
            continue
        w, out_expect = got
        add(dict(name='drate%02d' % idx, source='drate_cases',
                 tag=tag, config=config, words=w,
                 stall=stall, out_expect=out_expect,
                 requested_len=min(len(words), ep.ETH_IN_CAP)))

    # 2) seeded sweep: every config x every length class x stall rotation
    for r in range(rounds):
        rng = random.Random((seed * 1000003) + core * 97 + r * 31)
        ci = 0
        for config in range(ep.config_count(core)):
            for want in FRAME_LEN_CLASSES:
                cand = make_words(core, want, rng)
                got = plan_block(core, config, cand)
                if got is None:
                    skipped.append(dict(source='sweep', config=config,
                                        requested_len=want, stall=None,
                                        reason='no block length modelable'))
                    continue
                w, out_expect = got
                add(dict(name='sw%02d_r%d_c%d_n%d' % (ci, r, config, want),
                         source='sweep',
                         tag=(TAG_BASE + (core << 16) + r * 256 + ci) & 0xFFFFFFFF,
                         config=config, words=w, stall=(r * 4 + ci) % 8,
                         out_expect=out_expect, requested_len=want))
                ci += 1

    # 3) PERSIST sessions -- real hardware only (a synthetic board has no state
    #    to persist, so faking one would agree with itself by construction).
    #    CORE 7 is the model that carries a reference frame across blocks, so the
    #    same four frames are sent three ways: as four independent blocks, as a
    #    rsvd=1 session, and as a session whose configuration is changed mid-run
    #    with rsvd=3.  An image that ignored the session byte would answer the
    #    session group with the independent-block numbers, so those two groups
    #    cannot both be right -- that is the differential, and the plan refuses
    #    to emit a persisted case whose model answer equals the unpersisted one.
    if sessions and core not in (7,):
        # A session plan needs a model of what survives the block boundary, and
        # only CORE 7 has one here.  Silently emitting the ordinary plan instead
        # would let a run claim session coverage it never asked the board for.
        raise RuntimeError('--sessions is only modelled for core framediff '
                           '(got %r)' % ep.CORE_NAMES[core])
    if sessions and core == 7:
        P = ep.protocol
        scenes = [[v] * (P.FD_W * P.FD_H) for v in (40, 200, 40, 200)]

        def sess(base, name, seq):
            st = None
            for k, (sel, rsvd) in enumerate(seq):
                w = scenes[k]
                if rsvd == 0:
                    st = P.fd_state()       # a reset core re-seeds, in model too
                want = P._fd_run(w, sel, st)
                if rsvd and want == ep.model_oracle(sel, w, core):
                    raise RuntimeError('session case %s%02d is not separable from '
                                       'an unpersisted block' % (name, k))
                add(dict(name='%s%02d' % (name, k), source='session',
                         tag=(base + k) & 0xFFFFFFFF, config=sel, words=w,
                         stall=0, out_expect=len(want), want=want, rsvd=rsvd,
                         requested_len=len(w)))

        sess(0x5E350000, 'ctl', [(0, 0)] * 4)
        sess(0x5E450000, 'pers', [(0, 0), (0, 1), (0, 1), (0, 1)])
        sess(0x5E550000, 'recfg', [(0, 0), (5, 3), (5, 1), (5, 1)])

    configs_planned = sorted({c['config'] for c in planned})
    gaps = [c for c in range(ep.config_count(core)) if c not in configs_planned]
    return planned, skipped, gaps


# ------------------------------------------------------------------- ping --
def ping(target_ip, count=3, log=None):
    """OS liveness probe; the design also answers ICMP echo requests."""
    if sys.platform == 'win32':
        cmd = ['ping', '-n', str(count), '-w', '1000', target_ip]
    else:
        cmd = ['ping', '-c', str(count), '-W', '1', target_ip]
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=30)
    except Exception as exc:
        return dict(command=' '.join(cmd), ok=False, error=repr(exc))
    enc = 'gbk' if sys.platform == 'win32' else (
        __import__('locale').getpreferredencoding(False) or 'utf-8')
    text = r.stdout.decode(enc, errors='replace')
    received = None
    m = re.search(r'[Rr]eceived\s*[=:]\s*(\d+)', text)
    if m:
        received = int(m.group(1))
    else:                                   # non-English ping output
        received = len(re.findall(r'TTL=', text))
    ok = r.returncode == 0 and bool(received)
    res = dict(command=' '.join(cmd), rc=r.returncode, ok=ok,
               replies=received, expected=count,
               fully_responded=(received == count),
               output_tail=text.strip().splitlines()[-2:])
    if log:
        log('ping %s: rc=%s replies=%s/%s' % (target_ip, r.returncode,
                                              received, count))
    return res


# --------------------------------------------------------- synthetic board -
class SyntheticBoard:
    """--dry-run stand-in: replies with contract-shaped datagrams built purely
    from the model.  Exercises the host plumbing; it is never board evidence,
    which is why the resulting verdict status is DRY_RUN, not PASS."""

    def __init__(self, core):
        self.core = core
        self.c = dict(zip(ep.STA_FIELDS, (0,) * 10))
        self.c['core_index_and_flags'] = core & 0xFF
        self.tx_datagrams = self.tx_bytes = self.rx_datagrams = self.rx_bytes = 0
        self.discarded = []
        self.local = ('127.0.0.1', 0)

    def close(self):
        pass

    def exchange(self, payload, magic, timeout=None):
        t0 = time.perf_counter()
        self.tx_datagrams += 1
        self.tx_bytes += len(payload)
        if payload == ep.make_status_request():
            data = ep.synth_status_response(self.core, self.c)
        elif payload[:4] == ep.BLK_MAGIC:
            _t, cfg, n, stall, _oe, rsvd = struct.unpack(ep.HDR, payload[4:16])
            if rsvd:
                # There is nothing to persist here: this stand-in recomputes every
                # block from scratch, so it cannot show a session's answer even
                # shape-wise.  Answering a session request with a per-block reply
                # is exactly the failure the real differential is designed to
                # catch, so it has to be a loud refusal instead.
                raise AssertionError('dry-run cannot model a PERSIST session '
                                     '(rsvd=%d); a session round needs hardware'
                                     % rsvd)
            words = list(struct.unpack('<%dI' % n, payload[16:16 + 4 * n]))
            cycles = 500 + 40 * n + 8 * stall
            out = ep.model_oracle(cfg, words, self.core)
            self.c['rx_frames'] += 1
            self.c['rx_udp'] += 1
            self.c['tx_frames'] += 1
            self.c['words_in'] = (self.c['words_in'] + n) & 0xFFFFFFFF
            self.c['words_out'] = (self.c['words_out'] + len(out)) & 0xFFFFFFFF
            self.c['blocks'] += 1
            self.c['cycles_total'] = (self.c['cycles_total'] + cycles) & 0xFFFFFFFF
            data = ep.retitle_response(
                ep.synth_block_response(cfg, words, self.core, cycles=cycles),
                struct.unpack('<I', payload[4:8])[0])
        else:
            raise AssertionError('dry-run: unknown request magic')
        self.rx_datagrams += 1
        self.rx_bytes += len(data)
        return data, int((time.perf_counter() - t0) * 1e6)

    def status(self, timeout=None):
        data, rtt = self.exchange(ep.make_status_request(), ep.STA_MAGIC_RESP,
                                 timeout=timeout)
        return ep.parse_status_response(data), rtt


# --------------------------------------------------------------- one round -
def poll_status(conn, log, name, attempts=3, timeout=3.0):
    for i in range(1, attempts + 1):
        try:
            st, rtt = conn.status(timeout=timeout)
            log('%s: %s (rtt %d us)' % (name, json.dumps(st), rtt))
            return st, rtt, i, None
        except Exception as exc:
            log('%s attempt %d failed: %r' % (name, i, exc))
            time.sleep(0.2)
    return None, None, attempts, 'status poll failed'


def run_case(conn, case, core, log, frames_dir, attempts, timeout):
    # A session case carries its own expectation: the numbers a persisted block
    # must produce depend on what the PREVIOUS block left in the core, which no
    # per-block oracle can know.
    rsvd = case.get('rsvd', 0)
    want = case.get('want')
    req = ep.make_block_request(case['tag'], case['config'], case['words'],
                                case['stall'], core, rsvd=rsvd, expected=want)
    if frames_dir:
        (frames_dir / ('%s_req.bin' % case['name'])).write_bytes(req)
    rec = dict(name=case['name'], source=case['source'], tag='%08x' % case['tag'],
               config=case['config'], in_count=len(case['words']),
               requested_in_count=case['requested_len'], stall=case['stall'],
               rsvd=rsvd,
               out_expect=case['out_expect'], ok=False, attempts=0,
               rtt_us=None, cycles=None, flags=None, flag_names=[], outc=None,
               negative_check='SKIP', error=None)
    raw = None
    # A session block is not re-sendable: if the board processed the request and
    # only the reply was lost, repeating it advances the reference frame once
    # more and every later block of the session is then wrong.  So a session gets
    # one attempt and a lost reply is recorded as a failure.
    # range(1, 1) is empty: a session case asked for 'one attempt' and got
    # zero, so it was never sent and was then recorded as ok=False - the
    # unsent block counted against the core as a failure.  One attempt means
    # one execution, and a session is never re-sent because a lost reply
    # would leave the core one frame ahead of the model.
    for attempt in range(1, 2 if want is not None else attempts + 1):
        rec['attempts'] = attempt
        try:
            raw, rtt = conn.exchange(req, ep.RES_MAGIC, timeout=timeout)
        except TimeoutError as exc:
            rec['error'] = 'timeout: %s' % exc
            log('  %s attempt %d: %s' % (case['name'], attempt, exc))
            continue
        except Exception as exc:
            rec['error'] = 'send/recv: %r' % exc
            log('  %s attempt %d: %r' % (case['name'], attempt, exc))
            continue
        if frames_dir:
            (frames_dir / ('%s_resp.bin' % case['name'])).write_bytes(raw)
        try:
            got = ep.parse_block_response(raw, case['tag'], case['config'],
                                          case['words'], case['stall'], core,
                                          expected=want)
        except AssertionError as exc:
            # verify raises with tuple payloads; str() keeps them readable and
            # avoids %-formatting a tuple as multiple arguments
            rec['error'] = 'verify: %s' % str(exc.args[0] if exc.args else exc)
            log('  %s VERIFY FAIL %s' % (case['name'], rec['error']))
            break                       # a wrong answer is not a lost packet
        rec.update(ok=True, error=None, rtt_us=rtt, cycles=got['cycles'],
                   flags=got['flags'], flag_names=got['flag_names'],
                   outc=got['outc'], inc=got['inc'],
                   design_status=got['status'])
        # the harness's own negative check: the verifier must reject a flipped
        # bit in the last result byte (or in cycles when there is no result)
        bad = bytearray(raw)
        bad[19 if got['outc'] == 0 else 20 + 4 * got['outc'] - 1] ^= 1
        try:
            ep.parse_block_response(bytes(bad), case['tag'], case['config'],
                                    case['words'], case['stall'], core,
                                    expected=want)
        except AssertionError:
            rec['negative_check'] = 'PASS'
        else:
            rec['negative_check'] = 'FAIL'
            rec['error'] = 'checker accepted a corrupted payload'
            rec['ok'] = False
        break
    return rec, raw


def throughput(before, after, elapsed_s, cases, clock_mhz, link):
    """Transport numbers are wall-clock figures for THIS host path; design
    numbers come from the DUT's own counters and cycle reports."""
    d = ep.status_delta(before, after)
    bits = d['words_out'] * 32
    bpc = (bits / d['cycles_total']) if d['cycles_total'] else None
    req_bytes = sum(16 + 4 * c['in_count'] for c in cases)
    resp_bytes = 532 * len(cases)
    dgrams = (link['rx_datagrams'] - link['rx0']) + (link['tx_datagrams']
                                                     - link['tx0'])
    payload = (link['rx_bytes'] - link['rx_bytes0'] + link['tx_bytes']
               - link['tx_bytes0'])
    return dict(
        elapsed_s=round(elapsed_s, 6),
        block_datagrams=dgrams,
        block_payload_bytes=payload,
        transport_datagrams_per_s=round(dgrams / elapsed_s, 1) if elapsed_s > 0
        else None,
        transport_bytes_per_s=round(payload / elapsed_s, 1) if elapsed_s > 0
        else None,
        request_bytes=req_bytes, response_bytes=resp_bytes,
        design_words_out=d['words_out'],
        transport_bytes_per_s_from_design_words=(
            d['words_out'] * 4 / elapsed_s) if elapsed_s > 0 else None,
        cycles_delta=d['cycles_total'],
        design_mbit_s_contract_formula=(bits / d['cycles_total'])
        if d['cycles_total'] else None,
        design_bits_per_cycle=round(bpc, 6) if bpc is not None else None,
        design_mbit_s_at_reported_clock=round(bpc * clock_mhz, 3)
        if bpc is not None else None,
        clock_mhz_assumed=clock_mhz,
        note=('transport_bytes_per_s_from_design_words is '
              '(words_out_delta*4)/elapsed as specified, and '
              'design_mbit_s_contract_formula is (words_out_delta*32)/'
              'cycles_delta; the latter is Mbit/s only if one cycle is 1 us. '
              'eth_rate_harness counts 20 ns cycles (50 MHz domain), so '
              'design_mbit_s_at_reported_clock is the physical rate. All '
              'transport_* values measure this host UDP path, not the DSP '
              'cores; compare them with the ~11.5 kB/s UART/FX2 path.'),
        per_block_cycles=[c['cycles'] for c in cases],
        per_block_rtt_us=[c['rtt_us'] for c in cases])


def delivery_ledger(counters, link, status_polls=2):
    """Reconcile this host's sent datagrams against the dock's own RX counters.

    The pipe increments rx_udp for each accepted UDP request, so a request the
    dock threw away shows up as expected > rx_udp -- NOT as rx_err.  rx_err
    counts frames that were never our requests (this PC's background
    LLMNR/mDNS/NetBIOS multicast does reach the dock on a switched link), and
    reading an rx_err increment as a rejected request is exactly the
    misattribution that sent a whole investigation down the "unicast RX gate"
    path.

    `status_polls` are the before/after STAT requests, which the dock RXes
    inside the counter window but which are outside the host's tx snapshot, so
    they are expected but not counted in `sent`.
    """
    sent = link['tx_datagrams'] - link['tx0']
    expected = sent + status_polls
    return dict(
        datagrams_sent_in_sweep=sent,
        status_polls_in_window=status_polls,
        expected_rx_udp=expected,
        rx_frames_delta=counters['rx_frames'],
        rx_udp_delta=counters['rx_udp'],
        tx_frames_delta=counters['tx_frames'],
        blocks_delta=counters['blocks'],
        rx_err_delta=counters['rx_err'],
        ping_delta=counters['ping'],
        dropped_requests=max(0, expected - counters['rx_udp']),
        surplus_rx_udp=max(0, counters['rx_udp'] - expected),
        note=('dropped_requests is the only drop evidence here; rx_err_delta is '
              'background multicast and must be measured over an idle window '
              '(probe_unicast.py idle leg) before any attribution.'))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--core', required=True, choices=sorted(ep.CORE_IDS))
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--bind-ip', default='192.168.137.1')
    p.add_argument('--target-ip', default=ep.ENDPOINT_IP)
    p.add_argument('--port', type=int, default=ep.UDP_PORT)
    p.add_argument('--rounds', type=int, default=1,
                   help='repetitions of the seeded sweep')
    p.add_argument('--seed', type=int, default=1)
    p.add_argument('--timeout', type=float, default=2.0)
    p.add_argument('--attempts', type=int, default=2,
                   help='UDP is lossy: block requests are retried on timeout')
    p.add_argument('--clock-mhz', type=float, default=50.0,
                   help='clock the design counts its cycles in (RTL: 50 MHz)')
    p.add_argument('--no-ping', action='store_true')
    p.add_argument('--broadcast', action='store_true',
                   help='send requests to 255.255.255.255 (see EthClient)')
    p.add_argument('--boot-wait', type=float, default=0.0,
                   help='seconds to wait for the design before polling')
    p.add_argument('--dry-run', action='store_true',
                   help='no sockets: answer from the model, verdict DRY_RUN')
    a = p.parse_args(argv)

    core = ep.core_id(a.core)
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    frames = out / 'frames'
    frames.mkdir(exist_ok=True)
    log = Log(out / 'driver.log')
    t_start = time.time()

    verdict = dict(status='FAIL', transport='udp-dry-run' if a.dry_run else 'udp',
                   dry_run=bool(a.dry_run), started_at=now_iso(),
                   core=core, core_name=a.core, endpoint=a.target_ip,
                   port=a.port, bind_ip=a.bind_ip, seed=a.seed,
                   rounds=a.rounds, clock_mhz=a.clock_mhz,
                   eth_in_cap=ep.ETH_IN_CAP,
                   endpoint_mac=ep.FPGA_MAC if not a.dry_run else None,
                   cases=[], skipped=[], summary={}, protocol=str(ep.PROTOCOL_PATH))
    if a.boot_wait:
        log('boot wait %.1f s' % a.boot_wait)
        time.sleep(a.boot_wait)

    try:
        planned, skipped, gaps = build_plan(core, a.seed, a.rounds,
                                            sessions=(not a.dry_run
                                                      and core == 7))
        verdict['skipped'] = skipped
        log('plan: %d cases, %d skipped, config coverage %s'
            % (len(planned), len(skipped),
               'complete' if not gaps else 'MISSING %s' % gaps))
        if not planned:
            raise RuntimeError('no modelable case for core %s' % a.core)
        tags = [c['tag'] for c in planned]
        if len(set(tags)) != len(tags):
            raise RuntimeError('duplicate request tags in plan')

        if a.dry_run:
            verdict['ping'] = dict(command='skipped (dry-run)', ok=None)
        elif a.no_ping:
            verdict['ping'] = dict(command='skipped (--no-ping)', ok=None)
        else:
            verdict['ping'] = ping(a.target_ip, log=log)

        conn = SyntheticBoard(core) if a.dry_run else ep.EthClient(
            bind_ip=a.bind_ip, target_ip=a.target_ip, port=a.port,
            timeout=a.timeout, broadcast=a.broadcast)
        try:
            before, before_rtt, _n, err = poll_status(conn, log, 'status_before',
                                                      attempts=3,
                                                      timeout=max(3.0, a.timeout))
            if before is None:
                raise RuntimeError('pre-traffic %s (%d attempts)' % (err, _n))
            verdict['status_before'] = before
            verdict['status_before_rtt_us'] = before_rtt

            link = dict(tx0=conn.tx_datagrams, rx0=conn.rx_datagrams,
                        tx_bytes0=conn.tx_bytes, rx_bytes0=conn.rx_bytes)
            t0 = time.perf_counter()
            results = []
            for i, case in enumerate(planned):
                log('case %d/%d %s cfg%d n=%d stall%d expect %d out'
                    % (i + 1, len(planned), case['name'], case['config'],
                       len(case['words']), case['stall'], case['out_expect']))
                rec, _raw = run_case(conn, case, core, log, frames, a.attempts,
                                     a.timeout)
                results.append(rec)
                log('  -> %s rtt=%s us cycles=%s outc=%s flags=%s neg=%s'
                    % ('ok' if rec['ok'] else 'FAIL', rec['rtt_us'],
                       rec['cycles'], rec['outc'], rec['flags'],
                       rec['negative_check']))
            elapsed = time.perf_counter() - t0
            link.update(rx_datagrams=conn.rx_datagrams,
                        tx_datagrams=conn.tx_datagrams,
                        rx_bytes=conn.rx_bytes, tx_bytes=conn.tx_bytes)
            verdict['link'] = link

            after, after_rtt, _n2, err2 = poll_status(conn, log, 'status_after',
                                                      attempts=3,
                                                      timeout=max(3.0, a.timeout))
            if after is None:
                raise RuntimeError('post-traffic %s (%d attempts)' % (err2, _n2))
            verdict['status_after'] = after
            verdict['status_after_rtt_us'] = after_rtt
            verdict['discarded_datagrams'] = list(getattr(conn, 'discarded', []))
            verdict['transport_datagrams'] = dict(
                tx=getattr(conn, 'tx_datagrams', None),
                rx=getattr(conn, 'rx_datagrams', None),
                tx_bytes=getattr(conn, 'tx_bytes', None),
                rx_bytes=getattr(conn, 'rx_bytes', None))
        finally:
            if not a.dry_run:
                conn.close()

        verdict['cases'] = results
        ok = [c for c in results if c['ok']]
        bad = [c for c in results if not c['ok']]
        neg_bad = [c for c in results if c['negative_check'] != 'PASS']
        covered = sorted({c['config'] for c in ok})
        gaps = [c for c in range(ep.config_count(core)) if c not in covered]
        rtts = [c['rtt_us'] for c in ok if c['rtt_us'] is not None]
        verdict['summary'] = dict(
            planned=len(results), verified=len(ok), failed=len(bad),
            skipped_generated=len(skipped), configs_total=ep.config_count(core),
            configs_covered=covered, configs_uncovered=gaps,
            stalls_covered=sorted({c['stall'] for c in ok}),
            lengths_covered=sorted({c['in_count'] for c in ok}),
            rtt_us=dict(min=min(rtts), max=max(rtts),
                        mean=round(sum(rtts) / len(rtts), 1)) if rtts else None,
            cycles_total_ok=sum(c['cycles'] or 0 for c in ok),
            words_out_ok=sum(c['outc'] or 0 for c in ok),
            negative_check_failures=[c['name'] for c in neg_bad])
        if elapsed > 0:
            verdict['throughput'] = throughput(before, after, elapsed, ok,
                                               a.clock_mhz, link)
        if bad:
            verdict['status'] = 'FAIL'
            verdict['failure_reason'] = '%d/%d cases failed on the board: %s' % (
                len(bad), len(results), [c['name'] for c in bad][:8])
        elif gaps:
            verdict['status'] = 'PARTIAL'
            verdict['failure_reason'] = ('configs %s never exercised: %s'
                                         % (gaps, [s for s in skipped][:4]))
        elif a.dry_run:
            verdict['status'] = 'DRY_RUN'
            verdict['failure_reason'] = ('model-synthetic responses only; not '
                                         'board evidence')
        else:
            verdict['status'] = 'PASS'
    except Exception as exc:
        verdict['status'] = 'FAIL'
        verdict['error'] = repr(exc)
        log('ERROR %r' % exc)
    finally:
        verdict['finished_at'] = now_iso()
        verdict['wall_s'] = round(time.time() - t_start, 3)
        (out / 'verdict.json').write_text(
            json.dumps(verdict, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        s = verdict['summary']
        counters = None
        if verdict.get('status_before') and verdict.get('status_after'):
            counters = ep.status_delta(verdict['status_before'],
                                       verdict['status_after'])
        # The dry-run board only counts block requests in rx_udp; real hardware
        # RXes the before/after STAT polls inside the counter window too.
        ledger = None
        if counters is not None and verdict.get('link'):
            ledger = delivery_ledger(counters, verdict['link'],
                                     status_polls=0 if a.dry_run else 2)
            verdict['delivery_ledger'] = ledger
        (out / 'capture_summary.json').write_text(json.dumps(dict(
            status=verdict['status'], core=a.core, dry_run=a.dry_run,
            endpoint=a.target_ip, port=a.port, planned=s.get('planned'),
            verified=s.get('verified'), failed=s.get('failed'),
            skipped=s.get('skipped_generated'),
            configs_covered=s.get('configs_covered'),
            configs_uncovered=s.get('configs_uncovered'),
            throughput=verdict.get('throughput'),
            counters_delta=counters,
            delivery_ledger=ledger,
            frames=sorted(f.name for f in frames.glob('*.bin')),
            verdict=str(out / 'verdict.json')), indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        log('verdict %s -> %s' % (verdict['status'], out / 'verdict.json'))
        if ledger is not None:
            log('delivery: %d sent + %d STAT polls expected, rx_udp %d, '
                'dropped_requests %d, surplus %d; rx_err %d is background '
                'multicast, not a rejected request'
                % (ledger['datagrams_sent_in_sweep'],
                   ledger['status_polls_in_window'], ledger['rx_udp_delta'],
                   ledger['dropped_requests'], ledger['surplus_rx_udp'],
                   ledger['rx_err_delta']))
        if verdict['status'] == 'DRY_RUN':
            log('DRY-RUN: replies were model-synthesised locally; this is NOT '
                'board evidence and is not a PASS')
        log.close()
    # DRY_RUN exits 0 so run_eth_board --dry-run can validate the plumbing;
    # it is still never reported as a board PASS anywhere in the evidence.
    return 0 if verdict['status'] in ('PASS', 'DRY_RUN') else 1


if __name__ == '__main__':
    sys.exit(main())
