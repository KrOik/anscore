#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded dictionary-oracle tests and source-hashed Icarus evidence."""
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent


def folded_hash(key,slots):
    if slots==1: return 0
    width=(slots-1).bit_length();mask=slots-1;result=0
    while key:
        result^=key&mask;key>>=width
    return result


def vectors(slots,key_w,value_w,tag_w):
    rng=random.Random(0x48415348+slots*100+key_w+value_w)
    key_mask=(1<<key_w)-1;value_mask=(1<<value_w)-1
    mapping={};commands=[];snapshots=[]
    coverage={'get':0,'put_new':0,'put_replace':0,'delete':0,'not_found':0,'full':0,'clear':0,'reset':0}
    responses=0

    def add(op,key=0,value=0,tag_override=None):
        nonlocal responses
        key&=key_mask;value&=value_mask
        tag=rng.getrandbits(tag_w) if tag_override is None else tag_override
        status=found=inserted=old=0
        if op==4: mapping.clear();coverage['reset']+=1
        else:
            responses+=1
            if op==3: mapping.clear();coverage['clear']+=1
            else:
                found=int(key in mapping);old=mapping.get(key,0)
                if op==0:
                    coverage['get']+=1
                    if not found:status=1;coverage['not_found']+=1
                elif op==1:
                    if found:mapping[key]=value;coverage['put_replace']+=1
                    elif len(mapping)==slots:status=2;coverage['full']+=1
                    else:mapping[key]=value;inserted=1;coverage['put_new']+=1
                else:
                    if found:del mapping[key];coverage['delete']+=1
                    else:status=1;coverage['not_found']+=1
        commands.append(f'{op} {key:x} {value:x} {tag:x} {status} {found} {inserted} {old:x} '
                        f'{len(mapping)} {folded_hash(key,slots)}\n')
        ordered=sorted(mapping.items())
        snapshots.extend([(k<<value_w)|v for k,v in ordered]+[0]*(slots-len(ordered)))

    def missing():
        for key in range(slots+2):
            if key<=key_mask and key not in mapping:return key
        raise AssertionError('fixtures require more key encodings than slots')

    # Build a wraparound collision cluster using the documented hash, while
    # keeping the functional oracle independent of slot/probe placement.
    iw=max(1,(slots-1).bit_length())
    colliders=[];seen=set()
    for i in range(4096):
        key=((i<<iw)^i^(slots-1))&key_mask
        if key not in seen and folded_hash(key,slots)==slots-1:
            colliders.append(key);seen.add(key)
        if len(colliders)>=slots+2:break
    if len(colliders)<slots:
        colliders.extend(k for k in range(slots+1) if k<=key_mask and k not in seen)
    keys=colliders[:slots]
    assert len(keys)==slots and len(set(keys))==slots
    add(0,0,tag_override=0);add(2,key_mask,tag_override=(1<<tag_w)-1)
    add(1,0,0);add(1,0,value_mask);add(0,0);add(2,0);add(0,0);add(3)
    for key in keys:add(1,key,rng.getrandbits(value_w))
    for key in reversed(keys):add(0,key)
    add(1,missing(),123)  # full must never evict a different key
    add(1,keys[-1],0);add(0,keys[-1])  # replacement succeeds while full
    add(2,keys[-1])
    last_candidate=next((k for k in colliders[slots:] if k not in mapping),missing())
    add(1,last_candidate,value_mask)  # current final-probe tombstone candidate
    add(3)
    for key in keys:add(1,key,rng.getrandbits(value_w))
    add(2,keys[0])
    if slots>1:add(1,keys[-1],value_mask)  # find existing key beyond first tombstone
    for key in keys[1:]:add(0,key)
    for key in list(mapping):add(2,key)
    add(0,missing());add(2,missing())  # no EMPTY slot remains, only tombstones
    add(1,missing(),0);add(3);add(3)
    # Zero/all-one keys and values, including high key bits and count wrap edge.
    for key in [0,key_mask,1,key_mask^1]:
        add(1,key,value_mask);add(0,key);add(1,key,0);add(2,key)
    add(4)
    if slots==1 and key_w==1:
        choices=[(0,0,0),(0,1,0),(1,0,0),(1,0,1),(1,1,0),(1,1,1),(2,0,0),(2,1,0),(3,0,0)]
        for sequence in itertools.product(choices,repeat=3):
            add(3)
            for op,key,value in sequence:add(op,key,value)
    # Finite mixed persistent traffic, with bursts that exceed capacity.
    for n in range(420):
        if n%97==0:add(4)
        elif n%83==0:add(3)
        else:
            key=rng.choice(keys) if n%3 else rng.getrandbits(key_w)
            add(rng.choices([0,1,2],[3,5,2])[0],key,rng.getrandbits(value_w))
    # Check every retained binding before clearing, then check absent keys.
    for key in sorted(mapping):add(0,key)
    add(3)
    for key in keys:add(0,key)
    return ''.join(commands),snapshots,responses,coverage,len(colliders)


def main():
    evidence=ROOT/'verification.json';evidence.unlink(missing_ok=True)
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite'
    env=os.environ.copy();env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    executables={n:os.environ.get(n.upper()) or shutil.which(n,path=env['PATH']) for n in ['iverilog','vvp']}
    report={'status':['NOT_RUN','HW_UNVERIFIED'],'checks':[],'profiles':[],
            'not_run':['synthesis','place_and_route','STA','hardware']}
    temporary=''

    def run(args,reject=False):
        result=subprocess.run([executables[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        okay=(result.returncode!=0 and 'ram_hash_table_invalid_parameters' in result.stderr) if reject else result.returncode==0
        report['checks'].append({'command':args,'exit_code':result.returncode,'status':'PASS' if okay else 'FAIL',
                                'stdout':result.stdout.strip(),'stderr':result.stderr.strip(),'timeout_seconds':20})
        if not okay:raise RuntimeError(result.stdout+result.stderr)
        return result.stdout.strip()

    try:
        if not all(executables.values()):raise RuntimeError('NOT_RUN: Icarus/vvp required')
        report['tool']=run(['iverilog','-V']).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','ram_hash_table','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','resource_directory32','-f','examples/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_ram_hash_table_') as temporary:
            path=Path(temporary)
            for slots,kw,vw,tw in [(1,1,1,1),(4,4,5,3),(16,16,8,8),(32,32,32,8),(256,64,64,32)]:
                content,snapshots,responses,coverage,colliders=vectors(slots,kw,vw,tw)
                cases=len(content.splitlines());hex_digits=(kw+vw+3)//4
                (path/'commands.txt').write_bytes(content.encode())
                (path/'expected.mem').write_bytes(''.join(f'{v:0{hex_digits}x}\n' for v in snapshots).encode())
                image=path/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_ram_hash_table',f'-Ptb_ram_hash_table.SLOTS={slots}',
                     f'-Ptb_ram_hash_table.KEY_W={kw}',f'-Ptb_ram_hash_table.VALUE_W={vw}',f'-Ptb_ram_hash_table.TAG_W={tw}',
                     f'-Ptb_ram_hash_table.CASES={cases}',f'-Ptb_ram_hash_table.RESPONSES={responses}',
                     '-o',str(image),'-f','files.f','sim/tb_ram_hash_table.sv'])
                output=run(['vvp',str(image),f'+COMMANDS={(path/"commands.txt").as_posix()}',
                            f'+EXPECTED={(path/"expected.mem").as_posix()}'])
                marker=f'PASS cases={cases} responses={responses} dictionary_checks={cases} reset_probes=7'
                if marker not in output:raise RuntimeError('unit simulation did not complete')
                report['profiles'].append({'SLOTS':slots,'KEY_W':kw,'VALUE_W':vw,'TAG_W':tw,'cases':cases,
                    'responses':responses,'collision_fixture_keys':colliders,'coverage':coverage,
                    'vectors_sha256':hashlib.sha256(content.encode()).hexdigest(),
                    'dictionary_sha256':hashlib.sha256((path/'expected.mem').read_bytes()).hexdigest(),'result':output})
                print(output,flush=True)
            for parameter,value in [('SLOTS',0),('SLOTS',3),('SLOTS',512),('KEY_W',0),('KEY_W',65),
                                    ('VALUE_W',0),('VALUE_W',65),('TAG_W',0),('TAG_W',33)]:
                run(['iverilog','-g2012','-tnull','-s','ram_hash_table',f'-Pram_hash_table.{parameter}={value}','-f','files.f'],True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    except (RuntimeError,OSError,subprocess.TimeoutExpired) as exc:
        report['status']=['NOT_RUN_TIMEOUT' if isinstance(exc,subprocess.TimeoutExpired) else 'FAILED_OR_NOT_RUN','HW_UNVERIFIED']
        report['detail']=str(exc);raise
    finally:
        for check in report['checks']:
            check['command']=[a.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else a for a in check['command']]
        sources=['.gitattributes','README.md','SOURCES.md','files.f','rtl/ram_hash_table.sv','examples/files.f',
                 'examples/resource_directory32.sv','sim/tb_ram_hash_table.sv','check.py']
        report['source_sha256']={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources}
        report['tools']=executables
        evidence.write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
