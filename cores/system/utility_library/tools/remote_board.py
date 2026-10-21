"""Guarded SRAM-only programming and source-bound UART acceptance over SSH.

Credentials come from P25_PASSWORD or the already existing local SSH helper.
No password is written to logs or a release package. Refuses non-GW5A-25 JTAG.
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
import sys
import time
import paramiko
from verify import ROOT, REPO

PATTERN = re.compile(r'P25 G=(\d) M=([0-9A-F]{2}) E=([0-9A-F]{8}) N=([0-9A-F]{8}) '
                     r'D=([0-9A-F]{8}) L=([0-9A-F]{8}) S=([0-9A-F]{8})')


def password():
    if os.environ.get('P25_PASSWORD'):
        return os.environ['P25_PASSWORD']
    helper = REPO/'tools/_remote/sshrun.py'
    if helper.is_file():
        # Parse the existing local credential, never execute the helper at import.
        for node in ast.parse(helper.read_text(encoding='utf-8')).body:
            if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'PASSWORD' for t in node.targets):
                return ast.literal_eval(node.value)
    raise RuntimeError('Set P25_PASSWORD for the authorized board account')


def execute(client, argv, timeout=40):
    _, stdout, stderr = client.exec_command(shlex.join([str(v) for v in argv]), timeout=timeout)
    # Commands used here have bounded small output; no large stream deadlock.
    text = stdout.read().decode('utf-8', 'replace')+stderr.read().decode('utf-8', 'replace')
    code = stdout.channel.recv_exit_status()
    return code, text


CAPTURE = '''import serial, sys, time
s=serial.Serial(sys.argv[1],115200,timeout=0.2)
end=time.monotonic()+float(sys.argv[2])
data=bytearray()
while time.monotonic()<end:
    data.extend(s.read(4096))
s.close()
sys.stdout.buffer.write(data)
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--build', required=True, type=Path)
    ap.add_argument('--host', default='192.168.31.176')
    ap.add_argument('--user', default='bianbu')
    ap.add_argument('--port', default='/dev/ttyUSB1')
    ap.add_argument('--groups', default='0,1,2,3,4,5,6')
    args = ap.parse_args()
    build = args.build.resolve()
    summary = json.loads((build/'summary.json').read_text())
    # Ensure the binary corresponds to the current delivered RTL/golden files.
    for relative, expected_hash in summary['sources'].items():
        if relative.startswith(('rtl/', 'vectors/', 'board/')):
            if hashlib.sha256((ROOT/relative).read_bytes()).hexdigest() != expected_hash:
                raise RuntimeError('build stale against source: '+relative)
    groups = [int(v) for v in args.groups.split(',')]
    builds = {row['group']: row for row in summary['groups']}
    expected = {row['group']: row for row in json.loads((ROOT/'board/expected.json').read_text())}
    for g in groups:
        row = builds[g]
        if row['route'] != 'PASS' or not row['under_budget'] or not row.get('bitstream'):
            raise RuntimeError('build not accepted: '+str(g))
        fs = ROOT/row['bitstream']
        if hashlib.sha256(fs.read_bytes()).hexdigest() != row['bitstream_sha256']:
            raise RuntimeError('bitstream hash mismatch')
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    out = ROOT/'evidence'/('board_'+stamp)
    out.mkdir(parents=True, exist_ok=False)
    client = paramiko.SSHClient()
    client.load_system_host_keys()
    # Isolated known-host store for this workspace, reused for later runs.
    known = ROOT/'.remote_known_hosts'
    if known.exists():
        client.load_host_keys(str(known))
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(args.host, username=args.user, password=password(), timeout=15,
                   allow_agent=False, look_for_keys=False)
    client.save_host_keys(str(known))
    results = []
    report = dict(timestamp=datetime.now(timezone.utc).isoformat(), host=args.host,
                  device='GW5A-25', build=str(build), groups=results,
                  physical_clock_mhz=50, enabled_beat_mhz=3.125, status='IN_PROGRESS')
    sftp = client.open_sftp()
    remote = '/home/'+args.user+'/production_ip_25k_'+stamp
    try:
        code, detect = execute(client, ['openFPGALoader', '-b', 'tangprimer25k', '--detect'])
        (out/'jtag_detect.txt').write_text(detect, encoding='utf-8')
        if code or 'GW5A-25' not in detect or '0x1281b' not in detect:
            raise RuntimeError('JTAG guard rejected unexpected device')
        sftp.mkdir(remote)
        with sftp.file(remote+'/capture.py', 'w') as stream:
            stream.write(CAPTURE)
        # Save current UART state before first SRAM change.
        code, before = execute(client, ['python3', remote+'/capture.py', args.port, '1'])
        (out/'before_uart.txt').write_text(before, encoding='utf-8')
        if code:
            raise RuntimeError('UART unavailable before programming')
        for group in groups:
            row = builds[group]
            fs = ROOT/row['bitstream']
            remote_fs = remote+f'/group_{group}.fs'
            sftp.put(str(fs), remote_fs)
            code, uploaded_hash = execute(client, ['sha256sum', remote_fs])
            if code or not uploaded_hash.startswith(row['bitstream_sha256']):
                raise RuntimeError('remote artifact hash mismatch')
            # Shared hardware lock covers JTAG and UART capture as one operation.
            # SRAM only: no -f / flash erase / persistent reconfiguration.
            shell = 'openFPGALoader -b tangprimer25k '+shlex.quote(remote_fs)
            shell += ' && python3 '+shlex.quote(remote+'/capture.py')+' '+shlex.quote(args.port)+' 3'
            code, output = execute(client, ['flock', '-n', '/tmp/production_ip_25k_board.lock', 'sh', '-c', shell], 45)
            (out/f'group_{group}_program_uart.txt').write_text(output, encoding='utf-8')
            if code:
                raise RuntimeError(f'program/capture failed or board lock held: group={group}')
            matches = [m for m in PATTERN.finditer(output) if int(m[1]) == group]
            if not matches:
                raise RuntimeError('no UART verdict for group '+str(group))
            want = expected[group]
            for match in matches:
                values = dict(mask=match[2], errors=int(match[3], 16), count=int(match[4], 16),
                              digest=match[5], max_latency=int(match[6], 16), stalled_beats=int(match[7], 16))
                if any(values[k] != want[k] for k in values):
                    raise RuntimeError(f'UART mismatch group={group}: {values}')
            results.append(dict(group=group, status='PASS', frames=len(matches), cores=want['cores'],
                                **values, bitstream_sha256=row['bitstream_sha256']))
            (out/'summary.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
            print(f'BOARD group={group} 8/8 PASS N={values["count"]} D={values["digest"]} frames={len(matches)}', flush=True)
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


if __name__ == '__main__':
    main()
