#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite independent-oracle integration checks, <=20 seconds per child."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
PROFILES=[(1,1,1),(5,4,13),(19,8,31),(256,16,64)]
INPUTS=['rtl/canonical_huffman_encoder.sv','sim/tb_canonical_huffman_encoder.sv',
        'example/huffman_frame_encoder.sv','files.f','example/files.f','run_checks.py',
        '../canonical_huffman_table/rtl/canonical_huffman_table.sv']

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def make_vectors(symbols,bits,capacity):
    staging=[0]*symbols
    active=None
    records=[]
    frames=0
    def cfg(op,symbol=0,length=0):
        nonlocal active
        status=code=width=0
        if op in (0,2) and symbol>=symbols: status=1
        elif op==0:
            if length>bits: status=2
            else: staging[symbol]=length
        elif op==1:
            counts=[staging.count(i) for i in range(bits+1)]
            space=1
            for i in range(1,bits+1):
                space=2*space-counts[i]
                if space<0: break
            if space<0 or counts[0]==symbols: status=3
            else:
                counts[0]=0; first=0; next_codes=[0]*(bits+1)
                for i in range(1,bits+1):
                    first=(first+counts[i-1])*2; next_codes[i]=first
                active={}
                for i,width_i in enumerate(staging):
                    if width_i:
                        active[i]=(next_codes[width_i],width_i)
                        next_codes[width_i]+=1
        elif op==2:
            if active is None: status=4
            elif symbol not in active: status=5
            else: code,width=active[symbol]
        else:
            staging[:]=[0]*symbols; active=None
        records.append(f'0 {op} {symbol} {length} {len(records)%256} {status} {code} {width} 0\n')
    def frame(data,count=None):
        nonlocal frames
        if count is None: count=len(data)
        status=error=0; bit_string=''
        if count>capacity: status=6
        else:
            for index,symbol in enumerate(data):
                if symbol>=symbols: status,error=1,index; break
                if active is None: status,error=4,index; break
                if symbol not in active: status,error=5,index; break
                code,width=active[symbol]
                bit_string+=format(code,f'0{width}b')
        if status: bit_string=''
        bytes_out=[]
        for index in range(0,len(bit_string),8):
            word=bit_string[index:index+8]
            bytes_out.append((int(word.ljust(8,'0'),2),len(word)))
        records.append(f'1 {count} {frames%256} {status} {error} {len(bit_string)} {len(data)} {len(bytes_out)} 0\n')
        records.extend(f'{symbol}\n' for symbol in data)
        records.extend(f'{value} {width}\n' for value,width in bytes_out)
        frames+=1

    frame([]); frame([],capacity+1); frame([],0xffffffff)
    frame([0]*min(3,capacity))  # no table, remaining input must drain
    cfg(0,0xffffffff,0); cfg(0,0,bits+1); cfg(1)
    cfg(0,0,bits); cfg(1); cfg(2,0)
    for n in sorted(set([1,min(2,capacity),min(3,capacity),capacity])): frame([0]*n)
    frame([0xffffffff] if capacity==1 else [0,0xffffffff]+[0]*(min(3,capacity)-2))
    if symbols>1: frame([symbols-1] if capacity==1 else [0,symbols-1]+[0]*(min(3,capacity)-2))
    cfg(3)
    # Complete trees include a comb reaching the all-ones MAX_BITS code.
    depths=list(range(1,bits))+[bits,bits] if symbols>=bits+1 else [1]
    if symbols==5: depths=[2,2,2,3,3]
    for symbol,width in enumerate(reversed(depths)): cfg(0,symbol,width)
    cfg(1)
    available=list(active)
    rng=random.Random(320000+symbols)
    for n in sorted(set([1,min(2,capacity),min(7,capacity),capacity])):
        frame([available[i%len(available)] for i in range(n)])
        frame([rng.choice(available) for _ in range(n)])
    frame([available[1] if len(available)>1 else available[0]]*capacity)
    # Staging changes are invisible until BUILD, including a failed BUILD.
    cfg(0,available[0],0); frame([available[0]])
    if symbols>=3:
        for symbol in range(symbols): cfg(0,symbol,1)
        cfg(1); frame([rng.choice(available) for _ in range(capacity)])
    cfg(3); frame([]); frame([0]*min(3,capacity))
    return ''.join(records),frames

def main():
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=ROOT/'reports'/stamp; out.mkdir(parents=True)
    work=ROOT/'.work'/stamp; work.mkdir(parents=True)
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite'
    suffix='.exe' if os.name=='nt' else ''
    tools={name:str(suite/'bin'/(name+suffix)) if (suite/'bin'/(name+suffix)).is_file()
           else (shutil.which(name) or name) for name in ('iverilog','vvp')}
    env=dict(os.environ); env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    report=dict(schema='anscore-b32-finite-checks-v1',status='INCOMPLETE',checks=[],profiles=[],
                source_sha256={p:digest(ROOT/p) for p in INPUTS},
                tools={name:dict(path=path,sha256=digest(Path(path))) for name,path in tools.items() if Path(path).is_file()},
                hard_seconds_per_child=20,hardware_status='HW_UNVERIFIED',
                synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN')
    stopped=False
    def save(): (out/'results.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    def run(name,argv):
        nonlocal stopped
        if stopped: return False
        started=time.monotonic(); record=dict(name=name,argv=list(map(str,argv)),cwd=str(ROOT))
        stdout=stderr=b''
        try:
            child=subprocess.Popen(argv,cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                   start_new_session=(os.name!='nt'))
            try:
                stdout,stderr=child.communicate(timeout=20)
                record.update(status='PASS' if child.returncode==0 else 'FAIL',returncode=child.returncode)
            except subprocess.TimeoutExpired as exc:
                stdout,stderr=exc.stdout or b'',exc.stderr or b''
                record.update(status='TIMEOUT',returncode=None)
                try:
                    if os.name=='nt':
                        killed=subprocess.run(['taskkill','/PID',str(child.pid),'/T','/F'],capture_output=True,timeout=5)
                        if killed.returncode and child.poll() is None: child.kill()
                    else:
                        import signal
                        os.killpg(child.pid,signal.SIGKILL)
                except (OSError,subprocess.SubprocessError) as cleanup:
                    stderr+=('\ncleanup: '+str(cleanup)).encode()
                    try: child.kill()
                    except OSError: pass
                try: stdout,stderr=child.communicate(timeout=2)
                except (OSError,subprocess.SubprocessError) as cleanup:
                    stderr+=('\npipe collection: '+str(cleanup)).encode()
        except OSError as exc: record.update(status='NOT_RUN',returncode=None); stderr=str(exc).encode()
        if name.startswith('sim_') and record['status']=='PASS' and b'PASS canonical_huffman_encoder' not in stdout:
            record['status']='FAIL_NO_MARKER'
        record.update(seconds=round(time.monotonic()-started,4),stdout_sha256=hashlib.sha256(stdout).hexdigest(),stderr_sha256=hashlib.sha256(stderr).hexdigest())
        (out/(name+'.stdout.txt')).write_bytes(stdout); (out/(name+'.stderr.txt')).write_bytes(stderr)
        report['checks'].append(record); save(); print(name,record['status'],flush=True)
        if record['status']!='PASS': stopped=True
        return record['status']=='PASS'

    run('syntax_default',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','canonical_huffman_encoder','-f','files.f'])
    run('syntax_max_frame',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','canonical_huffman_encoder','-Pcanonical_huffman_encoder.MAX_FRAME=1024','-Pcanonical_huffman_encoder.TAG_W=32','-f','files.f'])
    run('syntax_example',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','huffman_frame_encoder','-f','example/files.f'])
    for symbols,bits,capacity in PROFILES:
        if stopped: break
        data,frames=make_vectors(symbols,bits,capacity)
        label=f's{symbols}_b{bits}_f{capacity}'
        vectors=out/(label+'.txt'); vectors.write_text(data,encoding='ascii')
        report['profiles'].append(dict(symbols=symbols,max_bits=bits,max_frame=capacity,frames=frames,vectors=vectors.name,vector_sha256=digest(vectors)))
        image=work/(label+'.vvp')
        if run('compile_'+label,[tools['iverilog'],'-g2012','-Wall','-s','tb_canonical_huffman_encoder',
                    f'-Ptb_canonical_huffman_encoder.SYMBOLS={symbols}',f'-Ptb_canonical_huffman_encoder.MAX_BITS={bits}',
                    f'-Ptb_canonical_huffman_encoder.MAX_FRAME={capacity}','-o',str(image),'-f','files.f','sim/tb_canonical_huffman_encoder.sv']):
            if run('sim_'+label,[tools['vvp'],str(image),'+vectors='+vectors.as_posix()]): image.unlink()
    unchanged=all(digest(ROOT/p)==h for p,h in report['source_sha256'].items())
    report['sources_unchanged']=unchanged
    ok=not stopped and unchanged and len(report['checks'])==11
    report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'] if ok else ['RTL_CANDIDATE','HW_UNVERIFIED']
    save(); print('Evidence:',out.relative_to(ROOT).as_posix())
    return 0 if ok else 1

if __name__=='__main__': sys.exit(main())
