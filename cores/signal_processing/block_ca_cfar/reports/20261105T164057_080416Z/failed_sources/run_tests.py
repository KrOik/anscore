"""SPDX-License-Identifier: Apache-2.0. Finite Icarus checks; no synthesis."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
TOOLS = REPO / 'tools/oss-cad-suite/oss-cad-suite'
BIN = TOOLS / 'bin'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    out = ROOT / 'reports' / stamp
    out.mkdir(parents=True)
    env = os.environ.copy()
    env['PATH'] = str(BIN) + os.pathsep + str(TOOLS/'lib') + os.pathsep + env.get('PATH', '')
    compiler = BIN / 'iverilog.exe'
    runtime = BIN / 'vvp.exe'
    if not compiler.exists():
        compiler = Path(shutil.which('iverilog') or 'iverilog')
        runtime = Path(shutil.which('vvp') or 'vvp')
    sources = ['rtl/block_ca_cfar.sv', 'example/cfar_power_frame.sv',
               'sim/tb_block_ca_cfar.sv', 'run_tests.py', 'files.f', 'example/files.f']
    report = {'utc': stamp, 'timeout_seconds_per_child': 20,
              'sources': {p:digest(ROOT/p) for p in sources},
              'tools': {str(p):digest(p) for p in (compiler,runtime) if p.is_file()},
              'scope': 'Icarus -tnull and finite deterministic unit simulations only',
              'hardware': 'HW_UNVERIFIED', 'checks': []}
    def run(name, argv):
        record = {'name': name, 'argv': list(map(str, argv))}
        try:
            child = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, timeout=20)
            stdout, stderr = child.stdout, child.stderr
            record.update(returncode=child.returncode, status='PASS' if child.returncode==0 else 'FAIL')
        except subprocess.TimeoutExpired as exc:
            stdout, stderr = exc.stdout or b'', exc.stderr or b''
            record.update(status='TIMEOUT')
        except OSError as exc:
            stdout, stderr = b'', str(exc).encode()
            record.update(status='NOT_RUN')
        (out/(name+'.stdout.txt')).write_bytes(stdout)
        (out/(name+'.stderr.txt')).write_bytes(stderr)
        record['stdout_sha256']=hashlib.sha256(stdout).hexdigest()
        record['stderr_sha256']=hashlib.sha256(stderr).hexdigest()
        if name.startswith('sim') and record['status']=='PASS' and b'PASS N=' not in stdout:
            record['status']='FAIL_NO_PASS_MARKER'
        report['checks'].append(record)
        (out/'results.json').write_text(json.dumps(report,indent=2)+'\n')
        print(name,record['status'],stdout.decode(errors='replace').strip())
        return record['status']=='PASS'
    ok = run('syntax_default',[str(compiler),'-g2012','-Wall','-tnull','-s','block_ca_cfar','-f','files.f'])
    ok = run('syntax_example',[str(compiler),'-g2012','-Wall','-tnull','-s','cfar_power_frame','-f','example/files.f']) and ok
    configurations=[(64,8,2,1,8),(1,1,1,0,1),(17,32,3,0,16),(70,16,16,16,16)]
    # VVPs live only in a task-specific temporary directory and are not delivered.
    with tempfile.TemporaryDirectory(prefix='anscore_b31_cfar_') as temporary:
        for number,values in enumerate(configurations):
            image=Path(temporary)/('case%d.vvp'%number)
            params=['-Ptb_block_ca_cfar.%s=%d'%(k,v) for k,v in zip(('N','D','T','G','A'),values)]
            passed=run('compile%d'%number,[str(compiler),'-g2012','-Wall','-s','tb_block_ca_cfar',*params,'-o',str(image),'-f','files.f','sim/tb_block_ca_cfar.sv'])
            ok=passed and ok
            if passed:
                ok=run('sim%d'%number,[str(runtime),str(image)]) and ok
    report['status']='PASS' if ok else 'INCOMPLETE'
    report['maturity']=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'] if ok else ['RTL_CANDIDATE','HW_UNVERIFIED']
    (out/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Evidence:',out.relative_to(ROOT).as_posix())
    return 0 if ok else 1

if __name__=='__main__':
    sys.exit(main())
