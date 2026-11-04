#!/usr/bin/env python3
"""Finite qualification only; all HDL children have a hard 20-second deadline."""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from prepare_matrix import oracle, rounds, reset_rows, matrix, PROFILES, NEGATIVES

ROOT = Path(__file__).resolve().parent
MARKER = 'affine_floor_sum_invalid_parameters__see_README'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2)+'\n', encoding='utf-8', newline='\n')


def sources():
    return {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name not in ['SOURCE_FREEZE.json', 'verification.json']
            and 'failure_archive' not in p.relative_to(ROOT).parts}


def read_rows(relative):
    return [tuple(map(int, line.split())) for line in (ROOT/relative).read_text().splitlines()]


def check_matrix():
    plan = json.loads((ROOT/'MATRIX_FREEZE.json').read_text())
    assert plan['freeze_stage'] == 'FINITE_MATRIX_BEFORE_ORIGINAL_HDL'
    assert plan['timeout_seconds'] == 20 and len(plan['children']) == 19
    assert plan['preparation_sha256'] == sha(ROOT/'prepare_matrix.py')
    assert plan['attribute_sha256'] == sha(ROOT/'.gitattributes')
    assert [(p['w'],p['t']) for p in plan['profiles']] == PROFILES
    assert plan['negatives'] == [list(row) for row in NEGATIVES]
    for index, p in enumerate(plan['profiles']):
        assert sha(ROOT/p['fixture']) == p['sha256']
        assert sha(ROOT/p['reset_fixture']) == p['reset_sha256']
        rows = read_rows(p['fixture'])
        assert [row[:4] for row in rows] == matrix(p['w'],index)
        assert len(rows) == p['statistics']['frames']
        stats = Counter()
        for row in rows:
            n,a,b,m,tag,total,error = row
            assert (total,error) == oracle(n,a,b,m)
            assert 0 <= tag < (1 << p['t']) and total < (1 << (3*p['w']))
            r = rounds(n,a,b,m)
            latency = r*(10*p['w']+8)-(2*p['w']+1) if r else 0
            stats['frames'] += 1; stats['m0'] += m==0
            stats['m0_n0'] += m==0 and n==0; stats['n0_success'] += m!=0 and n==0
            stats['rounds'] += r; stats['compute_cycles'] += latency
            stats['max_rounds'] = max(stats['max_rounds'],r)
            stats['max_latency'] = max(stats['max_latency'],latency)
            stats['max_sum'] = max(stats['max_sum'],total)
        assert dict(stats) == p['statistics']
        assert read_rows(p['reset_fixture']) == reset_rows(p['w'],p['t'])
        for row in read_rows(p['reset_fixture']):
            assert row[6:8] == oracle(*row[1:5]) and row[13:15] == oracle(*row[8:12])
    return plan


def child_commands(plan, iv='@IVERILOG@', vvp='@VVP@', tmp='@TEMP@'):
    result = [('version',[iv,'-V'],False),
              ('core_syntax',[iv,'-g2012','-Wall','-tnull','-s','affine_floor_sum','-f','files.f'],False),
              ('example_syntax',[iv,'-g2012','-Wall','-tnull','-s','affine_area_pair','-f','example/files.f'],False)]
    for p in plan['profiles']:
        name = p['name']; binary = str(Path(tmp)/(name+'.vvp'))
        trace = str(Path(tmp)/(name+'.trace'))
        result.append((name+'_compile',[iv,'-g2012','-Wall','-s','tb_affine_floor_sum','-o',binary,
                      '-P',f'tb_affine_floor_sum.W={p["w"]}',
                      '-P',f'tb_affine_floor_sum.TAG_W={p["t"]}',
                      '-P',f'tb_affine_floor_sum.CYCLE_LIMIT={p["conservative_cycle_estimate"]}',
                      'rtl/affine_floor_sum.sv','sim/tb_affine_floor_sum.sv'],False))
        result.append((name+'_simulate',[vvp,binary,'+FIXTURE='+str(ROOT/p['fixture']),
                      '+RESETS='+str(ROOT/p['reset_fixture']),'+TRACE='+trace],False))
    for name,w,t in plan['negatives']:
        result.append(('reject_'+name,[iv,'-g2012','-tnull','-s','affine_floor_sum',
                      '-P',f'affine_floor_sum.W={w}','-P',f'affine_floor_sum.TAG_W={t}',
                      'rtl/affine_floor_sum.sv'],True))
    assert [r[0] for r in result] == plan['children']
    return result


def freeze_source():
    assert not (ROOT/'SOURCE_FREEZE.json').exists(), 'never replace source freeze'
    assert not (ROOT/'verification.json').exists(), 'no qualification before source freeze'
    plan = check_matrix()
    content = sources()
    for relative in content:
        raw = (ROOT/relative).read_bytes(); raw.decode('utf-8')
        assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf'),relative
    frozen = dict(baseline=plan['baseline'],stage='COMPLETE_SOURCE_BEFORE_FIRST_COMPILER',
                  matrix_sha256=sha(ROOT/'MATRIX_FREEZE.json'),timeout_seconds=20,
                  children=plan['children'],commands=child_commands(plan),source_sha256=content)
    write_json(ROOT/'SOURCE_FREEZE.json',frozen)
    print('SOURCE_FROZEN',sha(ROOT/'SOURCE_FREEZE.json'),len(content))


def validate_trace(profile, path):
    w = profile['w']
    rows = read_rows(profile['fixture'])
    resets = read_rows(profile['reset_fixture'])
    rows += [r[8:15] for r in resets]
    contexts = {}
    outputs,probes = set(),set()
    coverage = Counter()
    for line in path.read_text().splitlines():
        words = line.split(); kind = words[0]; values = list(map(int,words[1:])); idx=values[0]
        if kind == 'X':
            assert idx not in probes and 0 <= idx < 31
            state,job,count,rounds_seen,held,nonterminal,error,alias = values[1:]
            is_alias = w==1 and idx in [18,19,22,24,28]
            assert alias == int(is_alias)
            if is_alias and idx!=28: assert (state,job,nonterminal)==(3,3,0)
            elif idx==0: assert state==0
            elif idx==1: assert state==1
            elif idx<=9: assert (state,job,count)==(2,(idx-2)//2,0 if (idx-2)%2==0 else w-1)
            elif idx<=13: assert (state,job)==(3,idx-10)
            elif idx<=19: assert (state,job,count)==(4,(idx-14)//2,0 if (idx-14)%2==0 else 2*w-1)
            elif idx<=22: assert (state,job)==(5,idx-20)
            elif idx==23: assert (state,job,nonterminal)==(3,3,0)
            elif idx==24: assert (state,job,nonterminal)==(3,3,1)
            elif idx in [25,26,27,30]:
                assert state==6 and held>=3 and error==int(idx in [26,30])
            elif idx==28: assert state==1 and (rounds_seen==0 if is_alias else rounds_seen>=2)
            elif idx==29: assert state==6 and held==0 and error==0
            else: raise AssertionError(('reset target',idx))
            probes.add(idx);coverage['reset_boundary_certificates']+=1;coverage['reset_aliases']+=alias
            continue
        assert 0 <= idx < len(rows)
        row=rows[idx]; on,oa,ob,om,tag,total,error=row
        if idx not in contexts:
            contexts[idx]=dict(n=on,a=oa,b=ob,m=om,s=0,r=0,stage='T' if on and om else 'O')
        c=contexts[idx]; n,a,b,m,s=c['n'],c['a'],c['b'],c['m'],c['s']
        if kind=='T':
            assert c['stage']=='T'
            c['r']+=1
            assert values[1:]==[c['r'],n,a,b,m,s]
            assert n>0 and m>0 and c['r']<=2*w+1
            assert s+oracle(n,a,b,m)[0]==total
            c['tri']=n*(n-1)//2;c['stage']='M0'
            coverage['round_invariant_certificates']+=1
        elif kind=='M':
            job,product=values[1:];assert c['stage']=='M'+str(job)
            expected=[c['tri'],c['tri']*c.get('qa',0),n*c.get('qb',0),n*a][job]
            assert product==expected and product < (1 << (3*w))
            if job in [1,2]: c['s']+=product
            c['stage']=['D0','D1','M3','Y'][job]
            coverage['multiply_certificates']+=1
        elif kind=='D':
            job,q,rem,divisor=values[1:];assert c['stage']=='D'+str(job) and divisor==m
            numerator=[a,b,c.get('y',0)][job]
            assert (q,rem)==divmod(numerator,m) and q < (1 << w) and 0<=rem<m
            if job==0: c['a']=rem;c['qa']=q;c['stage']='M1'
            elif job==1: c['b']=rem;c['qb']=q;c['stage']='M2'
            else:
                assert 1<=q<=n and 0<a<m
                c.update(n=q,b=rem,a=m,m=a,stage='T')
                coverage['euclidean_transform_certificates']+=1
            coverage['division_certificates']+=1
        elif kind=='Y':
            assert c['stage']=='Y' and 0<=a<m and 0<=b<m
            y=a*n+b;nonterminal=int(y>=m)
            assert values[1:]==[n,a,b,m,y,nonterminal] and y < (1 << (2*w))
            c['y']=y;c['stage']='D2' if nonterminal else 'O'
            coverage['nonterminal_y' if nonterminal else 'terminal_y']+=1
        elif kind=='O':
            assert idx not in outputs and c['stage']=='O'
            assert values[1:8]==list(row)
            latency,ms,ds,r=values[8:]
            assert r==c['r']==rounds(on,oa,ob,om)
            if on and om:
                assert c['s']==total and ms==4*r*w and ds==(3*r-1)*2*w
                assert latency==r*(10*w+8)-(2*w+1) and latency<=profile['latency_bound']
            else:
                assert (total,error)==(0,int(om==0)) and (latency,ms,ds,r)==(0,0,0,0)
            outputs.add(idx);coverage['latency_certificates']+=1
        else: raise AssertionError(('trace kind',kind))
    assert outputs==set(range(len(rows))) and probes==set(range(31))
    return dict(coverage),sha(path)


def check_observed(p, observed, certificates):
    assert observed['W']==p['w'] and observed['TAG']==p['t']
    assert observed['frames']==p['statistics']['frames'] and observed['queued']==observed['frames']-1
    assert observed['resets']==observed['fresh']==31
    assert observed['max_latency']==p['statistics']['max_latency']
    assert observed['states']==127 and observed['mul_jobs']==15
    assert observed['div_jobs']==(3 if p['w']==1 else 7) and observed['errors']==3
    assert observed['cycles']<=p['conservative_cycle_estimate']
    assert observed['output_holds']>=3*(observed['frames']+31)
    assert observed['source_holds']>=observed['queued']
    assert certificates['multiply_certificates']*p['w']==observed['mul_steps']
    assert certificates['division_certificates']*2*p['w']==observed['div_steps']
    assert certificates['round_invariant_certificates']==observed['rounds']
    assert certificates['latency_certificates']==observed['latency_checks']==observed['frames']+31
    assert certificates['reset_boundary_certificates']==31
    assert certificates['reset_aliases']==len(p['w1_alias_targets'])


def audit():
    plan=check_matrix();frozen=json.loads((ROOT/'SOURCE_FREEZE.json').read_text())
    receipt=json.loads((ROOT/'verification.json').read_text())
    assert frozen['matrix_sha256']==receipt['matrix_sha256']==sha(ROOT/'MATRIX_FREEZE.json')
    assert receipt['source_freeze_sha256']==sha(ROOT/'SOURCE_FREEZE.json')
    assert frozen['source_sha256']==receipt['source_sha256']==sources()
    assert frozen['commands']==[list(row) for row in child_commands(plan)]
    assert receipt['status']=='UNIT_SIM_PASS' and not receipt['terminal_timeout']
    assert [r['name'] for r in receipt['records']]==plan['children']
    assert len(receipt['records'])==19 and all(r['status']=='PASS' and r['elapsed_seconds']<20.5 for r in receipt['records'])
    assert len(receipt['profiles'])==6
    for p,observed in zip(plan['profiles'],receipt['profiles']):
        assert all(observed[k]==v for k,v in p.items())
        check_observed(p,observed['observed'],observed['certificates'])
    for relative in sources():
        raw=(ROOT/relative).read_bytes();raw.decode('utf-8')
        assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf'),relative
    print('OFFLINE_AUDIT_PASS',sha(ROOT/'MATRIX_FREEZE.json'),sha(ROOT/'SOURCE_FREEZE.json'),sha(ROOT/'verification.json'))


def run():
    plan=check_matrix();frozen=json.loads((ROOT/'SOURCE_FREEZE.json').read_text())
    assert frozen['matrix_sha256']==sha(ROOT/'MATRIX_FREEZE.json')
    assert frozen['source_sha256']==sources() and frozen['commands']==[list(row) for row in child_commands(plan)]
    assert not (ROOT/'verification.json').exists(),'never overwrite qualification receipt'
    tool_bin=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin'
    iv,vvp=tool_bin/'iverilog.exe',tool_bin/'vvp.exe'
    assert iv.is_file() and vvp.is_file()
    env=dict(os.environ);env['PATH']=str(tool_bin)+os.pathsep+str(tool_bin.parent/'lib')+os.pathsep+env.get('PATH','')
    receipt=dict(baseline=plan['baseline'],status='IN_PROGRESS',hardware='HW_UNVERIFIED',
                 matrix_sha256=sha(ROOT/'MATRIX_FREEZE.json'),source_freeze_sha256=sha(ROOT/'SOURCE_FREEZE.json'),
                 source_sha256=sources(),profiles=[],records=[],terminal_timeout=False)
    def save(): write_json(ROOT/'verification.json',receipt)
    def child(name,argv,reject):
        assert name==plan['children'][len(receipt['records'])]
        record=dict(name=name,argv=list(map(str,argv)),timeout_seconds=20);start=time.monotonic()
        try:
            result=subprocess.run(record['argv'],cwd=ROOT,env=env,capture_output=True,text=True,
                                  encoding='utf-8',errors='replace',timeout=20)
            record.update(exit_code=result.returncode,stdout=result.stdout,stderr=result.stderr)
            passed=(result.returncode!=0 and MARKER in result.stdout+result.stderr) if reject else result.returncode==0
            record['status']='PASS' if passed else 'FAIL'
        except subprocess.TimeoutExpired as exc:
            def decode(v): return v.decode('utf-8','replace') if isinstance(v,bytes) else v or ''
            record.update(exit_code=None,status='TIMEOUT',stdout=decode(exc.stdout),stderr=decode(exc.stderr))
            receipt['terminal_timeout']=True
        record['elapsed_seconds']=round(time.monotonic()-start,3)
        receipt['records'].append(record);save();print(name,record['status'],record['elapsed_seconds'],flush=True)
        if record['status']!='PASS': raise RuntimeError(name+' '+record['status'])
        return record
    temp_root=Path(tempfile.gettempdir()).resolve()
    tmp=Path(tempfile.mkdtemp(prefix='anscore_b22_floor_',dir=temp_root)).resolve()
    assert tmp.parent==temp_root and tmp.name.startswith('anscore_b22_floor_')
    try:
        for name,argv,reject in child_commands(plan,str(iv),str(vvp),str(tmp)):
            result=child(name,argv,reject)
            if name.endswith('_simulate'):
                p=next(p for p in plan['profiles'] if name==p['name']+'_simulate')
                summaries=[line for line in result['stdout'].splitlines() if line.startswith('PASS W=')]
                assert len(summaries)==1,'require unique PASS summary'
                observed={k:int(v,16 if k in ['states','mul_jobs','div_jobs','errors'] else 10)
                          for k,v in re.findall(r'(\w+)=([0-9a-f]+)',summaries[0])}
                certificates,trace_sha=validate_trace(p,tmp/(p['name']+'.trace'))
                check_observed(p,observed,certificates)
                receipt['profiles'].append(dict(p,observed=observed,certificates=certificates,trace_sha256=trace_sha));save()
        assert sources()==frozen['source_sha256']
        receipt['totals']={k:sum(p['observed'][k] for p in receipt['profiles'])
                           for k in ['frames','queued','resets','fresh','mul_steps','div_steps','rounds',
                                     'source_holds','output_holds','latency_checks']}
        receipt['status']='UNIT_SIM_PASS';save();audit()
        print('QUALIFIED',sha(ROOT/'verification.json'),receipt['totals'])
    except Exception as exc:
        receipt['status']='TIMEOUT_NOT_RUN' if receipt['terminal_timeout'] else 'FAIL';receipt['error']=str(exc)
        for name in plan['children'][len(receipt['records']):]: receipt['records'].append(dict(name=name,status='NOT_RUN'))
        save()
        archive_index=0
        while (ROOT/'failure_archive'/f'attempt_{archive_index:02d}').exists(): archive_index+=1
        archive=ROOT/'failure_archive'/f'attempt_{archive_index:02d}';archive.mkdir(parents=True)
        for relative in [*frozen['source_sha256'],'SOURCE_FREEZE.json','verification.json']:
            destination=archive/relative;destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(ROOT/relative,destination)
        for trace in tmp.glob('*.trace'): shutil.copyfile(trace,archive/trace.name)
        (archive/'NOT_RUN.txt').write_text('\n'.join(r['name'] for r in receipt['records'] if r['status']=='NOT_RUN')+'\n',encoding='utf-8',newline='\n')
        print('PRESERVED_FAILURE',archive,sha(ROOT/'verification.json'),flush=True)
        raise
    finally:
        assert tmp.parent==temp_root and tmp.name.startswith('anscore_b22_floor_')
        shutil.rmtree(tmp)


if __name__=='__main__':
    parser=argparse.ArgumentParser();group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--freeze-source',action='store_true');group.add_argument('--run',action='store_true')
    group.add_argument('--audit',action='store_true');args=parser.parse_args()
    if args.freeze_source: freeze_source()
    elif args.run: run()
    else: audit()
