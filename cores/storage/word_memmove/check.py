#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent snapshot oracle and bounded RTL checks; no synthesis."""
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent
MEMORY_WORDS=128


def vectors(count_w,tag_w):
    rng=random.Random(0x4d4f5645+count_w*100+tag_w)
    limit=(1<<count_w)-1
    n=min(limit,15)
    descriptors=[]

    def add(src,dst,words,fr=-1,fw=-1,base=0):
        descriptors.append((src,dst,min(words,limit),fr,fw,base))

    for src,dst in [(0,128),(128,0),(0,4),(4,0),(40,48),(48,40),(32,32)]:
        add(src,dst,n)
    add(0xffffffff,3,0)
    add(1,4,1);add(4,3,1);add(1,1,1)
    add(0xfffffffc,0,min(limit,2));add(0,0xfffffffc,min(limit,2))
    add(0,4,limit);add(0,0,limit)
    for fr,fw in [(0,-1),(1,-1),(n-1,-1),(-1,0),(-1,1),(-1,n-1),(1,1)]:
        add(0,128,n,fr,fw)
        add(0,4,n,fr,fw)
        add(4,0,n,fr,fw)
    add(MEMORY_WORDS*4,0,1);add(0,MEMORY_WORDS*4,1)
    high=0xffffff00
    add(high,high+4,n,base=high)
    add(0xfffffffc,high,1,base=high)
    add(high,0xfffffffc,1,base=high)
    for _ in range(48):
        count=rng.randrange(min(32,limit)+1)
        add(rng.randrange(96)*4,rng.randrange(96)*4,count,
            rng.choice([-1,-1,rng.randrange(max(1,count))]),
            rng.choice([-1,-1,rng.randrange(max(1,count))]))
    initial=[];expected=[];commands=[];coverage={'backward':0,'read_error':0,'write_error':0,'invalid':0,'noop':0}
    for src,dst,count,fr,fw,base in descriptors:
        before=[rng.getrandbits(32) for _ in range(MEMORY_WORDS)]
        after=before[:]
        status=moved=backward=requests=0
        valid=lambda address:base<=address<base+4*MEMORY_WORDS and address<=0xffffffff
        if count==0:
            coverage['noop']+=1
        elif src%4 or dst%4 or src+4*(count-1)>0xffffffff or dst+4*(count-1)>0xffffffff:
            status=1;coverage['invalid']+=1
        elif src==dst:
            coverage['noop']+=1
        else:
            backward=int(src<dst<src+4*count)
            coverage['backward']+=backward
            # Snapshot source values define memmove independently of how the
            # RTL's subsequent reads interact with its own overlapping writes.
            for step in range(count):
                index=count-1-step if backward else step
                sa,da=src+index*4,dst+index*4
                requests+=1
                if not valid(sa) or step==fr:
                    status=2;coverage['read_error']+=1;break
                value=before[(sa-base)//4]
                requests+=1
                if not valid(da) or step==fw:
                    status=3;coverage['write_error']+=1;break
                after[(da-base)//4]=value;moved+=1
        tag=rng.getrandbits(tag_w)
        commands.append(f'{src:x} {dst:x} {count} {tag:x} {fr} {fw} {status} {moved} {backward} {requests} {base:x}\n')
        initial+=before;expected+=after
    return ''.join(commands),initial,expected,coverage


def main():
    report_path=ROOT/'verification.json'
    report_path.unlink(missing_ok=True)
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite'
    env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    tools={n:os.environ.get(n.upper()) or shutil.which(n,path=env['PATH']) for n in ('iverilog','vvp')}
    report={'status':['NOT_RUN','HW_UNVERIFIED'],'checks':[],'profiles':[],
            'not_run':['synthesis','place_and_route','STA','hardware']}
    temporary=''

    def run(args,reject=False):
        result=subprocess.run([tools[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        okay=(result.returncode!=0 and 'word_memmove_invalid_parameters' in result.stderr) if reject else result.returncode==0
        report['checks'].append({'command':args,'status':'PASS' if okay else 'FAIL','exit_code':result.returncode,
                                 'stdout':result.stdout.strip(),'stderr':result.stderr.strip(),'timeout_seconds':20})
        if not okay: raise RuntimeError(result.stdout+result.stderr)
        return result.stdout.strip()

    try:
        if not all(tools.values()):raise RuntimeError('NOT_RUN: Icarus and vvp required')
        report['tool']=run(['iverilog','-V']).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','word_memmove','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','memmove_scratchpad','-f','examples/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_word_memmove_') as temporary:
            path=Path(temporary)
            for count_w,tag_w in [(1,1),(4,4),(16,8),(24,32)]:
                content,initial,expected,coverage=vectors(count_w,tag_w)
                cases=len(content.splitlines())
                (path/'commands.txt').write_bytes(content.encode())
                for name,values in [('initial',initial),('expected',expected)]:
                    (path/(name+'.mem')).write_bytes(''.join(f'{v:08x}\n' for v in values).encode())
                image=path/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_word_memmove',
                     f'-Ptb_word_memmove.COUNT_W={count_w}',f'-Ptb_word_memmove.TAG_W={tag_w}',
                     f'-Ptb_word_memmove.CASES={cases}','-o',str(image),'-f','files.f','sim/tb_word_memmove.sv'])
                output=run(['vvp',str(image),f'+VECTORS={(path/"commands.txt").as_posix()}',
                            f'+INITIAL={(path/"initial.mem").as_posix()}',f'+EXPECTED={(path/"expected.mem").as_posix()}'])
                if f'PASS cases={cases} reset_cases=5 memory_words_checked={cases*MEMORY_WORDS}' not in output:
                    raise RuntimeError('unit simulation did not complete')
                report['profiles'].append({'COUNT_W':count_w,'TAG_W':tag_w,'cases':cases,'coverage':coverage,
                                           'vectors_sha256':hashlib.sha256(content.encode()).hexdigest(),'result':output})
                print(output,flush=True)
            image=path/'integration.vvp'
            run(['iverilog','-g2012','-Wall','-s','tb_memmove_scratchpad','-o',str(image),
                 '-f','examples/files.f','sim/tb_memmove_scratchpad.sv'])
            output=run(['vvp',str(image)])
            if 'PASS integrated_memmove overlap_words=15 host_readback_words=32 concurrent_host_reads=4' not in output:
                raise RuntimeError('connection test did not complete')
            print(output,flush=True)
            for parameter,value in [('COUNT_W',0),('COUNT_W',25),('TAG_W',0),('TAG_W',33)]:
                run(['iverilog','-g2012','-tnull','-s','word_memmove',f'-Pword_memmove.{parameter}={value}','-f','files.f'],True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    except (RuntimeError,OSError,subprocess.TimeoutExpired) as exc:
        report['status']=['NOT_RUN_TIMEOUT' if isinstance(exc,subprocess.TimeoutExpired) else 'FAILED_OR_NOT_RUN','HW_UNVERIFIED']
        report['detail']=str(exc)
        raise
    finally:
        for check in report['checks']:
            check['command']=[a.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else a for a in check['command']]
        files=['.gitattributes','files.f','rtl/word_memmove.sv','examples/files.f','examples/memmove_scratchpad.sv',
               'sim/tb_word_memmove.sv','sim/tb_memmove_scratchpad.sv','check.py']
        report['source_sha256']={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in files}
        report['dependency_sha256']={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest()
                                     for p in ['../buffer_dma/rtl/mem_port_arbiter4.v','../buffer_dma/rtl/mem_port_bram.v']}
        report['tools']=tools
        report_path.write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
