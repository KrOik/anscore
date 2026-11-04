#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""One fixed qualification of sealed sources and pre-RTL frozen fixtures."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parent
MATRIX_SHA='156021352745b07627dbe3ec9a0fbe4ee90db27131084382b325b34511ed2cd0'
MARKER='exact_binary_permanent_invalid_parameters__see_README'
PROFILES=[(1,1),(2,3),(3,8),(5,8),(8,8),(12,32)]
FIELDS={'mode','N','T','frames','outputs','queued','resets','fresh','latency_checks',
        'dp_certificates','bank_checks','ram_reads','row_writes','dp_writes',
        'source_holds','output_holds','states','resetmask','cycles'}


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def write_json(path,obj):path.write_text(json.dumps(obj,indent=2)+'\n',encoding='utf-8',newline='\n')


def sources():
    return {p.relative_to(ROOT).as_posix():sha(p) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name not in ['SOURCE_FREEZE.json','verification.json']
            and 'failure_archive' not in p.relative_to(ROOT).parts}


def main_fixture(path):
    words=iter(map(int,(ROOT/path).read_text(encoding='ascii').split()));frames=[]
    for _ in range(next(words)):
        h=[next(words) for _ in range(8)]
        tokens=[tuple(next(words) for _ in range(5)) for _ in range(h[0])]
        gold=[next(words) for _ in range(h[7])]
        frames.append(dict(inputs=h[0],value=h[1],error=h[2],rows=h[3],tag=h[4],
                           latency=h[5],reads=h[6],certificates=h[7],tokens=tokens,gold=gold))
    assert next(words,None) is None
    return frames


def reset_fixture(path):
    words=iter(map(int,(ROOT/path).read_text(encoding='ascii').split()));probes=[]
    for _ in range(next(words)):
        target,count=next(words),next(words)
        probes.append((target,[tuple(next(words) for _ in range(5)) for _ in range(count)]))
    assert next(words,None) is None
    return probes


def check_matrix():
    assert sha(ROOT/'MATRIX_FREEZE.json')==MATRIX_SHA
    p=json.loads((ROOT/'MATRIX_FREEZE.json').read_bytes())
    assert p['stage']=='COMPLETE_INPUTS_ORACLES_SPLITS_BEFORE_ORIGINAL_HDL' and p['timeout_seconds']==20
    assert sha(ROOT/'prepare_matrix.py')==p['preparation_sha256']
    assert sha(ROOT/'.gitattributes')==p['attribute_sha256']
    assert [(q['n'],q['t']) for q in p['profiles']]==PROFILES
    fixtures=set()
    for profile in p['profiles']:
        rows=[];targets=[];n=profile['n'];depth=1<<n
        for group in profile['main_groups']:
            assert sha(ROOT/group['path'])==group['sha256'];fixtures.add(group['path'])
            block=main_fixture(group['path']);assert len(rows)==group['first'];rows+=block
            assert len(block)==group['frames'] and sum(x['inputs'] for x in block)==group['inputs']
            assert sum(x['certificates'] for x in block)==group['dp_certificates']
            assert sum(x['latency'] for x in block)==group['compute_cycles']
            for x in block:
                assert x['tokens'][-1][2] and not any(t[2] for t in x['tokens'][:-1])
                assert x['tag']==x['tokens'][0][4] and x['certificates']==(0 if x['error'] else depth)
                assert x['rows']==min(n,sum(t[1] for t in x['tokens']))
        assert len(rows)==profile['main_frames'] and sum(x['inputs'] for x in rows)==profile['main_inputs']
        assert sum(x['certificates'] for x in rows)==profile['main_dp_certificates']
        assert sum(x['reads'] for x in rows)==profile['main_reads']
        assert sorted(set(x['error'] for x in rows))==profile['error_values']
        assert sha(ROOT/profile['fresh_fixture'])==profile['fresh_sha256'];fixtures.add(profile['fresh_fixture'])
        fresh=main_fixture(profile['fresh_fixture']);assert len(fresh)==1
        assert fresh[0]['rows']==n and fresh[0]['error']==0 and fresh[0]['certificates']==depth
        assert fresh[0]['latency']==profile['latency_bound'] and fresh[0]['tag']==profile['first_fresh_tag']
        assert [t[0] for t in fresh[0]['tokens'] if t[1]]==[depth-1]*n
        for group in profile['reset_groups']:
            assert sha(ROOT/group['path'])==group['sha256'];fixtures.add(group['path'])
            block=reset_fixture(group['path']);assert [x[0] for x in block]==group['targets'];targets+=group['targets']
        assert targets==list(range(32))
    assert len(fixtures)==206 and len(p['children'])==213
    assert fixtures=={q.relative_to(ROOT).as_posix() for q in (ROOT/'sim/fixtures').glob('*.txt')}
    return p


def commands(plan):
    iv,vvp='@IVERILOG@','@VVP@';top='exact_binary_permanent';tb='tb_'+top
    out=[('version',[iv,'-V'],False),
         ('core_syntax',[iv,'-g2012','-Wall','-tnull','-s',top,'-f','files.f'],False),
         ('example_syntax',[iv,'-g2012','-Wall','-tnull','-s','compatibility_count8','-f','example/files.f'],False)]
    for p in plan['profiles']:
        binary='@TEMP@/'+p['name']+'.vvp'
        groups=p['main_groups']+p['reset_groups'];budget=max(g['conservative_cycle_limit'] for g in groups)
        maxframes=max(g['frames'] for g in p['main_groups']);maxinputs=max(g['inputs'] for g in p['main_groups'])
        out.append((p['name']+'_compile',[iv,'-g2012','-Wall','-s',tb,'-o',binary,
                    '-P',f'{tb}.N={p["n"]}','-P',f'{tb}.T={p["t"]}',
                    '-P',f'{tb}.MAX_FRAMES={maxframes}','-P',f'{tb}.MAX_INPUTS={maxinputs}',
                    '-P',f'{tb}.CYCLE_LIMIT={budget}','rtl/'+top+'.sv','sim/'+tb+'.sv'],False))
        for g in p['main_groups']:
            out.append((g['name'],[vvp,binary,'+MODE=0','+FIXTURE=@ROOT@/'+g['path']],False))
        for g in p['reset_groups']:
            out.append((g['name'],[vvp,binary,'+MODE=1','+FIXTURE=@ROOT@/'+g['path'],
                        '+FRESH=@ROOT@/'+p['fresh_fixture']],False))
    for key,n,t in plan['negatives']:
        out.append(('reject_'+key,[iv,'-g2012','-tnull','-s',top,'-P',f'{top}.N={n}',
                    '-P',f'{top}.TAG_W={t}','rtl/'+top+'.sv'],True))
    assert [c[0] for c in out]==plan['children'] and len(out)==213
    return out


def seal_source():
    assert not (ROOT/'SOURCE_FREEZE.json').exists() and not (ROOT/'verification.json').exists()
    plan=check_matrix();content=sources()
    for name in content:
        b=(ROOT/name).read_bytes();b.decode('utf-8');assert b'\r' not in b and not b.startswith(b'\xef\xbb\xbf'),name
    write_json(ROOT/'SOURCE_FREEZE.json',dict(stage='BEFORE_FIRST_COMPILER',baseline=plan['baseline'],
        matrix_sha256=MATRIX_SHA,source_sha256=content,timeout_seconds=20,children=plan['children'],commands=commands(plan)))
    print('SOURCE_FROZEN',sha(ROOT/'SOURCE_FREEZE.json'),'sources',len(content),'children',len(plan['children']))


def probe_check(profile,probe):
    target=probe['target'];eff=profile['reset_aliases'].get(str(target),target);n=profile['n'];depth=1<<n
    assert probe['effective']==eff
    state={0:0,1:0,2:0,3:0,4:0,5:1,6:2,7:3,8:4,9:5,10:6,11:7,
           12:2,13:3,14:4,15:5,16:6,17:7,18:8,19:9,20:10,21:10,
           22:10,23:10,24:10,25:10,26:10,27:4,28:7,29:5,30:10,31:10}[eff]
    assert probe['state']==state
    if 6<=eff<=11:assert probe['mask']==1
    if 12<=eff<=19:assert probe['mask']==depth-1
    if eff in [8,9,10]:assert probe['column']==0
    if eff in [14,15,16,17]:assert probe['column']==n-1
    if eff in [27,28,29]:assert probe['mask']==3
    if eff==27:assert probe['column']==1
    if eff==29:assert probe['column']==0


def canceled_counts(profile,probe,tokens):
    """Counts of issued bank actions before the observed pre-execution state."""
    n=profile['n'];depth=1<<n;target=probe['target'];eff=probe['effective'];state=probe['state']
    rows=[t[0] for t in tokens if t[1]][:n]
    captured=0 if eff in [0,1] else 1 if eff==2 else len(rows)
    if eff<=4 or 22<=eff<=26:return dict(row_writes=captured,dp_writes=0,ram_reads=0)
    if state==1:return dict(row_writes=captured,dp_writes=0,ram_reads=0)
    assert len(rows)==n
    eligible=lambda mask: (mask & rows[mask.bit_count()-1]).bit_count()
    if state>=8:
        return dict(row_writes=captured,dp_writes=depth,
                    ram_reads=depth-1+sum(eligible(m) for m in range(1,depth))+(state>=9))
    mask=probe['mask'];column=probe['column'];reads=sum(eligible(m) for m in range(1,mask))
    row_reads=mask-1+(state>=4)
    if state==7:reads+=eligible(mask)
    elif state>=4:
        selected=mask & rows[mask.bit_count()-1];reads+=(selected & ((1<<column)-1)).bit_count()
        if state==6:reads+=(selected>>column)&1
    return dict(row_writes=captured,dp_writes=mask,ram_reads=row_reads+reads)


def parse_output(stdout):
    summaries=[s for s in stdout.splitlines() if s.startswith('PASS mode=')];assert len(summaries)==1
    words=dict(re.findall(r'(\w+)=([^ ]+)',summaries[0]));assert set(words)==FIELDS
    result={k:int(v,16 if k in ['states','resetmask'] else 10) for k,v in words.items()}
    probes=[]
    for line in stdout.splitlines():
        if line.startswith('OBS '):
            p=dict(re.findall(r'(\w+)=(\d+)',line));assert set(p)=={'target','effective','state','mask','column'}
            probes.append({k:int(v) for k,v in p.items()})
        else:assert line==summaries[0] or re.fullmatch(r'.*\$finish called at \d+ \(1ps\)',line),line
    return result,probes


def check_result(profile,group,kind,observed,probes):
    n=profile['n'];depth=1<<n
    assert observed['mode']==(0 if kind=='main' else 1) and observed['N']==n and observed['T']==profile['t']
    assert observed['cycles']<=group['conservative_cycle_limit']
    if kind=='main':
        block=main_fixture(group['path']);frames=len(block);good=sum(x['error']==0 for x in block)
        expected=dict(frames=frames,outputs=frames,queued=frames-1,resets=0,fresh=0,
            latency_checks=frames,dp_certificates=good*depth,bank_checks=good*depth,
            dp_writes=good*depth,row_writes=sum(x['rows'] for x in block),
            ram_reads=sum(x['reads'] for x in block)+good*depth,resetmask=0)
        assert not probes and observed['source_holds']>=frames-1
    else:
        block=reset_fixture(group['path']);count=len(block);fresh=main_fixture(profile['fresh_fixture'])[0]
        assert [p['target'] for p in probes]==group['targets']
        expected=dict(frames=0,outputs=0,queued=0,resets=count,fresh=count,latency_checks=count,
            dp_certificates=count*depth,bank_checks=count*depth,row_writes=count*n,
            dp_writes=count*depth,ram_reads=count*(fresh['reads']+depth),
            resetmask=sum(1<<i for i in group['targets']),states=2047)
        for probe,(target,tokens) in zip(probes,block):
            assert probe['target']==target;probe_check(profile,probe)
            for key,value in canceled_counts(profile,probe,tokens).items():expected[key]+=value
        frames=count
    for key,value in expected.items():assert observed[key]==value,(profile['name'],group['name'],key,observed[key],value)
    assert observed['output_holds']>=3*frames


def audit():
    plan=check_matrix();seal=json.loads((ROOT/'SOURCE_FREEZE.json').read_bytes());r=json.loads((ROOT/'verification.json').read_bytes())
    assert r['status']=='UNIT_SIM_PASS' and not r['terminal_timeout']
    assert seal['matrix_sha256']==r['matrix_sha256']==MATRIX_SHA
    assert r['source_freeze_sha256']==sha(ROOT/'SOURCE_FREEZE.json')
    assert seal['source_sha256']==r['source_sha256']==sources()
    assert seal['commands']==[list(c) for c in commands(plan)]
    assert [c['name'] for c in r['records']]==plan['children'] and len(r['records'])==213
    replacements=r['path_expansion']
    results=[]
    for record,(name,template,reject) in zip(r['records'],commands(plan)):
        argv=[]
        for arg in template:
            for token,value in replacements.items():arg=arg.replace(token,value)
            argv.append(arg)
        assert record['argv']==argv and record['status']=='PASS' and record['timeout_seconds']==20
        assert record['elapsed_seconds']<20.5
        assert (record['exit_code']!=0 and MARKER in record['stdout']+record['stderr']) if reject else record['exit_code']==0
        if not reject and name!='version':assert not record['stderr'] and not re.search(r'warning|error|fatal',record['stdout'],re.I)
        if '_main_' in name or '_reset_' in name:
            p=next(p for p in plan['profiles'] if name.startswith(p['name']+'_'))
            kind='main' if '_main_' in name else 'reset';g=next(g for g in p[kind+'_groups'] if g['name']==name)
            observed,probes=parse_output(record['stdout']);check_result(p,g,kind,observed,probes)
            results.append(dict(profile=p['name'],group=name,kind=kind,observed=observed,probes=probes))
    assert results==r['results'] and len(results)==200
    for p,summary in zip(plan['profiles'],r['profiles']):
        items=[i for i in results if i['profile']==p['name']];states=0;resetmask=0
        for item in items:states|=item['observed']['states'];resetmask|=item['observed']['resetmask']
        expected=dict(name=p['name'],main_frames=sum(i['observed']['frames'] for i in items),
                      resets=sum(i['observed']['resets'] for i in items),fresh=sum(i['observed']['fresh'] for i in items),states=states,resetmask=resetmask)
        assert summary==expected and summary['main_frames']==p['main_frames']
        assert summary['resets']==summary['fresh']==32 and states==2047 and resetmask==0xffffffff
    totals={k:sum(i['observed'][k] for i in results) for k in FIELDS-{'mode','N','T','states','resetmask'}}
    assert r['totals']==totals and totals['frames']==742 and totals['resets']==totals['fresh']==192 and totals['queued']==654
    for name in sources():
        b=(ROOT/name).read_bytes();b.decode('utf-8');assert b'\r' not in b and not b.startswith(b'\xef\xbb\xbf')
    print('OFFLINE_AUDIT_PASS',MATRIX_SHA,sha(ROOT/'SOURCE_FREEZE.json'),sha(ROOT/'verification.json'))


def run():
    plan=check_matrix();seal=json.loads((ROOT/'SOURCE_FREEZE.json').read_bytes())
    assert seal['matrix_sha256']==MATRIX_SHA and seal['source_sha256']==sources()
    assert seal['commands']==[list(c) for c in commands(plan)]
    assert not (ROOT/'verification.json').exists(),'never overwrite a qualification receipt'
    toolbin=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin'
    iv,vvp=toolbin/'iverilog.exe',toolbin/'vvp.exe';assert iv.is_file() and vvp.is_file()
    env=dict(os.environ);env['PATH']=str(toolbin)+os.pathsep+str(toolbin.parent/'lib')+os.pathsep+env.get('PATH','')
    temp_root=Path(tempfile.gettempdir()).resolve();tmp=Path(tempfile.mkdtemp(prefix='anscore_b24_permanent_',dir=temp_root)).resolve()
    assert tmp.parent==temp_root and tmp.name.startswith('anscore_b24_permanent_')
    replacements={'@IVERILOG@':str(iv),'@VVP@':str(vvp),'@ROOT@':ROOT.as_posix(),'@TEMP@':tmp.as_posix()}
    receipt=dict(baseline=plan['baseline'],status='IN_PROGRESS',hardware='HW_UNVERIFIED',matrix_sha256=MATRIX_SHA,
        source_freeze_sha256=sha(ROOT/'SOURCE_FREEZE.json'),source_sha256=sources(),path_expansion=replacements,
        records=[dict(name=name,status='NOT_RUN') for name in plan['children']],results=[],profiles=[],terminal_timeout=False)
    def save():write_json(ROOT/'verification.json',receipt)
    save()
    try:
        for index,(name,template,reject) in enumerate(commands(plan)):
            argv=[]
            for arg in template:
                for token,value in replacements.items():arg=arg.replace(token,value)
                argv.append(arg)
            start=time.monotonic();record=dict(name=name,argv=argv,timeout_seconds=20)
            try:
                result=subprocess.run(argv,cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=20)
                good=(result.returncode!=0 and MARKER in result.stdout+result.stderr) if reject else result.returncode==0
                if not reject and name!='version':good=good and not result.stderr and not re.search(r'warning|error|fatal',result.stdout,re.I)
                record.update(exit_code=result.returncode,stdout=result.stdout,stderr=result.stderr,status='PASS' if good else 'FAIL')
            except subprocess.TimeoutExpired as exc:
                decode=lambda x:x.decode('utf-8','replace') if isinstance(x,bytes) else x or ''
                record.update(exit_code=None,stdout=decode(exc.stdout),stderr=decode(exc.stderr),status='TIMEOUT');receipt['terminal_timeout']=True
            record['elapsed_seconds']=round(time.monotonic()-start,3);receipt['records'][index]=record;save()
            print(name,record['status'],record['elapsed_seconds'],flush=True)
            if record['status']!='PASS':raise RuntimeError(name+' '+record['status'])
            if '_main_' in name or '_reset_' in name:
                try:
                    p=next(p for p in plan['profiles'] if name.startswith(p['name']+'_'))
                    kind='main' if '_main_' in name else 'reset';g=next(g for g in p[kind+'_groups'] if g['name']==name)
                    observed,probes=parse_output(record['stdout']);check_result(p,g,kind,observed,probes)
                    receipt['results'].append(dict(profile=p['name'],group=name,kind=kind,observed=observed,probes=probes));save()
                except Exception as exc:
                    record['status']='FAIL';record['validation_error']=repr(exc);save();raise
        for p in plan['profiles']:
            items=[i for i in receipt['results'] if i['profile']==p['name']];states=0;resetmask=0
            for item in items:states|=item['observed']['states'];resetmask|=item['observed']['resetmask']
            receipt['profiles'].append(dict(name=p['name'],main_frames=sum(i['observed']['frames'] for i in items),
                resets=sum(i['observed']['resets'] for i in items),fresh=sum(i['observed']['fresh'] for i in items),states=states,resetmask=resetmask))
        receipt['totals']={k:sum(i['observed'][k] for i in receipt['results']) for k in sorted(FIELDS-{'mode','N','T','states','resetmask'})}
        assert sources()==seal['source_sha256'];receipt['status']='UNIT_SIM_PASS';save();audit()
        print('QUALIFIED',sha(ROOT/'verification.json'),receipt['totals'])
    except Exception as exc:
        receipt['status']='TIMEOUT_NOT_RUN' if receipt['terminal_timeout'] else 'FAIL';receipt['error']=repr(exc);save()
        index=1
        while (ROOT/'failure_archive'/f'attempt_{index:02d}').exists():index+=1
        archive=ROOT/'failure_archive'/f'attempt_{index:02d}';archive.mkdir(parents=True)
        for name in [*seal['source_sha256'],'SOURCE_FREEZE.json','verification.json']:
            destination=archive/name;destination.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,destination)
        (archive/'NOT_RUN.txt').write_text('\n'.join(r['name'] for r in receipt['records'] if r['status']=='NOT_RUN')+'\n',encoding='utf-8',newline='\n')
        print('PRESERVED_FAILURE',archive,sha(ROOT/'verification.json'),flush=True);raise
    finally:
        assert tmp.parent==temp_root and tmp.name.startswith('anscore_b24_permanent_');shutil.rmtree(tmp)


if __name__=='__main__':
    parser=argparse.ArgumentParser();group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--seal-source',action='store_true');group.add_argument('--run',action='store_true');group.add_argument('--audit',action='store_true')
    args=parser.parse_args()
    if args.seal_source:seal_source()
    elif args.run:run()
    else:audit()
