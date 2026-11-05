#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded B32 source checks; no synthesis, hardware, network, or automatic retry."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
PROFILES = {'min': (1,16,8), '32to8': (9,32,8), '64to8': (16,64,8), '64to32': (64,64,32)}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(argv, env):
    """Return even when cleanup fails; retain primary timeout and captured bytes."""
    flags = {'creationflags': subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == 'nt' else {'start_new_session': True}
    try:
        proc = subprocess.Popen(list(map(str, argv)), cwd=ROOT, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, **flags)
    except OSError as exc:
        return {'status': 'NOT_RUN', 'reason': str(exc)}, b'', b''
    try:
        stdout, stderr = proc.communicate(timeout=20)
        return {'status': 'PASS' if proc.returncode == 0 else 'FAIL', 'exit_code': proc.returncode}, stdout, stderr
    except subprocess.TimeoutExpired as initial:
        result = {'status': 'TIMEOUT', 'exit_code': proc.returncode, 'cleanup_errors': []}
        stdout, stderr = initial.stdout or b'', initial.stderr or b''
        try:
            if os.name == 'nt':
                killed = subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
                if killed.returncode:
                    result['cleanup_errors'].append('taskkill exit code ' + str(killed.returncode))
            else:
                os.killpg(proc.pid, signal.SIGKILL)
        except (OSError, subprocess.TimeoutExpired) as exc:
            result['cleanup_errors'].append('tree kill: ' + str(exc))
        if proc.poll() is None:
            try:
                proc.kill()
            except OSError as exc:
                result['cleanup_errors'].append('direct kill: ' + str(exc))
        try:
            stdout, stderr = proc.communicate(timeout=5)
            result['cleanup_complete'] = proc.returncode is not None
        except (OSError, subprocess.TimeoutExpired) as exc:
            result['cleanup_complete'] = False
            result['cleanup_errors'].append('final communicate: ' + str(exc))
            if isinstance(exc, subprocess.TimeoutExpired):
                stdout = exc.stdout if exc.stdout is not None else stdout
                stderr = exc.stderr if exc.stderr is not None else stderr
            if proc.poll() is None:
                try:
                    proc.kill()
                except OSError as kill_exc:
                    result['cleanup_errors'].append('fallback direct kill: ' + str(kill_exc))
            # A pipe close can block on communicate's surviving reader thread;
            # publish the receipt without an unbounded join or close.
        result['exit_code'] = proc.returncode
        return result, stdout, stderr


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', choices=PROFILES, help='One fixed simulation profile, without repeating standalone checks')
    parser.add_argument('--tool-bin', type=Path)
    options = parser.parse_args()
    bindir = options.tool_bin or ROOT.parents[2] / 'tools/oss-cad-suite/oss-cad-suite/bin'
    suffix = '.exe' if os.name == 'nt' else ''
    iv, vv = bindir / ('iverilog'+suffix), bindir / ('vvp'+suffix)
    env = dict(os.environ)
    env['PATH'] = os.pathsep.join([str(bindir), str(bindir.parent/'lib'), env.get('PATH','')])
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    output = ROOT / 'reports' / stamp
    build = ROOT / '.build' / stamp
    output.mkdir(parents=True)
    build.mkdir(parents=True)
    inputs = sorted([p for p in ROOT.rglob('*') if p.is_file() and
                     (p.relative_to(ROOT).parts[0] in ('rtl','sim','example') or
                      p.name in ('run_tests.py','files.f') and p.parent==ROOT)])
    hashes = {p.relative_to(ROOT).as_posix(): sha(p) for p in inputs}
    for path in inputs:
        target = output / 'sources' / path.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    receipt = {'schema': 'anscore-b32-finite-v1', 'utc': stamp, 'cwd': str(ROOT),
               'source_sha256': hashes, 'source_copies': 'sources',
               'tool_sha256': {str(p): sha(p) for p in (iv,vv) if p.is_file()},
               'hard_seconds_per_child': 20, 'tree_cleanup_seconds_per_step': 5,
               'automatic_retry': False, 'records': [],
               'hardware': 'HW_UNVERIFIED', 'synthesis': 'NOT_RUN', 'pnr': 'NOT_RUN',
               'sta': 'NOT_RUN', 'board': 'NOT_RUN'}
    plan = []
    if options.profile is None:
        plan += [('lint_default',[iv,'-g2012','-Wall','-tnull','-s','axil_width_downsizer','-c','files.f']),
                 ('lint_example',[iv,'-g2012','-Wall','-tnull','-s','axil_narrow_peripheral','-c','example/files.f'])]
    profiles = {options.profile: PROFILES[options.profile]} if options.profile else PROFILES
    for name,(addr,wide,narrow) in profiles.items():
        image = build / (name+'.vvp')
        plan += [('compile_'+name,[iv,'-g2012','-Wall','-s','tb_axil_width_downsizer',
                                  f'-Ptb_axil_width_downsizer.ADDR_W={addr}',
                                  f'-Ptb_axil_width_downsizer.S_DATA_W={wide}',
                                  f'-Ptb_axil_width_downsizer.M_DATA_W={narrow}',
                                  '-o',image,'-c','files.f','sim/tb_axil_width_downsizer.sv']),
                 ('sim_'+name,[vv,image])]
    stopped = None
    missing = [str(p) for p in (iv,vv) if not p.is_file()]
    if missing:
        stopped = 'missing tool: '+', '.join(missing)
    for name, argv in plan:
        began = time.monotonic()
        if stopped:
            record, stdout, stderr = {'status':'NOT_RUN','reason':stopped}, b'', b''
        else:
            record, stdout, stderr = execute(argv, env)
        if record['status']=='PASS' and name.startswith('sim_') and b'PASS axil_width_downsizer' not in stdout:
            record.update(status='FAIL',reason='missing TB completion marker')
        if record['status']!='PASS' and stopped is None:
            stopped = name+' '+record['status']+'; remaining checks not executed'
        (output/(name+'.stdout.txt')).write_bytes(stdout)
        (output/(name+'.stderr.txt')).write_bytes(stderr)
        record.update(name=name,argv=list(map(str,argv)),cwd=str(ROOT),
                      seconds=round(time.monotonic()-began,6),
                      stdout_sha256=hashlib.sha256(stdout).hexdigest(),
                      stderr_sha256=hashlib.sha256(stderr).hexdigest())
        receipt['records'].append(record)
        (output/'results.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
        print(name+': '+record['status'],flush=True)
    receipt['sources_unchanged'] = all(sha(ROOT/name)==value for name,value in hashes.items())
    receipt['status'] = 'PASS' if stopped is None and receipt['sources_unchanged'] else 'FAIL'
    (output/'results.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print(output/'results.json')
    return 0 if receipt['status']=='PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
