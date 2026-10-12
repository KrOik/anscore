"""Guarded SRAM-only USB tests, independent host checker, immutable raw evidence."""
import argparse
import ast
import hashlib
import json
import os
import shlex
import sys
from pathlib import Path
import paramiko
from common import ROOT,REPO,evidence
sys.path.insert(0,str(ROOT/'models'))
from board_reference import vectors,validate

def password():
    if os.getenv('P25_PASSWORD'): return os.environ['P25_PASSWORD']
    for n in ast.parse((REPO/'tools/_remote/sshrun.py').read_text(encoding='utf-8-sig')).body:
        if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='PASSWORD' for t in n.targets): return ast.literal_eval(n.value)
    raise RuntimeError('missing authorized board credential')

def execute(c,argv,timeout=60):
    _,out,err=c.exec_command(shlex.join(map(str,argv)),timeout=timeout)
    text=out.read().decode('utf-8','replace')+err.read().decode('utf-8','replace')
    code=out.channel.recv_exit_status()
    return code,text

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--build',required=True,type=Path)
    ap.add_argument('--profiles',default='0,1,2,3,4,5,6,7'); ap.add_argument('--host',default='192.168.31.176'); a=ap.parse_args()
    build=a.build.resolve(); report_build=json.loads((build/'summary.json').read_text()); builds={r['profile']:r for r in report_build['profiles']}
    profiles=list(map(int,a.profiles.split(',')))
    for p in profiles:
        r=builds[p]; assert r['under_budget'] and r['route']=='PASS'
        for f,h in r['input_sha256'].items(): assert hashlib.sha256((REPO/f).read_bytes()).hexdigest()==h,('stale build',f)
        assert hashlib.sha256((ROOT/r['bitstream']).read_bytes()).hexdigest()==r['bitstream_sha256']
    out=evidence('board'); report={'status':'IN_PROGRESS','host':a.host,'device':'GW5A-25','build':str(build),'profiles':[],'clock_mhz':50,'clock_enable':1}
    c=paramiko.SSHClient(); c.load_system_host_keys()
    known=ROOT.parent/'production_ip_25k/.remote_known_hosts'
    if known.exists(): c.load_host_keys(str(known))
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(a.host,username='bianbu',password=password(),allow_agent=False,look_for_keys=False,timeout=15)
    sftp=c.open_sftp(); remote='/home/bianbu/'+out.name+'_system_ip'
    try:
        code,detection=execute(c,['openFPGALoader','-b','tangprimer25k','--detect'])
        (out/'jtag.txt').write_text(detection,encoding='utf-8')
        assert code==0 and 'GW5A-25' in detection and '0x1281b' in detection,'unexpected JTAG device'
        sftp.mkdir(remote)
        for local in [ROOT/'tools/uart_client.py',ROOT/'models/codec.py']: sftp.put(str(local),remote+'/'+local.name)
        for p in profiles:
            cases=[dict(core=k,seed=seed,stall=stall,**vectors(p,k,seed)) for k in range(16 if p==0 else (1 if p==8 else 8)) for seed,stall in [(1,0),(2,1)]]
            config={'profile':p,'cases':[dict(name=q['name'],core=q['core'],seed=q['seed'],stall=q['stall'],rows=[f'{r:024x}' for r in q['rows']],outputs=len(q['expected'])) for q in cases]}
            local=out/f'profile_{p}_stimuli.json'; local.write_text(json.dumps(config,indent=2)+'\n')
            r=builds[p]; fs=ROOT/r['bitstream']; remote_fs=remote+f'/profile_{p}.fs'
            sftp.put(str(fs),remote_fs); sftp.put(str(local),remote+f'/cases_{p}.json')
            code,sha=execute(c,['sha256sum',remote_fs]); assert code==0 and sha.startswith(r['bitstream_sha256'])
            cmd='openFPGALoader -b tangprimer25k '+shlex.quote(remote_fs)+' && python3 '+shlex.quote(remote+'/uart_client.py')
            cmd+=' --cases '+shlex.quote(remote+f'/cases_{p}.json')+' --output '+shlex.quote(remote+f'/raw_{p}.json')
            code,log=execute(c,['flock','-n','/tmp/production_ip_25k_board.lock','sh','-c',cmd],180)
            (out/f'profile_{p}_program_uart.log').write_text(log,encoding='utf-8')
            try: sftp.get(remote+f'/raw_{p}.json',str(out/f'profile_{p}_raw.json'))
            except FileNotFoundError: pass
            assert code==0,('program/UART failed',p,log[-1200:])
            raw=json.loads((out/f'profile_{p}_raw.json').read_text()); assert raw['status']=='CAPTURED'
            assert len(raw['runs'])==len(cases)
            for case,got in zip(cases,raw['runs']):
                assert got['inputs']==[f'{r:024x}' for r in case['rows']]
                validate(case,[int(r,16) for r in got['raw']])
                n=len(case['rows']); metrics=got['metrics']
                if 1<=p<=7 or (p==0 and case['core'] in [3,7,8,11,13,14,15]): assert metrics['errors']==0,(case['name'],metrics)
                if not case['stall'] and (1<=p<=7 or (p==0 and case['core'] in [3,7,8,13,14,15])): assert got['status']['cycles']<=n+4,('full rate failed',case['name'])
                got['model_check']='PASS'
            raw['status']='PASS'; (out/f'profile_{p}_checked.json').write_text(json.dumps(raw,indent=2)+'\n')
            report['profiles'].append(dict(profile=p,status='PASS',runs=len(cases),raw_outputs=sum(len(r['raw']) for r in raw['runs']),
                bitstream_sha256=r['bitstream_sha256'],stimuli_sha256=hashlib.sha256(local.read_bytes()).hexdigest(),
                raw_sha256=hashlib.sha256((out/f'profile_{p}_raw.json').read_bytes()).hexdigest()))
            (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
            print(f'BOARD profile={p} PASS runs={len(cases)} raw={report["profiles"][-1]["raw_outputs"]}',flush=True)
        report['status']='PASS'
    except Exception as e: report['status']='FAIL'; report['reason']=str(e); raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n'); sftp.close(); c.close(); print('Evidence='+str(out),flush=True)

if __name__=='__main__': main()
