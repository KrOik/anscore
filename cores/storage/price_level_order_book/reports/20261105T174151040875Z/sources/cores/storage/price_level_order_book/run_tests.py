#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite model-based L2 book checks. No synthesis/hardware/network or retry."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import signal
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
PROFILES={'min':(1,1,1,1),'small':(5,9,7,8),'default':(16,32,32,8),'max':(32,32,32,32)}
INPUTS=['run_tests.py','files.f','example/files.f','rtl/price_level_order_book.sv',
        'sim/tb_price_level_order_book.sv','example/market_depth16.sv',
        '../ram_ordered_dictionary/rtl/ram_ordered_dictionary.sv',
        '../../system/common_scaffold/memory/src/cip_sync_sp_ram.v']


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def vectors(levels,pw,qw,tw):
    """Independent reference: two plain dictionaries and sorted key lists."""
    books=[{},{}]
    pmax=(1<<pw)-1;qmax=(1<<qw)-1;tmax=(1<<tw)-1
    rows=[];count=0
    def command(op,side=0,price=0,quantity=0,rank=0):
        nonlocal count
        price &= pmax;quantity &= qmax
        book=books[side]
        before=book.get(price,0);found=int(price in book)
        status=0;rp=rq=previous=rf=0
        if op>7: status=7
        elif op<=2 and quantity==0: status=3
        elif op==5 and rank>=levels: status=6
        elif op<=3:
            if op in (2,3) and not found: status=1
            elif op==2 and quantity>before: status=5
            elif op==1 and before+quantity>qmax: status=4
            elif op in (0,1) and not found and len(book)==levels: status=2
            else:
                rq=quantity if op==0 else before+quantity if op==1 else before-quantity if op==2 else 0
                if rq: book[price]=rq
                else: del book[price]
                rf=found;rp=price;previous=before
        elif op in (4,5):
            order=sorted(book,reverse=(side==0));wanted=0 if op==4 else rank
            if wanted>=len(order): status=1
            else: rp=order[wanted];rq=book[rp];rf=1
        elif op==6: book.clear()
        elif op==7: books[0].clear();books[1].clear()
        tag=(0xfedc0000+count*17+3)&tmax
        rows.append([0,op,side,price,quantity,rank,tag,status,rf,rp,rq,previous,len(books[0]),len(books[1])])
        count+=1
    def reset(kind):
        rows.append([kind]+[0]*13);books[0].clear();books[1].clear()
    for side in (0,1):
        command(4,side);command(5,side,rank=0)
        command(5,side,rank=levels);command(5,side,rank=0xffffffff)
        command(3,side);command(8,side);command(15,side)
        for op in (0,1,2): command(op,side,quantity=0)
    pool=[0,pmax]
    for price in range(levels+2):
        value=(price*7+3)&pmax
        if value not in pool: pool.append(value)
    pool=pool[:levels]
    for side in (0,1):
        for price in reversed(pool): command(0,side,price,min(3,qmax))
        missing=next(p for p in range(levels+2) if p not in books[side])
        command(0,side,missing,1);command(1,side,missing,1)
        command(0,side,pool[0],qmax);command(1,side,pool[0],1)
        for rank in range(levels): command(5,side,rank=rank)
        command(0,side,pool[0],1)
        if qmax>1: command(2,side,pool[0],qmax)
        command(2,side,pool[0],1);command(2,side,pool[0],1)
        command(1,side,pool[0],1);command(3,side,pool[0]);command(4,side)
    command(6,0);command(4,0);command(4,1)
    command(7,1);command(0,0,pmax,1);command(0,1,0,1)
    command(4,0);command(4,1) # crossed book is retained, not matched
    rng=random.Random(330000+levels)
    for _ in range(50):
        side=rng.randrange(2);op=rng.choice([0,1,1,2,3,4,5,6,7])
        price=rng.choice(pool+[pmax,rng.randrange(pmax+1)])
        qty=rng.choice([0,1,min(2,qmax),qmax])
        command(op,side,price,qty,rng.choice([0,max(0,levels-1),levels,0xffffffff]))
    reset(1);command(4,0);command(4,1)
    command(0,0,0,1);command(0,1,pmax,1)
    reset(2);command(4,0);command(4,1)
    command(1,0,pmax,1);command(1,1,0,1)
    reset(3);command(4,0);command(4,1)
    command(1,0,pmax,qmax);command(2,0,pmax,qmax);command(3,0,pmax)
    command(7,1);command(5,1,rank=0)
    return ''.join(' '.join(map(str,row))+'\n' for row in rows),count


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
        source=(ROOT/name).resolve();destination=out/'sources'/source.relative_to(REPO)
        destination.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,destination)
        copies[name]=destination.relative_to(out).as_posix()
    report={'schema':'anscore-b33-finite-v1','utc':stamp,'source_sha256':hashes,'source_copies':copies,
            'tool_sha256':{str(p):sha(p) for p in (iv,vv) if p.is_file()},'records':[],
            'hard_seconds_per_child':20,'bounded_cleanup_seconds_per_step':5,'automatic_retry':False,
            'hardware':'HW_UNVERIFIED','synthesis':'NOT_RUN','pnr':'NOT_RUN','sta':'NOT_RUN','board':'NOT_RUN','profiles':[]}
    plan=[]
    if options.profile is None:
        plan=[('lint_default',[iv,'-g2012','-Wall','-tnull','-s','price_level_order_book','-f','files.f']),
              ('lint_max',[iv,'-g2012','-Wall','-tnull','-s','price_level_order_book',
                           '-Pprice_level_order_book.LEVELS=32','-Pprice_level_order_book.TAG_W=32','-f','files.f']),
              ('lint_example',[iv,'-g2012','-Wall','-tnull','-s','market_depth16','-f','example/files.f'])]
    profiles={options.profile:PROFILES[options.profile]} if options.profile else PROFILES
    for label,(levels,pw,qw,tw) in profiles.items():
        data,count=vectors(levels,pw,qw,tw)
        vector=out/(label+'.txt');vector.write_text(data,encoding='ascii')
        report['profiles'].append({'name':label,'parameters':[levels,pw,qw,tw],'commands':count,'vectors':vector.name,'vector_sha256':sha(vector)})
        image=build/(label+'.vvp')
        plan += [('compile_'+label,[iv,'-g2012','-Wall','-s','tb_price_level_order_book',
                  f'-Ptb_price_level_order_book.LEVELS={levels}',f'-Ptb_price_level_order_book.PRICE_W={pw}',
                  f'-Ptb_price_level_order_book.QTY_W={qw}',f'-Ptb_price_level_order_book.TAG_W={tw}',
                  '-o',image,'-f','files.f','sim/tb_price_level_order_book.sv']),
                 ('sim_'+label,[vv,image,'+vectors='+vector.as_posix()])]
    stopped='missing tool: '+','.join(str(p) for p in (iv,vv) if not p.is_file()) if not (iv.is_file() and vv.is_file()) else None
    for name,argv in plan:
        began=time.monotonic()
        if stopped: record,stdout,stderr={'status':'NOT_RUN','reason':stopped},b'',b''
        else: record,stdout,stderr=child(argv,env)
        if record['status']=='PASS' and name.startswith('sim_') and b'PASS price_level_order_book' not in stdout:
            record.update(status='FAIL',reason='missing required TB completion marker')
        if record['status']!='PASS' and stopped is None: stopped=name+' '+record['status']+'; remaining children not launched'
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


if __name__=='__main__': sys.exit(main())
