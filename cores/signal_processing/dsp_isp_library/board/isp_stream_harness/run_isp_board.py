"""ISP board session from this PC: SRAM-program over SSH, drive IMG1/IMR1 on the rig host.

The ISP stream harness speaks the 276-byte IMG1/IMR1 block contract over the
dock UART only (no Ethernet frontend), so this runner is the ISP counterpart of
run_eth_board.py.  Everything hardware-touching happens inside the repository
board lock; the bitstream is SRAM-programmed by the remote board host with
openFPGALoader and every case is checked on the rig against the frozen,
independent model that shipped with the build directory.

Order of work per session:

  1. stage image.fs + the build's frozen protocol.py / models / variant.json /
     isp_uart_round.py into /tmp/isp_round and verify sha256 of each upload
  2. program SRAM (round 1)
  3. transport probe: 2 cases on each candidate ttyUSB port.  Historical ISP
     evidence captured the reply with an FX2 logic analyser on the mirrored TX
     pin, never from the dock UART itself, so whether ttyUSB's RX line really
     sees the FPGA's uart_tx (M11, mirrored on A11) is unproven.  The probe
     settles that with bytes actually read back, before a full sweep is spent.
  4. full 16-case sweep on the answering port, then reprogram and repeat
     (round 2 is the mandatory reproducibility round).

Link bandwidth (bytes/s over 115200-baud UART) and core throughput
(cycles/frame from the harness' own counter) are reported separately; neither
is presented as the other.

Usage:
    python run_isp_board.py --build <dir with image.fs> --output <artifacts> \
        [--ports /dev/ttyUSB1,/dev/ttyUSB0] [--baud 115200] [--rounds 2] \
        [--probe-only] [--boot-settle 3.0] [--case-timeout 6.0]
"""
import argparse, hashlib, json, sys, time
from datetime import datetime, timezone
from pathlib import Path

import paramiko

HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1]
ROOT = LIB.parents[1]
sys.path.insert(0, str(LIB / 'board'))
from board_lock import BoardLock

HOST, USER, PASSWORD = '192.168.31.176', 'bianbu', 'bianbu'
RDIR = '/tmp/isp_round'
DRIVER = HERE / 'isp_uart_round.py'
REPLY_BYTES = 276


def now_iso():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


class Log:
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


def connect():
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASSWORD, timeout=15,
                allow_agent=False, look_for_keys=False)
    return cli


def run(cli, cmd, timeout=600):
    stdin, out, err = cli.exec_command(cmd, timeout=timeout)
    o = out.read().decode('utf-8', 'replace')
    e = err.read().decode('utf-8', 'replace')
    return stdin.channel.recv_exit_status(), o, e


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stage(cli, build, log):
    """Upload image.fs plus the self-contained remote driver payload."""
    image = build / 'image.fs'
    files = [image, DRIVER]
    for name in ('protocol.py', 'variant.json'):
        src = build / name
        if src.exists():
            files.append(src)
    files += sorted(build.glob('*.py'))
    seen, payload = set(), []
    for f in files:
        if f.name in seen or f.name == 'run.py':
            continue
        seen.add(f.name)
        payload.append(f)
    run(cli, 'rm -rf %s && mkdir -p %s' % (RDIR, RDIR))
    sftp = cli.open_sftp()
    try:
        for f in payload:
            sftp.put(str(f), '%s/%s' % (RDIR, f.name))
    finally:
        sftp.close()
    records = []
    for f in payload:
        rc, o, e = run(cli, 'sha256sum %s/%s' % (RDIR, f.name))
        remote = (o + e).split()[0] if rc == 0 else ''
        local = sha256(f)
        records.append(dict(name=f.name, bytes=f.stat().st_size,
                            sha256=local, remote_sha256=remote,
                            verified=remote == local))
        log('  staged %-24s %8d B %s' % (f.name, f.stat().st_size,
                                         'ok' if remote == local else 'MISMATCH'))
    if not all(r['verified'] for r in records):
        raise RuntimeError('staging integrity check failed')
    return records


def program(cli, log_path, log, round_index, image):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log('programming image.fs round %d on %s (%d bytes)'
        % (round_index, USER, image.stat().st_size))
    rc, out_text, err_text = run(cli, 'cd %s && openFPGALoader -b tangprimer20k '
                                      'image.fs 2>&1' % RDIR, timeout=900)
    text = out_text + err_text
    log_path.write_text('$ openFPGALoader -b tangprimer20k image.fs\n' + text,
                        encoding='utf-8')
    log('  openFPGALoader rc=%d, log %s' % (rc, log_path.name))
    return rc, text


def remote_round(cli, out_dir, log, args, port, seed, variant, rname, limit=0):
    """Run isp_uart_round.py on the rig, then pull its artifacts back.

    The build directory's variant.json fixes core/bits/padding so the sweep
    exercises exactly the configuration that was simulated and routed.  Each
    run gets its own remote output directory; rounds never share frames.
    """
    remote = '%s/%s' % (RDIR, rname)
    cmd = ('cd %s && rm -rf %s && python3 isp_uart_round.py --output %s '
           '--uart %s --baud %d --timeout %.1f --seed %d --bits %d --padding %d'
           % (RDIR, remote, remote, port, args.baud, args.case_timeout, seed,
              int(variant.get('bits', 8)), int(variant.get('padding', 1))))
    if limit:
        cmd += ' --limit %d' % limit
    log('  remote driver: %s' % cmd)
    rc, o, e = run(cli, cmd, timeout=args.round_budget)
    text = o + e
    log('  rc=%d, %d log lines' % (rc, len(text.splitlines())))
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / 'remote_stdout.log').write_text(text, encoding='utf-8')
    sftp = cli.open_sftp()
    verdict, frames = {}, []
    try:
        local_v = out_dir / 'verdict.json'
        sftp.get('%s/verdict.json' % remote, str(local_v))
        verdict = json.loads(local_v.read_text(encoding='utf-8'))
        rc2, listing, _ = run(cli, 'ls %s/frames' % remote)
        for name in listing.split():
            local_f = out_dir / 'frames' / name
            local_f.parent.mkdir(parents=True, exist_ok=True)
            sftp.get('%s/frames/%s' % (remote, name), str(local_f))
            frames.append(dict(name=name, bytes=local_f.stat().st_size))
    except Exception as exc:
        verdict = verdict or {'status': 'NO_VERDICT', 'error': repr(exc)}
    finally:
        sftp.close()
    if frames:
        log('  pulled %d frame files' % len(frames))
    return rc, verdict, frames


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--build', required=True, type=Path,
                   help='directory containing image.fs + frozen protocol.py')
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--ports', default='/dev/ttyUSB1,/dev/ttyUSB0')
    p.add_argument('--baud', type=int, default=115200)
    p.add_argument('--rounds', type=int, default=2)
    p.add_argument('--probe-only', action='store_true')
    p.add_argument('--boot-settle', type=float, default=3.0)
    p.add_argument('--case-timeout', type=float, default=6.0)
    p.add_argument('--round-budget', type=int, default=900)
    p.add_argument('--lock-timeout', type=int, default=120)
    a = p.parse_args(argv)

    build = a.build.resolve()
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    log = Log(out / 'board.log')
    variant = {}
    vpath = build / 'variant.json'
    if vpath.exists():
        variant = json.loads(vpath.read_text(encoding='utf-8'))
    image = build / 'image.fs'
    if not image.exists():
        log('FATAL no image.fs in %s' % build)
        return 2
    ports = [s.strip() for s in a.ports.split(',') if s.strip()]

    session = dict(status='FAIL', started_at=now_iso(), board='tangprimer20k',
                   transport='uart-%d' % a.baud, build=str(build),
                   image_sha256=sha256(image), variant=variant,
                   remote='%s@%s:%s' % (USER, HOST, RDIR),
                   rounds=[], probe=None, candidate_ports=ports)
    summary_path = out / 'session.json'

    with BoardLock(purpose='ISP %s IMG1/IMR1 board round'
                   % variant.get('core_name', '?'), output=out,
                   timeout=a.lock_timeout):
        log('board lock acquired (%s)' % out)
        cli = connect()
        log('ssh %s@%s ok' % (USER, HOST))
        try:
            rc, o, e = run(cli, 'ls -l /dev/ttyUSB* 2>&1; command -v '
                                'openFPGALoader; python3 -c '
                                '"import serial;print(serial.__version__)"')
            (out / 'rig_prerequisites.log').write_text(o + e, encoding='utf-8')
            log('  rig: %s' % ' | '.join(l for l in (o + e).splitlines() if l))
            session['staged'] = stage(cli, build, log)

            # -------- probe: which UART port actually receives the TX pin ----
            rc, text = program(cli, out / 'program_probe.log', log, 0, image)
            if rc:
                raise RuntimeError('probe programming failed')
            time.sleep(a.boot_settle)
            probe_dir = out / 'probe'
            probes = []
            for port in ports:
                log('=== probe %s ===' % port)
                rname = 'probe_' + port.replace('/dev/tty', 'tty')
                prc, pverdict, pframes = remote_round(
                    cli, probe_dir / rname, log, a, port, seed=9001,
                    variant=variant, rname=rname, limit=2)
                cases = pverdict.get('cases', [])
                # a full-length IMR1 reply proves the RX line, even if the
                # payload itself then fails verification
                transport = any('reply length' not in str(c.get('error') or '')
                                for c in cases)
                probes.append(dict(port=port, rc=prc, transport=transport,
                                   status=pverdict.get('status'),
                                   planned=pverdict.get('planned'),
                                   verified=pverdict.get('verified'),
                                   frame_files=pframes,
                                   detail=[dict(tag=c.get('tag'), ok=c.get('ok'),
                                                error=c.get('error'),
                                                rtt_us=c.get('rtt_us'),
                                                attempts=c.get('attempts'),
                                                cycles=c.get('cycles'))
                                           for c in cases]))
                log('  probe %s -> transport=%s verdict=%s'
                    % (port, transport, pverdict.get('status')))
            answering = [q['port'] for q in probes if q['transport']]
            session['probe'] = dict(cases_per_port=2, ports=probes,
                                    answering=answering,
                                    note='historic ISP evidence captured the '
                                         'reply on FX2 D0, never on ttyUSB; this '
                                         'probe measures ttyUSB RX directly')
            (out / 'probe.json').write_text(json.dumps(session['probe'], indent=2)
                                            + '\n', encoding='utf-8')
            if not answering:
                session['status'] = 'FAIL'
                session['failure'] = ('no candidate UART port returned a valid '
                                      'IMR1 reply; ISP board verification needs '
                                      'a different capture path')
                log('PROBE FAIL: %s' % ', '.join('%s:%s' % (q['port'], q['status'])
                                                 for q in probes))
            else:
                session['transport_port'] = answering[0]
                log('PORT OK: %s' % answering[0])
                if not a.probe_only:
                    for r in range(1, a.rounds + 1):
                        log('=== round %d/%d ===' % (r, a.rounds))
                        rdir = out / ('round_%02d' % r)
                        prc, text = program(cli, rdir / 'program.log', log, r,
                                            image)
                        if prc:
                            session['rounds'].append(dict(round=r,
                                                          programmed=False))
                            raise RuntimeError('programming failed in round %d' % r)
                        time.sleep(a.boot_settle)
                        rr, verdict, frames = remote_round(
                            cli, rdir, log, a, answering[0], seed=1000 + r,
                            variant=variant, rname='round_%02d' % r)
                        verdict = dict(verdict)
                        verdict['round'] = r
                        verdict['frame_files'] = frames
                        session['rounds'].append(verdict)
                        log('  round %d verdict %s (%s/%s verified, %.0f B/s link)'
                            % (r, verdict.get('status'), verdict.get('verified'),
                               verdict.get('planned'),
                               float(verdict.get('bytes_per_s') or 0)))
                if a.probe_only:
                    session['status'] = 'TRANSPORT_PROBE'
                else:
                    good = [q for q in session['rounds'] if q.get('status') == 'PASS']
                    session['status'] = 'PASS' if len(good) == a.rounds else 'FAIL'
        except Exception as exc:
            session['status'] = 'FAIL'
            session['failure'] = repr(exc)
            log('EXCEPTION %r' % (exc,))
        finally:
            rc, o, e = run(cli, 'ls -l %s 2>&1' % RDIR)
            (out / 'remote_dir.log').write_text('$ ls -l %s\n%s%s' % (RDIR, o, e),
                                                encoding='utf-8')
            cli.close()

    passed = [q for q in session['rounds'] if q.get('status') == 'PASS']
    if passed:
        link = sum(float(q.get('bytes_per_s') or 0) for q in passed) / len(passed)
        cyc = [int(c['cycles']) for q in passed for c in q.get('cases', [])
               if c.get('cycles')]
        session['performance'] = dict(
            link_bytes_per_s_avg=round(link, 1),
            link_note='115200-baud UART transport, not a core rate',
            core_cycles_per_frame=cyc,
            core_note='harness cycle counter per 64-pixel frame; '
                      '27 MHz clk so cycles/64 = cycles per pixel',
            verified_cases=sum(int(q.get('verified') or 0) for q in passed))
    session['finished_at'] = now_iso()
    summary_path.write_text(json.dumps(session, indent=2, ensure_ascii=False) + '\n',
                            encoding='utf-8')
    (out / '.boardlock_released.json').write_text(json.dumps(dict(
        session=session['status'], board='tangprimer20k',
        transport='uart-%d' % a.baud, released_at=now_iso(),
        purpose='ISP IMG1/IMR1 board round', output=str(out)), indent=2) + '\n',
        encoding='utf-8')
    log('session %s -> %s' % (session['status'], summary_path))
    log.close()
    return 0 if session['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
