#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded cyclic-gate cycle checks; no hardware tools or automatic retry."""
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
from verification_model import make_vectors
ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
PROFILES={'min':(1,1,1,1,1,1),'ragged':(3,3,3,8,17,9),'default':(4,4,4,16,32,8)}
INPUTS=['run_tests.py','verification_model.py','files.f','example/files.f',
        'rtl/cyclic_gate_packet_scheduler.sv','sim/tb_cyclic_gate_packet_scheduler.sv',
        'example/cyclic_packet_gate4.sv','../common_scaffold/memory/src/cip_sync_fifo.v']
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def child(argv,env):
    flags={'creationflags':subprocess.CREATE_NEW_PROCESS_GROUP} if os.name=='nt' else {'start_new_session':True}
    try:
        proc=subprocess.Popen(list(map(str,argv)),cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**flags)
    except OSError as exc:
        return {'status':'NOT_RUN','reason':str(exc)},b'',b''
    try:
        stdout,stderr=proc.communicate(timeout=20)
        return {'status':'PASS' if proc.returncode==0 else 'FAIL','exit_code':proc.returncode},stdout,stderr
    except subprocess.TimeoutExpired as exc:
        stdout,stderr=exc.stdout or b'',exc.stderr or b''
        result={'status':'TIMEOUT','cleanup_errors':[]}
        try:
            if os.name=='nt':
                killed=subprocess.run(['taskkill','/PID',str(proc.pid),'/T','/F'],capture_output=True,timeout=5)
                if killed.returncode: result['cleanup_errors'].append('taskkill exit '+str(killed.returncode))
            else: os.killpg(proc.pid,signal.SIGKILL)
        except (OSError,subprocess.SubprocessError) as cleanup:
            result['cleanup_errors'].append(str(cleanup))
        if proc.poll() is None:
            try: proc.kill()
            except OSError as cleanup: result['cleanup_errors'].append(str(cleanup))
        try:
            stdout,stderr=proc.communicate(timeout=5)
            result['cleanup_complete']=proc.returncode is not None
        except (OSError,subprocess.SubprocessError) as cleanup:
            result['cleanup_complete']=False;result['cleanup_errors'].append(str(cleanup))
            if isinstance(cleanup,subprocess.TimeoutExpired):
                stdout=cleanup.stdout if cleanup.stdout is not None else stdout
                stderr=cleanup.stderr if cleanup.stderr is not None else stderr
            if proc.poll() is None:
                try: proc.kill()
                except OSError as last: result['cleanup_errors'].append(str(last))
        result['exit_code']=proc.returncode
        return result,stdout,stderr


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--profile',choices=PROFILES)
    parser.add_argument('--tool-bin',type=Path)
    options=parser.parse_args()
    bindir=options.tool_bin or REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
    suffix='.exe' if os.name=='nt' else ''
    iv,vv=bindir/('iverilog'+suffix),bindir/('vvp'+suffix)
    env=dict(os.environ);env['PATH']=os.pathsep.join([str(bindir),str(bindir.parent/'lib'),env.get('PATH','')])
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=ROOT/'reports'/stamp;build=ROOT/'.build'/stamp
    out.mkdir(parents=True);build.mkdir(parents=True)
    hashes={name:sha(ROOT/name) for name in INPUTS}
    copies={}
    for name in INPUTS:
        source=(ROOT/name).resolve();target=out/'sources'/source.relative_to(REPO)
        target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
        copies[name]=target.relative_to(out).as_posix()
    report={'schema':'anscore-b34-finite-v1','utc':stamp,'source_sha256':hashes,'source_copies':copies,
            'tool_sha256':{str(p):sha(p) for p in (iv,vv) if p.is_file()},'records':[],
            'hard_seconds_per_child':20,'bounded_cleanup_seconds_per_step':5,'automatic_retry':False,
            'hardware':'HW_UNVERIFIED','synthesis':'NOT_RUN','pnr':'NOT_RUN','sta':'NOT_RUN','board':'NOT_RUN','profiles':[]}
    plan=[]
    if options.profile is None:
        plan=[('lint_default',[iv,'-g2012','-Wall','-tnull','-s','cyclic_gate_packet_scheduler','-f','files.f']),
              ('lint_max',[iv,'-g2012','-Wall','-tnull','-s','cyclic_gate_packet_scheduler',
                           '-Pcyclic_gate_packet_scheduler.QUEUES=8','-Pcyclic_gate_packet_scheduler.DEPTH=16',
                           '-Pcyclic_gate_packet_scheduler.SLOTS=16','-Pcyclic_gate_packet_scheduler.DATA_W=64',
                           '-Pcyclic_gate_packet_scheduler.TAG_W=32','-f','files.f']),
              ('lint_example',[iv,'-g2012','-Wall','-tnull','-s','cyclic_packet_gate4','-f','example/files.f'])]
    profiles={options.profile:PROFILES[options.profile]} if options.profile else PROFILES
    for label,params in profiles.items():
        data,metrics=make_vectors(*params)
        vector=out/(label+'.txt');vector.write_text(data,encoding='ascii')
        report['profiles'].append({'name':label,'parameters':list(params),'metrics':metrics,'vectors':vector.name,'vector_sha256':sha(vector)})
        image=build/(label+'.vvp')
        overrides=[f'-Ptb_cyclic_gate_packet_scheduler.{name}={value}' for name,value in zip(['QUEUES','DEPTH','SLOTS','TICK_W','DATA_W','TAG_W'],params)]
        plan += [('compile_'+label,[iv,'-g2012','-Wall','-s','tb_cyclic_gate_packet_scheduler',*overrides,
                                   '-o',image,'-f','files.f','sim/tb_cyclic_gate_packet_scheduler.sv']),
                 ('sim_'+label,[vv,image,'+vectors='+vector.as_posix()])]
    stopped='missing tool: '+','.join(str(p) for p in (iv,vv) if not p.is_file()) if not (iv.is_file() and vv.is_file()) else None
    for name,argv in plan:
        began=time.monotonic()
        if stopped:record,stdout,stderr={'status':'NOT_RUN','reason':stopped},b'',b''
        else:record,stdout,stderr=child(argv,env)
        if record['status']=='PASS' and name.startswith('sim_') and b'PASS cyclic_gate_packet_scheduler' not in stdout:
            record.update(status='FAIL',reason='missing required completion marker')
        if record['status']!='PASS' and stopped is None:stopped=name+' '+record['status']+'; remaining children not launched'
        (out/(name+'.stdout.txt')).write_bytes(stdout);(out/(name+'.stderr.txt')).write_bytes(stderr)
        record.update(name=name,argv=list(map(str,argv)),cwd=str(ROOT),seconds=round(time.monotonic()-began,6),
                      stdout_sha256=hashlib.sha256(stdout).hexdigest(),stderr_sha256=hashlib.sha256(stderr).hexdigest())
        report['records'].append(record)
        (out/'results.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
        print(name+': '+record['status'],flush=True)
    report['sources_unchanged']=all(sha(ROOT/name)==value for name,value in hashes.items())
    report['complete_plan']=len(report['records'])==len(plan)
    report['status']='PASS' if stopped is None and report['sources_unchanged'] and report['complete_plan'] else 'FAIL'
    (out/'results.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(out/'results.json')
    return 0 if report['status']=='PASS' else 1
if __name__=='__main__':sys.exit(main())
