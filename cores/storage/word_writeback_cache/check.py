#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded cache checks with a transaction-level independent Python oracle."""
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent
HIGH=0xfffffe00
HIGH_WORDS=128


def initial_word(address):
    return ((address*0x9e3779b1) ^ (address>>7) ^ 0x53a6c19d) & 0xffffffff


def vectors(lines, words, tag_w):
    """Whole blocks and byte arrays; no RTL state or cycle scheduling model."""
    rng=random.Random(0x43414348+lines*100+words)
    low_words=max(128,3*lines*words)
    addresses=[4*i for i in range(low_words)]+[HIGH+4*i for i in range(HIGH_WORDS)]
    memory={a:initial_word(a) for a in addresses}
    residents={}
    cmds=[]
    events=[]
    coverage={'hit':0,'miss':0,'writeback_error':0,'refill_error':0,'invalid':0,'flush':0,'reset':0,'zero_strobe':0}

    def add(op, address=0, data=0, strobe=15, fr=-1, fw=-1):
        tag=rng.getrandbits(tag_w)
        status=result=hit=0
        local=[]
        reads=writes=0

        def transfer(write, a, value=0):
            nonlocal reads,writes
            index=writes if write else reads
            error=index==(fw if write else fr) or a not in memory
            if write:
                writes+=1
                if not error: memory[a]=value
                response=0
            else:
                reads+=1
                response=memory.get(a,0) if not error else 0
            local.append((int(write),a,value if write else 0,int(error),response))
            return error,response

        def evict(slot):
            block, payload, dirty=residents[slot]
            if dirty:
                for i,value in enumerate(payload):
                    error,_=transfer(True,block+4*i,value)
                    if error: return False
            del residents[slot]
            return True

        if op==4:
            residents.clear()
            coverage['reset']+=1
        elif op==3 or (op!=2 and address%4):
            status=1;coverage['invalid']+=1
        elif op==1 and strobe==0:
            coverage['zero_strobe']+=1
        elif op==2:
            coverage['flush']+=1
            for slot in sorted(list(residents)):
                if not evict(slot): status=2;break
        else:
            block=address//(4*words)*(4*words)
            slot=(block//(4*words))%lines
            offset=(address-block)//4
            hit=int(slot in residents and residents[slot][0]==block)
            coverage['hit' if hit else 'miss']+=1
            if not hit:
                if slot in residents and not evict(slot): status=2
                if status==0:
                    payload=[]
                    for i in range(words):
                        error,value=transfer(False,block+4*i)
                        if error: status=3;break
                        payload.append(value)
                    if status==0: residents[slot]=[block,payload,False]
            if status==0:
                resident=residents[slot]
                if op==0: result=resident[1][offset]
                else:
                    before=resident[1][offset].to_bytes(4,'little')
                    after=data.to_bytes(4,'little')
                    resident[1][offset]=int.from_bytes(bytes(after[i] if strobe>>i&1 else before[i] for i in range(4)),'little')
                    resident[2]=True
        if status==2: coverage['writeback_error']+=1
        if status==3: coverage['refill_error']+=1
        cmds.append(f'{op} {address:08x} {data:08x} {strobe:x} {tag:x} {result:08x} {status} {hit} {len(local)}\n')
        events.extend(local)

    # Cold/hot reads, every byte mask, no-op and invalid operations.
    add(0);add(0)
    for strobe in range(16):
        add(1,0,rng.getrandbits(32),strobe);add(0,0)
    add(1,4*words,0x12345678,0)
    add(0,4*words)
    for address in [1,2,3,0xffffffff]: add(0,address);add(1,address,123)
    add(3);add(3,3)
    add(2,3)  # flush ignores all address/data/strobe fields
    # Dirty eviction failures preserve old cached data; retries are idempotent.
    conflict=4*lines*words
    for fail in sorted(set([0,words//2,words-1])):
        add(2);add(1,0,0xabe00000+fail)
        add(0,conflict,fw=fail)
        add(0,0)
        add(0,conflict)
        add(0,0)
    # Refill failures, including successful dirty writeback before refill error.
    for fail in sorted(set([0,words//2,words-1])):
        add(2);add(0,0,fr=fail);add(0,0)
        add(1,0,0xfeed0000+fail)
        add(1,conflict,0xabcdef01,5,fr=fail)
        add(0,0);add(0,conflict)
    # Full cache, indexed clean+dirty scan, partial flush progress and retry.
    for fail in sorted(set([0,words-1,min(lines*words-1,words+1)])):
        add(2)
        for slot in range(lines): add(1,slot*words*4,0x93000000+slot+fail)
        add(2,fw=fail)
        for slot in range(lines): add(0,slot*words*4)
        add(2);add(2)
    # Both ends of the unsigned byte address space and complete top line.
    for a in [HIGH,0xfffffffc,HIGH+4,0xfffffff8]:
        add(0,a);add(1,a,rng.getrandbits(32),7);add(0,a)
    add(2)
    # Finite mixed deterministic sequence; injected errors may be unused on hits.
    for n in range(240):
        if n%43==0: add(4)
        elif n%29==0: add(2,fw=rng.choice([-1,0,words-1]))
        else:
            address=rng.choice(addresses)
            add(rng.randrange(2),address,rng.getrandbits(32),rng.randrange(16),
                fr=rng.choice([-1,-1,-1,0,words-1]),fw=rng.choice([-1,-1,-1,0,words-1]))
    # Observe all cached low words, then commit all dirty lines to backend.
    for slot in range(lines): add(0,slot*words*4)
    add(2)
    event_text=''.join(f'{w} {a:08x} {d:08x} {e} {r:08x}\n' for w,a,d,e,r in events)
    return ''.join(cmds),event_text,[memory[a] for a in addresses],low_words,coverage


def main():
    report_path=ROOT/'verification.json'
    report_path.unlink(missing_ok=True)
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite'
    env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    executables={n:os.environ.get(n.upper()) or shutil.which(n,path=env['PATH']) for n in ['iverilog','vvp']}
    report={'status':['NOT_RUN','HW_UNVERIFIED'],'checks':[],'profiles':[],
            'not_run':['synthesis','place_and_route','STA','hardware']}
    temporary=''

    def run(args,reject=False):
        completed=subprocess.run([executables[args[0]],*args[1:]],cwd=ROOT,env=env,
                                 capture_output=True,text=True,timeout=20)
        okay=(completed.returncode!=0 and 'word_writeback_cache_invalid_parameters' in completed.stderr) if reject else completed.returncode==0
        report['checks'].append({'command':args,'exit_code':completed.returncode,'status':'PASS' if okay else 'FAIL',
                                 'stdout':completed.stdout.strip(),'stderr':completed.stderr.strip(),'timeout_seconds':20})
        if not okay: raise RuntimeError(completed.stdout+completed.stderr)
        return completed.stdout.strip()

    try:
        if not all(executables.values()): raise RuntimeError('NOT_RUN: Icarus and vvp required')
        report['tool']=run(['iverilog','-V']).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','word_writeback_cache','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','cache_scratchpad','-f','examples/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_word_writeback_cache_') as temporary:
            path=Path(temporary)
            for lines,words,tag_w in [(1,1,1),(2,2,4),(16,4,8),(4,8,16),(64,16,32)]:
                commands,events,expected,low_words,coverage=vectors(lines,words,tag_w)
                for name,content in [('commands.txt',commands),('events.txt',events),
                                     ('expected.mem',''.join(f'{v:08x}\n' for v in expected))]:
                    (path/name).write_bytes(content.encode())
                image=path/'unit.vvp'
                cases=len(commands.splitlines());event_count=len(events.splitlines())
                run(['iverilog','-g2012','-Wall','-s','tb_word_writeback_cache',
                     f'-Ptb_word_writeback_cache.LINES={lines}',f'-Ptb_word_writeback_cache.LINE_WORDS={words}',
                     f'-Ptb_word_writeback_cache.TAG_W={tag_w}',f'-Ptb_word_writeback_cache.CASES={cases}',
                     f'-Ptb_word_writeback_cache.LOW_WORDS={low_words}',f'-Ptb_word_writeback_cache.EVENTS={event_count}',
                     '-o',str(image),'-f','files.f','sim/tb_word_writeback_cache.sv'])
                output=run(['vvp',str(image),f'+COMMANDS={(path/"commands.txt").as_posix()}',
                            f'+EVENTS={(path/"events.txt").as_posix()}',f'+EXPECTED={(path/"expected.mem").as_posix()}'])
                if f'PASS cases={cases} backend_events={event_count} reset_probes=7' not in output:
                    raise RuntimeError('unit simulation did not complete')
                report['profiles'].append({'LINES':lines,'LINE_WORDS':words,'TAG_W':tag_w,'cases':cases,
                    'backend_events':event_count,'final_memory_words':len(expected),'coverage':coverage,
                    'vectors_sha256':hashlib.sha256((commands+events).encode()).hexdigest(),'result':output})
                print(output,flush=True)
            image=path/'integration.vvp'
            run(['iverilog','-g2012','-Wall','-s','tb_cache_scratchpad','-o',str(image),
                 '-f','examples/files.f','sim/tb_cache_scratchpad.sv'])
            output=run(['vvp',str(image)])
            if 'PASS integrated_cache' not in output: raise RuntimeError('integration simulation did not complete')
            print(output,flush=True)
            for parameter,value in [('LINES',0),('LINES',3),('LINES',128),('LINE_WORDS',0),
                                    ('LINE_WORDS',3),('LINE_WORDS',32),('TAG_W',0),('TAG_W',33)]:
                run(['iverilog','-g2012','-tnull','-s','word_writeback_cache',
                     f'-Pword_writeback_cache.{parameter}={value}','-f','files.f'],True)
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    except (RuntimeError,OSError,subprocess.TimeoutExpired) as exc:
        report['status']=['NOT_RUN_TIMEOUT' if isinstance(exc,subprocess.TimeoutExpired) else 'FAILED_OR_NOT_RUN','HW_UNVERIFIED']
        report['detail']=str(exc)
        raise
    finally:
        for check in report['checks']:
            check['command']=[a.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else a for a in check['command']]
        sources=['.gitattributes','README.md','SOURCES.md','rtl/word_writeback_cache.sv','files.f','examples/files.f','examples/cache_scratchpad.sv',
                 'sim/tb_word_writeback_cache.sv','sim/tb_cache_scratchpad.sv','check.py']
        report['source_sha256']={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources}
        report['dependency_sha256']={'../buffer_dma/rtl/mem_port_bram.v':hashlib.sha256((ROOT/'../buffer_dma/rtl/mem_port_bram.v').read_bytes()).hexdigest()}
        report['tools']=executables
        report_path.write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__': main()
