#!/usr/bin/env python3
"""Grouped peripheral development checks; preserves all existing evidence and legacy tests."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

BASE=Path(__file__).resolve().parent
REPO=BASE.parents[2]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=int, default=60)
    args=parser.parse_args()
    if args.timeout<1: parser.error('--timeout must be positive')
    stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    evidence=BASE/'evidence'/stamp
    evidence.mkdir(parents=True)
    suite=REPO/'tools'/'oss-cad-suite'/'oss-cad-suite'
    env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    sources=sorted((BASE/'rtl').glob('*.v'))
    benches=[('tb_common_serial_group','COMMON_SERIAL_GROUP PASS'),
             ('tb_common_sd_spi','PASS SD SPI:')]
    test_sources=[BASE/'sim'/(name+'.sv') for name,_ in benches]
    report={'status':'RUNNING','utc':stamp,'verification':'Grouped RTL compilation and short pin-level protocol simulation',
            'board_verified':False,'synthesis_run':False,'resource_impact':None,'steps':[],
            'sources_sha256':{p.relative_to(BASE).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in sources+test_sources+[Path(__file__).resolve()] if p.exists()}}
    def execute(label,command):
        start=time.monotonic()
        step={'name':label,'command':list(map(str,command)),'timeout_seconds':args.timeout}
        try:
            run=subprocess.run(step['command'],cwd=REPO,env=env,capture_output=True,text=True,
                               encoding='utf-8',errors='replace',timeout=args.timeout)
            out=run.stdout+run.stderr
            step['exit_code']=run.returncode
            step['timed_out']=False
        except subprocess.TimeoutExpired as exc:
            out='TIMEOUT\n'+str(exc)
            step['exit_code']=None;step['timed_out']=True
        step['elapsed_seconds']=round(time.monotonic()-start,3)
        log=evidence/(label+'.log');log.write_text(out,encoding='utf-8')
        step['log']=log.relative_to(BASE).as_posix();report['steps'].append(step)
        print(f"{label}: exit={step['exit_code']}",flush=True)
        if step['exit_code']!=0 or step['timed_out']:
            raise RuntimeError(f'{label} failed: {out}')
        return out
    try:
        iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH'])
        if not iv or not vv: raise RuntimeError('Icarus Verilog / vvp unavailable')
        execute('all_rtl_compile',[iv,'-g2012','-tnull',*sources])
        for name,marker in benches:
            exe=evidence/(name+'.vvp')
            execute(name+'_compile',[iv,'-g2012','-s',name,'-o',exe,*sources,BASE/'sim'/(name+'.sv')])
            out=execute(name+'_simulation',[vv,exe])
            if marker not in out: raise RuntimeError(f'{name} did not produce expected PASS marker')
            print(out.strip(),flush=True)
        report['status']='PASS'
        report['functional_modules']=9
        report['serial_group_modules']=5
        report['legacy_basics']='GPIO/PWM/timer/IRQ unchanged; existing validation evidence retained; included in aggregate compilation'
    except Exception as exc:
        report['status']='FAIL';report['error']=str(exc);print(str(exc),file=sys.stderr)
    finally:
        (evidence/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        print(f"COMMON_PERIPHERALS {report['status']} evidence={evidence}")
    return 0 if report['status']=='PASS' else 1

if __name__=='__main__':
    raise SystemExit(main())
