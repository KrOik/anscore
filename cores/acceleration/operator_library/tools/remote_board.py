"""Guarded SRAM-only programming and source-bound UART acceptance over SSH.

Credentials come from P25_PASSWORD or the existing local SSH helper; nothing is
written to logs. Refuses a non-GW5A-25 JTAG target, a stale bitstream, a route
that is not PASS, or a group over budget. Flash is never touched.
"""
import argparse
import ast
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import paramiko
from verify import ROOT, REPO
from groups import plan

PATTERN = re.compile(r'A25 G=([0-9A-Z]) M=([0-9A-Fa-f]{2}) E=([0-9A-Fa-f]{8}) N=([0-9A-Fa-f]{8}) '
                     r'D=([0-9A-Fa-f]{8}) L=([0-9A-Fa-f]{8}) S=([0-9A-Fa-f]{8})')


def group_of(label):
    """Inverse of generate_board.group_label: '0'-'9' then 'A'-'Z'."""
    return int(label) if label.isdigit() else ord(label.upper()) - ord('A') + 10


def password():
    if os.environ.get('P25_PASSWORD'):
        return os.environ['P25_PASSWORD']
    helper = REPO/'tools/_remote/sshrun.py'
    if helper.is_file():
        for node in ast.parse(helper.read_text(encoding='utf-8', errors='replace')).body:
            if isinstance(node, ast.Assign) and any(
                    isinstance(t, ast.Name) and t.id == 'PASSWORD' for t in node.targets):
                return ast.literal_eval(node.value)
    raise RuntimeError('Set P25_PASSWORD for the authorized board account')


def execute(client, argv, timeout=60):
    _, stdout, stderr = client.exec_command(shlex.join([str(v) for v in argv]), timeout=timeout)
    text = stdout.read().decode('utf-8', 'replace')+stderr.read().decode('utf-8', 'replace')
    return stdout.channel.recv_exit_status(), text


CAPTURE = '''import serial, sys, time
s=serial.Serial(sys.argv[1],115200,timeout=0.2)
end=time.monotonic()+float(sys.argv[2])
data=bytearray()
while time.monotonic()<end:
    data.extend(s.read(4096))
s.close()
sys.stdout.buffer.write(bytes(data))
'''

# The requested port is tried first, so the proven /dev/ttyUSB1 path is unchanged;
# only when it carries no bytes does another node get a turn. Enumerating nodes in
# order would be a guess, because which tty the debugger's second channel lands on
# depends on when the kernel bound it, not on the board.
PICK = '''import glob, serial, sys, time
req=sys.argv[1]
for p in [req]+[q for q in sorted(glob.glob("/dev/ttyUSB*")) if q!=req]:
    try: s=serial.Serial(p,115200,timeout=0.2)
    except Exception: continue
    end=time.monotonic()+2.0; n=0
    while time.monotonic()<end: n+=len(s.read(4096))
    s.close()
    if n: print(p+" bytes="+str(n)); break
else: print("none bytes=0")
'''


def resolve_port(client, requested):
    """Return the console node that actually carries verdict frames."""
    code, text = execute(client, ['python3', '-c', PICK, requested], timeout=40)
    line = text.strip().splitlines()[-1] if text.strip() else 'none bytes=0'
    port = line.split(' ')[0]
    if port.startswith('/dev/ttyUSB'):
        if port != requested:
            print(f'uart: {requested} silent, using {port} ({line})', flush=True)
        return port
    print(f'uart: no node emitted bytes, keeping {requested} ({line})', flush=True)
    return requested


def connect(args):
    """SSH session for the authorized dock; the password never leaves memory."""
    client = paramiko.SSHClient()
    client.load_system_host_keys()
    known = ROOT / '.remote_known_hosts'
    if known.exists():
        client.load_host_keys(str(known))
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(args.host, username=args.user, password=password(), timeout=15,
                   allow_agent=False, look_for_keys=False)
    client.save_host_keys(str(known))
    return client


def probe(args):
    """Reachability only: JTAG device identity and live UART, nothing programmed."""
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    out = ROOT / 'evidence' / ('probe_' + stamp)
    out.mkdir(parents=True, exist_ok=False)
    client = connect(args)
    args.port = resolve_port(client, args.port)
    sftp = client.open_sftp()
    remote = '/home/' + args.user + '/production_accel_25k_probe_' + stamp
    report = dict(timestamp=datetime.now(timezone.utc).isoformat(), host=args.host,
                  mode='probe', port=args.port, status='IN_PROGRESS')
    try:
        code, detect = execute(client, ['openFPGALoader', '-b', 'tangprimer25k', '--detect'])
        (out / 'jtag_detect.txt').write_text(detect, encoding='utf-8')
        if code or 'GW5A-25' not in detect or '0x1281b' not in detect:
            raise RuntimeError('JTAG probe saw an unexpected device')
        sftp.mkdir(remote)
        with sftp.file(remote + '/capture.py', 'w') as stream:
            stream.write(CAPTURE)
        code, before = execute(client, ['python3', remote + '/capture.py', args.port, '3'])
        (out / 'before_uart.txt').write_text(before, encoding='utf-8')
        if code:
            raise RuntimeError('UART unavailable')
        execute(client, ['rm', '-r', remote])
        report['status'] = 'PASS'
        report['verdict_frames'] = len(PATTERN.findall(before))
        report['device'] = 'GW5A-25 detected'
        print(f'PROBE PASS device=GW5A-25 uart={args.port} bytes={len(before)} '
              f'verdict_frames={report["verdict_frames"]}', flush=True)
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        sftp.close()
        client.close()
    print(f'Probe evidence={out}')
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--build', type=Path, nargs='+',
                    help='build evidence directory or directories; groups are taken from '
                         'whichever shard accepted them, so parallel synth shards can be '
                         'programmed in one board session')
    ap.add_argument('--probe', action='store_true',
                    help='check dock, device id and UART only; programs nothing')
    ap.add_argument('--host', default='192.168.31.176')
    ap.add_argument('--user', default='bianbu')
    ap.add_argument('--port', default='/dev/ttyUSB1')
    ap.add_argument('--groups', help='comma list, default every built group')
    args = ap.parse_args()
    if args.probe:
        return probe(args)
    if not args.build:
        ap.error('--build is required unless --probe')
    build_dirs = []
    builds = {}
    rejected = {}
    for path in args.build:
        build = path.resolve()
        summary = json.loads((build/'summary.json').read_text(encoding='utf-8'))
        for relative, expected_hash in summary['sources'].items():
            if relative.startswith(('rtl/', 'vectors/', 'board/', 'tables/')):
                if hashlib.sha256((ROOT/relative).read_bytes()).hexdigest() != expected_hash:
                    raise RuntimeError(f'build {build.name} stale against source: '+relative)
        for row in summary['groups']:
            if row.get('route') == 'PASS' and row.get('under_budget') \
                    and row.get('bitstream'):
                builds.setdefault(row['group'], row)
            else:
                # Kept only so a missing bitstream is reported by group number
                # instead of a KeyError; an accepted row from any directory wins.
                rejected.setdefault(row['group'], row)
        build_dirs.append(str(build))
    for group, row in rejected.items():
        builds.setdefault(group, row)
    groups = [int(v) for v in args.groups.split(',')] if args.groups \
        else [row['group'] for row in plan()]
    expected = {row['group']: row for row in json.loads((ROOT/'board/expected.json')
                                                        .read_text(encoding='utf-8'))}
    for g in groups:
        row = builds.get(g)
        if row is None or row['route'] != 'PASS' or not row['under_budget'] \
                or not row.get('bitstream'):
            raise RuntimeError('build not accepted for group '+str(g))
        fs = ROOT/row['bitstream']
        if hashlib.sha256(fs.read_bytes()).hexdigest() != row['bitstream_sha256']:
            raise RuntimeError('bitstream hash mismatch for group '+str(g))
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    out = ROOT/'evidence'/('board_'+stamp)
    out.mkdir(parents=True, exist_ok=False)
    client = connect(args)
    args.port = resolve_port(client, args.port)
    results = []
    report = dict(timestamp=datetime.now(timezone.utc).isoformat(), host=args.host,
                  device='GW5A-25', builds=build_dirs, groups=results,
                  physical_clock_mhz=50, enabled_beat_mhz=3.125, status='IN_PROGRESS')
    (out/'summary.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    sftp = client.open_sftp()
    remote = '/home/'+args.user+'/production_accel_25k_'+stamp
    try:
        code, detect = execute(client, ['openFPGALoader', '-b', 'tangprimer25k', '--detect'])
        (out/'jtag_detect.txt').write_text(detect, encoding='utf-8')
        if code or 'GW5A-25' not in detect or '0x1281b' not in detect:
            raise RuntimeError('JTAG guard rejected unexpected device')
        sftp.mkdir(remote)
        with sftp.file(remote+'/capture.py', 'w') as stream:
            stream.write(CAPTURE)
        code, before = execute(client, ['python3', remote+'/capture.py', args.port, '1'])
        (out/'before_uart.txt').write_text(before, encoding='utf-8')
        if code:
            raise RuntimeError('UART unavailable before programming')
        for group in groups:
            row = builds[group]
            fs = ROOT/row['bitstream']
            remote_fs = remote+f'/group_{group}.fs'
            sftp.put(str(fs), remote_fs)
            code, uploaded = execute(client, ['sha256sum', remote_fs])
            if code or not uploaded.startswith(row['bitstream_sha256']):
                raise RuntimeError('remote artifact hash mismatch group '+str(group))
            shell = 'openFPGALoader -b tangprimer25k '+shlex.quote(remote_fs)
            shell += ' && python3 '+shlex.quote(remote+'/capture.py')+' '+shlex.quote(args.port)+' 4'
            code, output = execute(client, ['flock', '-n', '/tmp/production_ip_25k_board.lock',
                                            'sh', '-c', shell], 90)
            (out/f'group_{group}_program_uart.txt').write_text(output, encoding='utf-8')
            if code:
                raise RuntimeError(f'program/capture failed or board lock held: group={group}')
            matches = [m for m in PATTERN.finditer(output) if group_of(m[1]) == group]
            if not matches:
                raise RuntimeError('no UART verdict for group '+str(group))
            want = expected[group]
            for match in matches:
                values = dict(mask=match[2].upper(), errors=int(match[3], 16),
                              count=int(match[4], 16), digest=match[5].upper(),
                              max_latency=int(match[6], 16), stalled_beats=int(match[7], 16))
                if any(values[key] != want[key] for key in values):
                    raise RuntimeError(f'UART mismatch group={group}: {values} != {want}')
            results.append(dict(group=group, status='PASS', frames=len(matches),
                                cores=want['cores'], units=want['units'],
                                **{key: want[key] for key in
                                   ('mask', 'errors', 'count', 'digest', 'max_latency',
                                    'stalled_beats')},
                                bitstream_sha256=row['bitstream_sha256']))
            (out/'summary.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
            print(f'BOARD group={group} {want["units"]}/{want["units"]} PASS '
                  f'N={want["count"]:08X} D={want["digest"]} frames={len(matches)}', flush=True)
        report['status'] = 'PASS'
    except Exception as exc:
        report['status'] = 'FAIL'
        report['reason'] = str(exc)
        raise
    finally:
        (out/'summary.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
        sftp.close()
        client.close()
    print(f'Board evidence={out}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
