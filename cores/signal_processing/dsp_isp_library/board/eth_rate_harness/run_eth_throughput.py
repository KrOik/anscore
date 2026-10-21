"""Sustained-throughput measurement for the eth_rate_harness RMII/UDP path.

This is the number that justifies retiring the FX2 + 115200-baud UART capture
(~11.5 kB/s) for throughput work: stream many small blocks back-to-back at the
endpoint while sampling its STAT counters on a time period, then report the
wall-clock rate of the host transport.

Honesty of the figures:
  * transport_datagrams_per_s / transport_bytes_per_s are WALL-CLOCK rates of
    this PC's UDP path measured with model verification switched ON for every
    block, so host-side oracle time is inside the denominator.  The breakdown
    (board_wait_s, host_model_s, host_other_s) is reported so the reader can
    see what actually limits the number.
  * the design's own cycles_total / words_out counters are reported separately
    as `design`; they are never presented as a transport measurement.
  * no response is trusted: every block reply is verified with the reused
    dsp_rate_harness model oracle, so a fast but wrong stream still FAILs.

Usage:
    python run_eth_throughput.py --core resampler --output artifacts/eth_tp \
        [--blocks 400] [--in-words 8] [--config 0|all] [--stall 0] \
        [--status-period 0.5] [--seed 7] [--clock-mhz 50] [--ping-first] \
        [--bind-ip 192.168.137.1] [--target-ip 192.168.137.16] [--port 11452] \
        [--dry-run]
"""
import argparse, json, random, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import eth_protocol as ep
import run_eth_round as rr

UART_BASELINE_BYTES_PER_S = 11520      # measured FX2/115200 capture path


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--core', required=True, choices=sorted(ep.CORE_IDS))
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--blocks', type=int, default=400,
                   help='number of back-to-back block requests')
    p.add_argument('--in-words', type=int, default=8,
                   help='input words per block (1..%d)' % ep.ETH_IN_CAP)
    p.add_argument('--config', default='0',
                   help='canned config index, or "all" to rotate over them')
    p.add_argument('--stall', type=int, default=0)
    p.add_argument('--status-period', type=float, default=0.5,
                   help='minimum seconds between STAT counter samples')
    p.add_argument('--seed', type=int, default=7)
    p.add_argument('--clock-mhz', type=float, default=50.0)
    p.add_argument('--bind-ip', default='192.168.137.1')
    p.add_argument('--target-ip', default=ep.ENDPOINT_IP)
    p.add_argument('--port', type=int, default=ep.UDP_PORT)
    p.add_argument('--timeout', type=float, default=2.0)
    p.add_argument('--ping-first', action='store_true',
                   help='ICMP liveness probe before streaming (skipped by default: '
                   'the first STAT poll is the real gate)')
    p.add_argument('--dry-run', action='store_true',
                   help='model-synthesised replies; rates describe this PC only')
    a = p.parse_args(argv)

    core = ep.core_id(a.core)
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    log = rr.Log(out / 'driver.log')
    report = dict(status='FAIL', dry_run=a.dry_run, started_at=rr.now_iso(),
                  core=a.core, core_id=core, endpoint=a.target_ip, port=a.port,
                  blocks_planned=a.blocks, in_words=a.in_words,
                  config=a.config, stall=a.stall, seed=a.seed,
                  clock_mhz=a.clock_mhz, samples=[], results=[])
    conn = None
    try:
        if not 0 <= a.stall <= 7:
            raise ValueError('stall must be 0..7')
        if not 1 <= a.in_words <= ep.ETH_IN_CAP:
            raise ValueError('in_words must be 1..%d' % ep.ETH_IN_CAP)
        n_cfg = ep.config_count(core)
        if a.config == 'all':
            configs = list(range(n_cfg))
        else:
            sel = int(a.config)
            if not 0 <= sel < n_cfg:
                raise ValueError('config %s outside 0..%d' % (a.config, n_cfg - 1))
            configs = [sel]

        rng = random.Random(a.seed * 7919 + core)
        planned = []
        # plan_block can only SHORTEN a block, and two cores refuse every length
        # except their frame contract: CORE 5 is one 8x8 image and CORE 7 is four
        # 4x4 frames, both exactly ETH_IN_CAP words.  So offer the requested
        # length first and the transport cap second, and report the length that
        # was actually streamed instead of the one that was asked for.
        lengths = list(dict.fromkeys((a.in_words, ep.ETH_IN_CAP)))
        used_len = None
        for i in range(a.blocks):
            cfg = configs[i % len(configs)]
            got, used = None, a.in_words
            for n in lengths:
                got = rr.plan_block(core, cfg, rr.make_words(core, n, rng))
                if got is not None:
                    used = n
                    break
            if got is None:
                continue          # not modelable at any length: never send it
            w, out_expect = got
            used_len = used
            planned.append(dict(name='tp%05d' % i, source='throughput',
                                tag=(0x78000000 + i) & 0xFFFFFFFF, config=cfg,
                                words=w, stall=a.stall, out_expect=out_expect,
                                requested_len=a.in_words, in_words=used))
        report['blocks_modelable'] = len(planned)
        if not planned:
            raise RuntimeError('no modelable block for core %s config %s at %s '
                               'words' % (a.core, a.config,
                                          ' or '.join(str(n) for n in lengths)))
        report['in_words_used'] = used_len
        log('streaming %d blocks (config %s, %d words in, mean %d words out)'
            % (len(planned), a.config, used_len,
               round(sum(c['out_expect'] for c in planned) / len(planned), 2)))
        if a.ping_first:
            report['ping'] = (dict(command='skipped (dry-run)', ok=None)
                              if a.dry_run else rr.ping(a.target_ip, log=log))

        conn = rr.SyntheticBoard(core) if a.dry_run else ep.EthClient(
            bind_ip=a.bind_ip, target_ip=a.target_ip, port=a.port,
            timeout=a.timeout)
        first = conn.status()[0]
        report['status_before'] = first
        series = []
        t_wall0 = time.perf_counter()
        last_sample = t_wall0
        board_wait = host_model = 0.0
        verified = failed = 0
        for i, case in enumerate(planned):
            req = ep.make_block_request(case['tag'], case['config'],
                                        case['words'], case['stall'], core)
            t0 = time.perf_counter()
            raw, rtt = conn.exchange(req, ep.RES_MAGIC, timeout=a.timeout)
            board_wait += rtt / 1e6
            t1 = time.perf_counter()
            got = {}
            try:
                parsed = ep.parse_block_response(raw, case['tag'], case['config'],
                                                 case['words'], case['stall'],
                                                 core)
                status = 'ok' if parsed['status'] == 'PASS' else 'fail'
                got = parsed
            except AssertionError as exc:
                status = 'fail'
                log('block %d rejected: %s' % (i, exc.args[0] if exc.args else exc))
            t2 = time.perf_counter()
            host_model += t2 - t1
            verified += status == 'ok'
            failed += status == 'fail'
            report['results'].append(dict(block=i, config=case['config'],
                                          in_count=len(case['words']),
                                          out_expect=case['out_expect'],
                                          rtt_us=rtt, status=status,
                                          cycles=got.get('cycles'),
                                          outc=got.get('outc'),
                                          flags=got.get('flags'),
                                          verify_s=round(t2 - t1, 6)))
            if (i + 1) % 25 == 0 or i + 1 == len(planned):
                el = time.perf_counter() - t_wall0
                log('  %d/%d blocks, %d verified, %.1f datagram/s, %.0f byte/s'
                    % (i + 1, len(planned), verified,
                       (conn.tx_datagrams + conn.rx_datagrams) / el,
                       (conn.tx_bytes + conn.rx_bytes) / el))
            if time.perf_counter() - last_sample >= a.status_period:
                st, srtt = conn.status()
                series.append(dict(t=round(time.perf_counter() - t_wall0, 6),
                                   rx_frames=st['rx_frames'],
                                   tx_frames=st['tx_frames'],
                                   words_in=st['words_in'],
                                   words_out=st['words_out'],
                                   cycles_total=st['cycles_total'],
                                   blocks_done=st['blocks'], rtt_us=srtt))
                last_sample = time.perf_counter()
        t_wall1 = time.perf_counter()
        final, frtt = conn.status()

        wall = t_wall1 - t_wall0
        dgrams = conn.tx_datagrams + conn.rx_datagrams
        dpayload = conn.tx_bytes + conn.rx_bytes
        frame_bytes = sum(16 + 4 * len(c['words']) + 532 for c in planned)
        d_words = (final['words_out'] - first['words_out']) & 0xFFFFFFFF
        d_cyc = (final['cycles_total'] - first['cycles_total']) & 0xFFFFFFFF
        report.update(
            status='PASS' if failed == 0 and verified == len(planned) else 'FAIL',
            finished_at=rr.now_iso(), wall_s=round(wall, 6),
            blocks_verified=verified, blocks_failed=failed,
            status_samples=len(series),
            transport=dict(datagrams=dgrams, payload_bytes=dpayload,
                           datagrams_per_s=round(dgrams / wall, 1),
                           bytes_per_s=round(dpayload / wall, 1),
                           frame_bytes_per_s=round(frame_bytes / wall, 1),
                           blocks_per_s=round(len(planned) / wall, 2),
                           board_wait_s=round(board_wait, 3),
                           host_model_s=round(host_model, 3),
                           host_other_s=round(wall - board_wait - host_model, 3),
                           board_wait_fraction=round(board_wait / wall, 4)),
            design=dict(final_counters=final, final_status_rtt_us=frtt,
                        words_out_delta=d_words, cycles_delta=d_cyc,
                        bytes_per_s_from_counters=round(d_words * 4 / wall, 1),
                        mbit_s_contract_formula=round(d_words * 32 / d_cyc, 4)
                        if d_cyc else None,
                        mbit_s_at_reported_clock=round(d_words * 32 / d_cyc
                                                      * a.clock_mhz, 3)
                        if d_cyc else None,
                        per_block_cycles=[r['cycles'] for r in report['results']
                                          if r['cycles'] is not None]),
            uart_baseline_bytes_per_s=UART_BASELINE_BYTES_PER_S,
            speedup_vs_uart=round(dpayload / wall / UART_BASELINE_BYTES_PER_S, 2),
            samples=series,
            note=('transport.* is this host UDP path with per-block model '
                  'verification included in the wall time; design.* comes from '
                  'the DUT STAT counters and is not a transport measurement. '
                  'mbit_s_contract_formula is (words_out_delta*32)/cycles_delta '
                  'and is Mbit/s only if one cycle is 1 us; eth_rate_harness '
                  'counts 20 ns cycles, hence mbit_s_at_reported_clock. '
                  'speedup_vs_uart compares bytes_per_s with the measured '
                  '~11.5 kB/s FX2/UART capture path.'))
        if a.dry_run:
            report['status'] = 'DRY_RUN'
            report['note'] += (' DRY-RUN: every reply was model-synthesised on '
                               'this PC, so these rates describe the host, not '
                               'the dock.')
    except Exception as exc:
        report['status'] = 'FAIL'
        report['error'] = repr(exc)
        log('ERROR %r' % exc)
    finally:
        if conn is not None and not a.dry_run:
            conn.close()
        (out / 'throughput.json').write_text(json.dumps(report, indent=2,
                                                        ensure_ascii=False) + '\n', encoding='utf-8')
        log('')
        for group in ('transport', 'design'):
            for k, v in report.get(group, {}).items():
                if k == 'per_block_cycles':
                    continue
                log('%s.%s = %s' % (group, k, v))
        log('blocks verified %s/%s (failed %s) -> %s'
            % (report.get('blocks_verified'), report.get('blocks_modelable'),
               report.get('blocks_failed'), report['status']))
        log('wrote %s' % (out / 'throughput.json'))
        log.close()
    return 0 if report['status'] in ('PASS', 'DRY_RUN') else 1


if __name__ == '__main__':
    sys.exit(main())
