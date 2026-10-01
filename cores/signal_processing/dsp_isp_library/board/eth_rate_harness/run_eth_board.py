"""One-shot Ethernet board session from this PC: program over SSH, measure over UDP.

Replaces the FX2/UART evidence path for throughput work.  The dock is jtag-
programmed by the remote Linux board host (192.168.31.176, openFPGALoader,
SRAM only) while all measurement traffic runs locally against the dock's
on-board RMII PHY at 192.168.137.16:11452.  Everything hardware-touching runs
inside the repository board lock, exactly like remote/run_drate_batch.py, so
parallel agents cannot interleave on the single dock.

Per round:
  1. upload <build>/eth.fs -> /tmp/eth_round/eth.fs on the board host
  2. openFPGALoader -b tangprimer20k eth.fs, log saved as program_round_NN.log
  3. wait for PHY link + design boot, then retry the STA1 status poll (<=10 s)
  4. run run_eth_round.py into round_NN/ (its own verdict.json + frames)
Round 2 is the mandatory reprogram/retest round: a result that only appears
once is not evidence.  Nothing is downloaded from the board host except the
program log; all measurement evidence is produced on this PC.

The dock UART (/dev/ttyUSB1) is recorded for provenance but is not used by the
UDP path; the block contract is carried entirely by Ethernet.  Both rounds
always run, so a failure can be judged reproducible.  On completion the lock
summary is written to <output>/.boardlock_released.json, mirroring the
repository-root archive run_drate_batch.py leaves behind.

Usage:
    python run_eth_board.py --build <dir with eth.fs> --output <artifacts dir> \
        --core resampler [--rounds 2] [--uart /dev/ttyUSB1] \
        [--bind-ip 192.168.137.1] [--target-ip 192.168.137.16] [--port 11452] \
        [--seed 1] [--driver-rounds 1] [--boot-settle 3.0] [--status-budget 10.0] \
        [--dry-run]
"""
import argparse, hashlib, json, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path

import paramiko

HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1]                                 # cores/signal_processing/dsp_isp_library
ROOT = LIB.parents[1]
sys.path.insert(0, str(LIB / 'board'))
from board_lock import BoardLock
sys.path.insert(0, str(HERE))
import eth_protocol as ep

HOST, USER, PASSWORD = '192.168.31.176', 'bianbu', 'bianbu'
RDIR = '/tmp/eth_round'
DRIVER = HERE / 'run_eth_round.py'


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


# --------------------------------------------------------------------- ssh -
def connect():
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASSWORD, timeout=15,
                allow_agent=False, look_for_keys=False)
    return cli


def run(cli, cmd, timeout=300):
    """paramiko 4.0: exec_command gives (stdin, stdout, stderr); the exit
    status comes from stdin.channel.recv_exit_status()."""
    stdin, out, err = cli.exec_command(cmd, timeout=timeout)
    o = out.read().decode('utf-8', 'replace')
    e = err.read().decode('utf-8', 'replace')
    return stdin.channel.recv_exit_status(), o, e


def program_round(cli, fs_local, log_path, log):
    """Upload the bitstream and SRAM-program the dock; returns (rc, text)."""
    run(cli, 'rm -rf %s && mkdir -p %s' % (RDIR, RDIR))
    sftp = cli.open_sftp()
    try:
        sftp.put(str(fs_local), '%s/eth.fs' % RDIR)
    finally:
        sftp.close()
    log('programming %s (%s, %d bytes)'
        % (fs_local.name, USER, fs_local.stat().st_size))
    rc, o, e = run(cli, 'cd %s && openFPGALoader -b tangprimer20k eth.fs 2>&1'
                   % RDIR, timeout=600)
    text = o + e
    log_path.write_text('$ openFPGALoader -b tangprimer20k eth.fs\n' + text, encoding='utf-8')
    log('  openFPGALoader rc=%d, log %s' % (rc, log_path.name))
    return rc, text


# ------------------------------------------------------------ endpoint wait -
def await_endpoint(args, log, dry_run, budget):
    """Poll STA1 until the design answers; returns (status, tries, error)."""
    deadline = time.time() + budget
    tries = 0
    last = None
    while time.time() < deadline:
        tries += 1
        try:
            if dry_run:
                data = ep.synth_status_response(ep.core_id(args.core))
                return ep.parse_status_response(data), tries, None
            with ep.EthClient(bind_ip=args.bind_ip, target_ip=args.target_ip,
                              port=args.port, timeout=1.5,
                              broadcast=args.broadcast) as cli:
                st, rtt = cli.status()
            log('  endpoint ready after %d tries (rtt %d us): %s'
                % (tries, rtt, json.dumps(st)))
            return st, tries, None
        except Exception as exc:
            last = repr(exc)
            log('  endpoint not ready (try %d): %s' % (tries, last))
            time.sleep(0.5)
    return None, tries, 'endpoint never answered STA1: %s' % last


# -------------------------------------------------------------------- round -
def run_driver(args, out_dir, log, seed):
    cmd = [sys.executable, str(DRIVER), '--core', args.core,
           '--output', str(out_dir), '--bind-ip', args.bind_ip,
           '--target-ip', args.target_ip, '--port', str(args.port),
           '--rounds', str(args.driver_rounds), '--seed', str(seed),
           '--timeout', str(args.timeout), '--clock-mhz', str(args.clock_mhz),
           '--attempts', str(args.attempts)]
    if args.no_ping:
        cmd.append('--no-ping')
    if args.broadcast:
        cmd.append('--broadcast')
    if args.dry_run:
        cmd.append('--dry-run')
    log('  driver: %s' % ' '.join(cmd))
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out_dir / 'driver_stdout.log').write_bytes(r.stdout)
    tail = r.stdout.decode('utf-8', 'replace').strip().splitlines()[-3:]
    for line in tail:
        log('    | %s' % line)
    verdict = {}
    vpath = out_dir / 'verdict.json'
    if vpath.exists():
        try:
            verdict = json.loads(vpath.read_text(encoding='utf-8'))
        except Exception as exc:
            verdict = {'status': 'NO_VERDICT', 'error': repr(exc)}
    else:
        verdict = {'status': 'NO_VERDICT', 'error': 'driver wrote no verdict.json'}
    return r.returncode, verdict


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--build', required=True, type=Path,
                   help='directory containing eth.fs')
    p.add_argument('--fs', default='eth.fs', help='bitstream filename in --build')
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--core', required=True, choices=sorted(ep.CORE_IDS))
    p.add_argument('--rounds', type=int, default=2,
                   help='program/retest rounds; round 2 is mandatory evidence')
    p.add_argument('--uart', default='/dev/ttyUSB1',
                   help='board host UART, recorded only (UDP path is used)')
    p.add_argument('--bind-ip', default='192.168.137.1')
    p.add_argument('--target-ip', default=ep.ENDPOINT_IP)
    p.add_argument('--port', type=int, default=ep.UDP_PORT)
    p.add_argument('--seed', type=int, default=1)
    p.add_argument('--driver-rounds', type=int, default=1,
                   help='sweeps per board round inside run_eth_round.py')
    p.add_argument('--timeout', type=float, default=2.0)
    p.add_argument('--attempts', type=int, default=3)
    p.add_argument('--clock-mhz', type=float, default=50.0)
    p.add_argument('--boot-settle', type=float, default=3.0,
                   help='seconds after programming before the first STA1')
    p.add_argument('--status-budget', type=float, default=10.0,
                   help='seconds to keep retrying the STA1 status poll')
    p.add_argument('--no-ping', action='store_true')
    p.add_argument('--broadcast', action='store_true',
                   help='requests go to 255.255.255.255; the dock currently '
                        'drops unicast IPv4 datagrams addressed to itself')
    p.add_argument('--dry-run', action='store_true',
                   help='no SSH, no UDP sockets: validate the orchestration')
    a = p.parse_args(argv)

    build = a.build.resolve()
    fs = build / a.fs
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    log = Log(out / 'board.log')
    if a.rounds < 2 and not a.dry_run:
        log('NOTE: --rounds %d < 2; the mandatory reprogram/retest round is '
            'missing, so this cannot be reported as PASS' % a.rounds)

    session = dict(status='FAIL', dry_run=a.dry_run, started_at=now_iso(),
                   build=str(build), bitstream=None, sha256=None, core=a.core,
                   core_id=ep.core_id(a.core), uart_recorded_only=a.uart,
                   endpoint='%s:%d' % (a.target_ip, a.port),
                   bind_ip=a.bind_ip, board_host='%s@%s' % (USER, HOST),
                   rounds_planned=a.rounds, rounds=[],
                   transport='rmii-udp, limited-broadcast requests'
                             if a.broadcast else 'rmii-udp')
    if fs.exists():
        session['bitstream'] = str(fs)
        session['sha256'] = hashlib.sha256(fs.read_bytes()).hexdigest()
    elif not a.dry_run:
        session['error'] = 'bitstream not found: %s' % fs
        log(session['error'])
        log.close()
        (out / 'verdict.json').write_text(json.dumps(session, indent=2) + '\n', encoding='utf-8')
        return 1
    else:
        session['bitstream'] = '%s (missing, tolerated in --dry-run)' % fs

    cli = None
    results = []
    try:
        if not a.dry_run:
            cli = connect()
            log('ssh %s@%s ok' % (USER, HOST))
        with BoardLock(purpose='eth_rate_harness %s %s'
                       % (a.core, 'dry-run' if a.dry_run else 'board'),
                       output=out):
            log('board lock acquired (%s)' % (ROOT / '.boardlock'))
            for n in range(1, a.rounds + 1):
                rdir = out / ('round_%02d' % n)
                rdir.mkdir(exist_ok=True)
                log('=== round %d/%d ===' % (n, a.rounds))
                row = dict(round=n, output=str(rdir), program_rc=None,
                           endpoint_ready=False, status='FAIL')
                results.append(row)
                if not a.dry_run:
                    rc, _text = program_round(cli, fs,
                                              out / ('program_round_%02d.log' % n),
                                              log)
                    row['program_rc'] = rc
                    if rc != 0:
                        row['error'] = 'openFPGALoader failed (rc=%d)' % rc
                        log('  %s; aborting the session' % row['error'])
                        break
                    log('  waiting %.1f s for link + boot' % a.boot_settle)
                    time.sleep(a.boot_settle)
                else:
                    (out / ('program_round_%02d.log' % n)).write_text(
                        '$ openFPGALoader -b tangprimer20k eth.fs\n'
                        'DRY-RUN: no SSH session, no programming performed\n', encoding='utf-8')
                st, tries, err = await_endpoint(a, log, a.dry_run,
                                                a.status_budget)
                row['endpoint_ready'] = st is not None
                row['status_poll_tries'] = tries
                if st is None:
                    row['error'] = err
                    log('  %s' % err)
                else:
                    row['endpoint_status'] = st
                # each board round gets its own sweep seed, still reproducible
                # from the session seed recorded in the round verdict
                drc, verdict = run_driver(a, rdir, log, a.seed + n)
                row['driver_rc'] = drc
                row['status'] = verdict.get('status')
                row['summary'] = verdict.get('summary')
                row['throughput'] = verdict.get('throughput')
                row['error'] = row.get('error') or verdict.get('error') \
                    or verdict.get('failure_reason')
                log('  round %d verdict %s' % (n, row['status']))
    except Exception as exc:
        session['error'] = repr(exc)
        log('ERROR %r' % exc)
    finally:
        if cli is not None:
            cli.close()

    real = [r for r in results if not a.dry_run]
    passed = [r for r in results if r['status'] == 'PASS']
    if a.dry_run:
        session['status'] = 'DRY_RUN' if results and all(
            r['status'] == 'DRY_RUN' for r in results) else 'FAIL'
        session['note'] = ('orchestration validated only; all replies were '
                           'model-synthesised locally. Not board evidence.')
    elif len(passed) == a.rounds and a.rounds >= 2 and len(real) == a.rounds:
        session['status'] = 'PASS'
    elif len(passed) == a.rounds and a.rounds == 1:
        session['status'] = 'PARTIAL'
        session['note'] = 'single round only: reprogram/retest round required'
    else:
        session['status'] = 'FAIL'
    session['rounds'] = results
    session['finished_at'] = now_iso()

    (out / 'verdict.json').write_text(json.dumps(session, indent=2,
                                                 ensure_ascii=False) + '\n', encoding='utf-8')
    released = dict(session='eth_rate_harness_%s' % a.core, owner='local-pc',
                    board='Tang_Primer_20K_Dock', transport='rmii-udp',
                    released_at=now_iso(),
                    purpose='program + UDP measure %s (%d rounds%s)'
                            % (a.core, a.rounds, ', dry-run' if a.dry_run else ''),
                    results=[dict(round=r['round'], status=r['status'],
                                  program_rc=r.get('program_rc'),
                                  endpoint_ready=r.get('endpoint_ready'),
                                  output=r['output']) for r in results])
    (out / '.boardlock_released.json').write_text(
        json.dumps(released, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

    log('')
    log('round  program  ready  verdict   planned  verified  failed  dgrams/s  '
        'bytes/s')
    for r in results:
        th = r.get('throughput') or {}
        s = r.get('summary') or {}
        log('%-6s  %-8s  %-5s  %-9s  %-8s  %-8s  %-7s  %-9s  %-9s'
            % (r['round'], r.get('program_rc'), 'yes' if r['endpoint_ready']
               else 'NO', r['status'], s.get('planned'), s.get('verified'),
               s.get('failed'), th.get('transport_datagrams_per_s'),
               th.get('transport_bytes_per_s')))
    log('session %s -> %s%s' % (session['status'], out / 'verdict.json',
                                '   (DRY-RUN: not board evidence)'
                                if a.dry_run else ''))
    log.close()
    return 0 if session['status'] in ('PASS', 'DRY_RUN') else 1


if __name__ == '__main__':
    sys.exit(main())
