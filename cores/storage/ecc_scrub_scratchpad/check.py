#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite memory oracle and Icarus checks. No synthesis or external packages."""
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
PAYLOAD_POSITIONS=[p for p in range(1,39) if p & (p-1)]


def encode(data):
    bits=[0]*40
    for i,p in enumerate(PAYLOAD_POSITIONS): bits[p]=(data>>i)&1
    for p in [1,2,4,8,16,32]:
        bits[p]=sum(bits[q] for q in range(1,39) if q&p)%2
    bits[39]=sum(bits[1:39])%2
    return sum(bits[p]<<(p-1) for p in range(1,40))


def extract(code):
    return sum(((code>>(p-1))&1)<<i for i,p in enumerate(PAYLOAD_POSITIONS))


def decode(code):
    """Find a valid codeword in radius one, without syndrome decoding."""
    if encode(extract(code))==code: return 0,extract(code),code
    candidates=[code^(1<<b) for b in range(39)
                if encode(extract(code^(1<<b)))==code^(1<<b)]
    if not candidates: return 2,0,code
    assert len(candidates)==1
    return 1,extract(candidates[0]),candidates[0]


def vectors(depth,tag_w,pair_count):
    rng=random.Random(0x454343+depth)
    memory=[0]*depth
    commands=[];snapshots=[]
    coverage={'single_patterns':0,'double_patterns':0,'corrected_responses':0,
              'uncorrectable_responses':0,'invalid':0,'scrub':0,'reset_markers':0,'injected_words':0}
    responses=0

    def add(op,address=0,data=0,strobe=15,mask=0,tag_override=None):
        nonlocal responses
        status=result=corrected=uncorrectable=first=0
        tag=rng.getrandbits(tag_w)
        if tag_override is not None: tag=tag_override
        if op==4:
            assert address%4==0 and address//4<depth
            memory[address//4]^=mask;coverage['injected_words']+=1
        elif op==5:
            memory[:]=[0]*depth;coverage['reset_markers']+=1
        elif op==6:
            memory[:]=[v^mask for v in memory];coverage['injected_words']+=depth
        else:
            responses+=1
            if op==2:
                coverage['scrub']+=1
                for i,raw in enumerate(memory):
                    error,_,fixed=decode(raw)
                    if error==1: corrected+=1;memory[i]=fixed
                    elif error==2:
                        if uncorrectable==0: first=i*4
                        uncorrectable+=1
                status=2 if uncorrectable else 1 if corrected else 0
            elif op==3 or address%4 or address//4>=depth:
                status=3;coverage['invalid']+=1
            elif op==1 and strobe==0: pass
            elif op==1 and strobe==15: memory[address//4]=encode(data)
            else:
                index=address//4
                status,value,fixed=decode(memory[index])
                corrected=int(status==1);uncorrectable=int(status==2)
                first=address if uncorrectable else 0
                if status!=2:
                    if op==0:
                        result=value
                        memory[index]=fixed
                    else:
                        old=value.to_bytes(4,'little');new=data.to_bytes(4,'little')
                        merged=bytes(new[i] if strobe>>i&1 else old[i] for i in range(4))
                        memory[index]=encode(int.from_bytes(merged,'little'))
            if corrected: coverage['corrected_responses']+=1
            if uncorrectable: coverage['uncorrectable_responses']+=1
        commands.append(f'{op} {address:08x} {data:08x} {strobe:x} {tag:x} {mask:010x} '
                        f'{result:08x} {status} {corrected} {uncorrectable} {first:08x}\n')
        snapshots.extend(memory)

    add(0,0,tag_override=0);add(0,(depth-1)*4,tag_override=(1<<tag_w)-1)
    for a in [1,2,3,depth*4,0xfffffffc,0xffffffff]:
        add(0,a);add(1,a,0xabcdef01,0)
    add(3);add(2,3,0x12345678,0)
    for strobe in range(16): add(1,0,rng.getrandbits(32),strobe);add(0,0)
    # Every physical single-bit position, exercising read and partial-write repair.
    for bit in range(39):
        address=(bit%depth)*4
        add(1,address,rng.getrandbits(32))
        add(4,address,mask=1<<bit)
        if bit%2: add(1,address,rng.getrandbits(32),[1,2,4,8,5,10][bit%6])
        else: add(0,address)
        add(0,address)
        coverage['single_patterns']+=1
    pairs=list(itertools.combinations(range(39),2))
    chosen=pairs if pair_count==741 else rng.sample(pairs,pair_count)
    for a,b in chosen:
        address=((a*39+b)%depth)*4
        add(1,address,rng.getrandbits(32))
        add(4,address,mask=(1<<a)|(1<<b))
        add(0,address)
        add(1,address,rng.getrandbits(32),5)  # must reject without changing RAM
        add(1,address,rng.getrandbits(32),0)  # must not repair/detect
        add(2)
        add(1,address,rng.getrandbits(32))  # full overwrite restores validity
        add(0,address)
        coverage['double_patterns']+=1
    # Exact DEPTH-sized counters, including the extra count bit for powers of 2.
    add(5);add(6,mask=1<<38);add(2);add(2)
    add(6,mask=3);add(2);add(5)
    # Mixed sweep: clean/single/double words, lowest failing address, continue
    # beyond failures rather than terminating the scrub at its first bad word.
    for i in range(min(depth,12)):
        add(1,i*4,rng.getrandbits(32))
        if i%3==1: add(4,i*4,mask=1<<((i*7)%39))
        elif i%3==2: add(4,i*4,mask=3)
    add(2,0xffffffff);add(2)
    for i in range(min(depth,12)): add(1,i*4,0x19300000+i)
    for n in range(96):
        if n%23==0: add(2)
        else: add(rng.randrange(2),4*rng.randrange(depth),rng.getrandbits(32),rng.randrange(16))
    add(2)
    return ''.join(commands),snapshots,responses,coverage


def main():
    evidence=ROOT/'verification.json'
    evidence.unlink(missing_ok=True)
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite'
    env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    executables={n:os.environ.get(n.upper()) or shutil.which(n,path=env['PATH']) for n in ['iverilog','vvp']}
    report={'status':['NOT_RUN','HW_UNVERIFIED'],'checks':[],'profiles':[],
            'not_run':['synthesis','place_and_route','STA','hardware']}
    temporary=''

    def run(args,reject=False):
        result=subprocess.run([executables[args[0]],*args[1:]],cwd=ROOT,env=env,
                              capture_output=True,text=True,timeout=20)
        okay=(result.returncode!=0 and 'ecc_scrub_scratchpad_invalid_parameters' in result.stderr) if reject else result.returncode==0
        report['checks'].append({'command':args,'exit_code':result.returncode,'status':'PASS' if okay else 'FAIL',
                                'stdout':result.stdout.strip(),'stderr':result.stderr.strip(),'timeout_seconds':20})
        if not okay: raise RuntimeError(result.stdout+result.stderr)
        return result.stdout.strip()

    try:
        if not all(executables.values()): raise RuntimeError('NOT_RUN: Icarus/vvp required')
        report['tool']=run(['iverilog','-V']).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','ecc_scrub_scratchpad','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','ecc_ram256','-f','examples/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_ecc_scrub_scratchpad_') as temporary:
            path=Path(temporary)
            for depth,tw,pairs in [(1,1,12),(3,4,741),(16,8,64),(256,16,32),(4096,32,16)]:
                content,snapshots,responses,coverage=vectors(depth,tw,pairs)
                cases=len(content.splitlines())
                (path/'commands.txt').write_bytes(content.encode())
                (path/'expected.mem').write_bytes(''.join(f'{v:010x}\n' for v in snapshots).encode())
                image=path/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_ecc_scrub_scratchpad',
                     f'-Ptb_ecc_scrub_scratchpad.DEPTH={depth}',f'-Ptb_ecc_scrub_scratchpad.TAG_W={tw}',
                     f'-Ptb_ecc_scrub_scratchpad.CASES={cases}',f'-Ptb_ecc_scrub_scratchpad.RESPONSES={responses}',
                     '-o',str(image),'-f','files.f','sim/tb_ecc_scrub_scratchpad.sv'])
                output=run(['vvp',str(image),f'+COMMANDS={(path/"commands.txt").as_posix()}',
                            f'+EXPECTED={(path/"expected.mem").as_posix()}'])
                marker=f'PASS cases={cases} responses={responses} memory_codewords={cases*depth} reset_probes=8'
                if marker not in output: raise RuntimeError('simulation did not complete')
                report['profiles'].append({'DEPTH':depth,'TAG_W':tw,'cases':cases,'responses':responses,
                    'memory_codewords_compared':cases*depth,'coverage':coverage,
                    'vectors_sha256':hashlib.sha256(content.encode()).hexdigest(),
                    'memory_sha256':hashlib.sha256((path/'expected.mem').read_bytes()).hexdigest(),'result':output})
                print(output,flush=True)
            for parameter,value in [('DEPTH',0),('DEPTH',4097),('TAG_W',0),('TAG_W',33)]:
                run(['iverilog','-g2012','-tnull','-s','ecc_scrub_scratchpad',
                     f'-Pecc_scrub_scratchpad.{parameter}={value}','-f','files.f'],True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    except (RuntimeError,OSError,subprocess.TimeoutExpired) as exc:
        report['status']=['NOT_RUN_TIMEOUT' if isinstance(exc,subprocess.TimeoutExpired) else 'FAILED_OR_NOT_RUN','HW_UNVERIFIED']
        report['detail']=str(exc)
        raise
    finally:
        for check in report['checks']:
            check['command']=[a.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else a for a in check['command']]
        sources=['.gitattributes','SOURCES.md','README.md','files.f','rtl/ecc_scrub_scratchpad.sv',
                 'examples/files.f','examples/ecc_ram256.sv','check.py','sim/tb_ecc_scrub_scratchpad.sv']
        report['source_sha256']={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources}
        dependencies=['../../acceleration/stream_secded_encode/rtl/stream_secded_encode.sv',
                      '../../acceleration/stream_secded_decode/rtl/stream_secded_decode.sv']
        report['dependency_sha256']={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in dependencies}
        report['tools']=executables
        evidence.write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__': main()
