#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite independent-memory oracle and bounded Icarus checks, no synthesis."""
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent


def vectors(width,depth,tag_width):
    rng=random.Random(0x41544f4d+width*1000+depth)
    mask=(1<<width)-1
    cells=[0]*depth
    lines=[]
    counts=[0]*16
    successful_cas=failed_cas=0

    def signed(value):
        return value-(1<<width) if value>>(width-1) else value

    def command(op,addr,arg=0,compare=0):
        nonlocal successful_cas,failed_cas
        arg&=mask;compare&=mask
        tag=rng.getrandbits(tag_width)
        old=wrote=status=0
        if op>10:
            status=2
        elif addr>=depth:
            status=1
        else:
            old=cells[addr]
            result=old
            if op==1: result=arg
            elif op==2: result=(old+arg)&mask
            elif op==3: result=old^arg
            elif op==4: result=old&arg
            elif op==5: result=old|arg
            elif op==6: result=min((old,arg),key=signed)
            elif op==7: result=max((old,arg),key=signed)
            elif op==8: result=min(old,arg)
            elif op==9: result=max(old,arg)
            elif op==10:
                if old==compare: result=arg;successful_cas+=1
                else: failed_cas+=1
            wrote=int(op!=0 and (op!=10 or old==compare))
            if wrote: cells[addr]=result
        counts[op]+=1
        lines.append(f'{op} {addr} {arg:x} {compare:x} {tag:x} {old:x} {wrote} {status}\n')

    for addr in range(depth): command(0,addr)
    # Independently initialize/check every location to expose address aliasing.
    for addr in range(depth): command(1,addr,(addr*0x193+7)&mask)
    for addr in range(depth): command(0,addr)
    extremes=[0,1,mask,1<<(width-1),(1<<(width-1))-1]
    for op in range(11):
        for i,old in enumerate(extremes+extremes[::-1]):
            addr=(op*7+i)%depth
            arg=extremes[(i+2)%len(extremes)]
            command(1,addr,old)
            command(op,addr,arg,old if i%2==0 else old^mask)
            command(0,addr)
    max_addr=(1<<max(1,(depth-1).bit_length()))-1
    if max_addr>=depth:
        for op in range(11): command(op,max_addr,mask,mask)
    command(15,max_addr,1,1)
    for _ in range(300):
        op=rng.randrange(16);addr=rng.randrange(max_addr+1)
        compare=cells[addr] if addr<depth and rng.randrange(2) else rng.getrandbits(width)
        command(op,addr,rng.getrandbits(width),compare)
        if addr<depth: command(0,addr)
    for addr in range(depth): command(0,addr)
    assert successful_cas and failed_cas
    return ''.join(lines),{'commands':len(lines),'opcode_counts':counts,
                           'successful_cas':successful_cas,'failed_cas':failed_cas}


def main():
    report_path=ROOT/'verification.json'
    report_path.unlink(missing_ok=True)
    env=os.environ.copy()
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite'
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    tools={name:os.environ.get(name.upper()) or shutil.which(name,path=env['PATH']) for name in ('iverilog','vvp')}
    commands,cases=[],[]
    report={'status':['NOT_RUN','HW_UNVERIFIED'],'commands':commands,'cases':cases,
            'not_run':['synthesis','place_and_route','STA','hardware']}
    temporary=''

    def run(args,reject=False):
        result=subprocess.run([tools[args[0]],*args[1:]],cwd=ROOT,env=env,text=True,capture_output=True,timeout=20)
        okay=(result.returncode!=0 and 'atomic_scratchpad_invalid_parameters' in result.stderr) if reject else result.returncode==0
        commands.append({'command':args,'status':'PASS' if okay else 'FAIL','exit_code':result.returncode,
                         'stdout':result.stdout.strip(),'stderr':result.stderr.strip(),'timeout_seconds':20})
        if not okay: raise RuntimeError(result.stdout+result.stderr)
        return result.stdout.strip()

    try:
        if not all(tools.values()): raise RuntimeError('NOT_RUN: Icarus and vvp required')
        report['tool']=run(['iverilog','-V']).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','atomic_scratchpad','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','atomic_counter_bank','-f','files.f','examples/atomic_counter_bank.sv'])
        with tempfile.TemporaryDirectory(prefix='anscore_atomic_scratchpad_') as temporary:
            for width,depth,tag_width in [(2,1,1),(8,3,4),(32,16,8),(64,257,32)]:
                content,coverage=vectors(width,depth,tag_width)
                path=Path(temporary);vec=path/'vectors.txt';image=path/'test.vvp'
                vec.write_bytes(content.encode('ascii'))
                run(['iverilog','-g2012','-Wall','-s','tb_atomic_scratchpad',
                     f'-Ptb_atomic_scratchpad.DATA_W={width}',f'-Ptb_atomic_scratchpad.DEPTH={depth}',
                     f'-Ptb_atomic_scratchpad.TAG_W={tag_width}','-o',str(image),'-f','files.f','sim/tb_atomic_scratchpad.sv'])
                output=run(['vvp',str(image),f'+VECTORS={vec.as_posix()}'])
                if f'PASS commands={coverage["commands"]} reset_cases=5 full_clear_words={depth}' not in output:
                    raise RuntimeError('unit simulation missing completion marker')
                cases.append({'parameters':{'DATA_W':width,'DEPTH':depth,'TAG_W':tag_width},'status':'PASS',
                              'coverage':coverage,'result':output,'vectors_sha256':hashlib.sha256(content.encode()).hexdigest()})
                print(output,flush=True)
            run(['iverilog','-g2012','-Wall','-tnull','-s','atomic_scratchpad','-Patomic_scratchpad.DATA_W=64',
                 '-Patomic_scratchpad.DEPTH=4096','-Patomic_scratchpad.TAG_W=32','-f','files.f'])
            for parameter,value in [('DATA_W',1),('DEPTH',0),('DEPTH',4097),('TAG_W',33)]:
                run(['iverilog','-g2012','-tnull','-s','atomic_scratchpad',f'-Patomic_scratchpad.{parameter}={value}','-f','files.f'],True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED']
    except (RuntimeError,subprocess.TimeoutExpired,OSError) as exc:
        report['status']=['NOT_RUN_TIMEOUT' if isinstance(exc,subprocess.TimeoutExpired) else 'FAILED_OR_NOT_RUN','HW_UNVERIFIED']
        report['detail']=str(exc)
        raise
    finally:
        for item in commands:
            item['command']=[a.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else a for a in item['command']]
        files=['.gitattributes','files.f','rtl/atomic_scratchpad.sv','examples/atomic_counter_bank.sv','sim/tb_atomic_scratchpad.sv','check.py']
        report['source_sha256']={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in files}
        report['tools']=tools
        report_path.write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__': main()
