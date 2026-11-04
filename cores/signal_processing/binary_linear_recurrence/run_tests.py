#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen finite GF(2) linear-system oracle; native Icarus children <=20s."""
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent
BASELINE='01b92bf2f8d81fff097f1965de61edf81604ae4f'
PROFILES=[(1,1),(3,3),(5,8),(17,8),(64,8),(256,32)]
SOURCES=['.gitattributes','README.md','SOURCES.md','files.f','example/files.f',
    'example/recurrence64.sv','rtl/binary_linear_recurrence.sv','sim/tb_binary_linear_recurrence.sv','run_tests.py']
RESET_TARGETS=['idle_collect','masked_started_collect','first_discrepancy_read','first_discrepancy_eval',
    'update','finalize','prediction_read','prediction_eval','held_valid_blocked_source','discrepancy_jump',
    'discrepancy_nonjump','zero_discrepancy_update','middle_discrepancy_read','last_discrepancy_eval',
    'middle_prediction_read','last_prediction_eval','held_empty_error_blocked_source','overflow_drain',
    'partial_capture','held_overflow_error_blocked_source']


def minimum_connection(bits):
    """Solve finite recurrence equations at increasing candidate orders.

    Integer bitsets implement Gaussian elimination, independently of BM's
    discrepancy/connection/auxiliary updates. Return any solution and uniqueness.
    """
    prefix=[0]
    for bit in bits:prefix.append((prefix[-1]<<1)|bit)
    for order in range(len(bits)+1):
        mask=(1<<order)-1;basis={};consistent=True
        for t in range(order,len(bits)):
            row=(prefix[t]&mask)|(bits[t]<<order)
            while row&mask:
                pivot=(row&mask).bit_length()-1
                if pivot not in basis:basis[pivot]=row;break
                row^=basis[pivot]
            else:
                if row>>order:consistent=False;break
        if consistent:
            solution=0
            for pivot,row in sorted(basis.items()):
                value=(row>>order)^((row&mask&solution).bit_count()&1)
                solution|=value<<pivot
            connection=1|(solution<<1)
            assert all(bits[t]==sum(((connection>>i)&1)*bits[t-i] for i in range(1,order+1))%2
                for t in range(order,len(bits)))
            return order,connection,len(basis)==order
    raise AssertionError('order N always has a solution')


def fixtures(capacity,tag_w):
    rng=random.Random(0x424d474632+capacity*19+tag_w);frames=[]
    def kept(bits):frames.append([(bit,1) for bit in bits])
    frames.extend([[(1,0)],[(0,0),(1,0)]])
    for bits in [[0],[1],[0,0],[1,1],[1,0],[0,1],[1,0,1],[1,0,1,0]]:kept(bits)
    for bits in [[0]*capacity,[1]*capacity,[i%2 for i in range(capacity)]]:kept(bits)
    for position in sorted({0,capacity//2,capacity-1,max(0,capacity-2)}):
        kept([int(i==position) for i in range(capacity)])
    kept([1]*(capacity+2));kept([0]*(capacity+1))
    frames.append([(1,0)]+[(i%2,1) for i in range(capacity)]+[(1,0)])
    frames.append([(1,0),(1,1),(0,0),(0,1),(1,0)])
    for length in ([8] if capacity<=5 else ([9] if capacity==17 else [])):
        for n in range(1,length+1):
            for bits in itertools.product((0,1),repeat=n):kept(bits)
    for number in range(35):
        n=rng.randint(1,min(capacity,16));kept([rng.randrange(2) for _ in range(n)])
    for number in range(20):
        n=rng.randint(1,min(capacity+2,18));frames.append([(rng.randrange(2),int(rng.randrange(5)!=0)) for _ in range(n)])
    for order in [1,2,3,5,9]:
        if order>capacity:continue
        bits=[rng.randrange(2) for _ in range(order)];coefficients=[rng.randrange(2) for _ in range(order)]
        coefficients[-1]=1
        while len(bits)<capacity:bits.append(sum(c*bits[-i-1] for i,c in enumerate(coefficients))%2)
        kept(bits)
    coverage={key:0 for key in ['valid','empty','overflow','all_zero','all_one','full_capacity','masked_tail',
        'masked_first','unique_connection','nonunique_connection','order_equals_count','zero_order']}
    inputs=[];expected=[];records=[]
    for fi,frame in enumerate(frames):
        tag=(1<<tag_w)-1 if fi%11==0 else (0 if fi%11==1 else rng.getrandbits(tag_w))
        for j,(bit,keep) in enumerate(frame):
            inputs.append(f'{bit} {keep} {int(j==len(frame)-1)} {tag if j==0 else rng.getrandbits(tag_w):x}\n')
        all_kept=[bit for bit,keep in frame if keep];bits=all_kept[:capacity];count=len(bits)
        errors=int(count==0)|(int(len(all_kept)>capacity)<<1)
        coverage['empty']+=count==0;coverage['overflow']+=bool(errors&2)
        coverage['masked_tail']+=not frame[-1][1];coverage['masked_first']+=not frame[0][1]
        if errors:order=connection=0;unique=False;delay=1
        else:
            order,connection,unique=minimum_connection(bits);coverage['valid']+=1
            coverage['all_zero']+=not any(bits);coverage['all_one']+=all(bits)
            coverage['full_capacity']+=count==capacity;coverage['unique_connection']+=unique
            coverage['nonunique_connection']+=not unique;coverage['order_equals_count']+=order==count
            coverage['zero_order']+=order==0
            if frame[-1][1]:delay=2*minimum_connection(bits[:-1])[0]+2+2*order
            else:delay=1+2*order
        expected.append(f'{count} {order} {errors} {tag:x} {delay}\n')
        records.append(dict(bits=bits,count=count,order=order,errors=errors,tag=tag,delay=delay,
            unique=unique,connection=connection))
    assert all(coverage[key]>0 for key in ['valid','empty','overflow','all_zero','all_one','full_capacity',
        'masked_tail','masked_first','unique_connection','nonunique_connection','order_equals_count','zero_order'])
    assert {r['errors'] for r in records}=={0,1,2}
    return ''.join(inputs),''.join(expected),records,coverage


def check_trace(trace,records):
    lines=trace.splitlines();assert len(lines)==len(records)
    totals=dict(recurrence_equations=0,prediction_terms=0,unique_exact_checks=0,
        nonunique_valid_checks=0,trailing_zero_lag=0,coefficient_vectors=0)
    for fi,(line,record) in enumerate(zip(lines,records)):
        parts=line.split();assert len(parts)==8
        index,count,order=map(int,parts[:3]);connection=int(parts[3],16)
        next_bit,errors=map(int,parts[4:6]);tag=int(parts[6],16);delay=int(parts[7])
        assert (index,count,order,errors,tag,delay)==(fi,record['count'],record['order'],record['errors'],record['tag'],record['delay'])
        if errors:assert connection==next_bit==0;continue
        assert connection&1 and connection>>(order+1)==0 and next_bit in [0,1]
        bits=record['bits']
        for t in range(order,count):
            assert bits[t]==sum(((connection>>i)&1)*bits[t-i] for i in range(1,order+1))%2
            totals['recurrence_equations']+=1
        assert next_bit==sum(((connection>>i)&1)*bits[count-i] for i in range(1,order+1))%2
        totals['prediction_terms']+=order;totals['coefficient_vectors']+=1
        if record['unique']:assert connection==record['connection'];totals['unique_exact_checks']+=1
        else:totals['nonunique_valid_checks']+=1
        totals['trailing_zero_lag']+=order>0 and ((connection>>order)&1)==0
    return totals


def main():
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],matrix_status='NOT_RUN',checks=[],profiles=[],
        dependency_sha256={},oracle='Increasing-order GF(2) linear systems with integer-bitset Gaussian elimination; all emitted coefficients checked against all finite recurrence equations and next-bit parity',
        frozen_profiles=PROFILES,reset_targets=RESET_TARGETS,qualified_commands=19,
        not_run=['synthesis','PnR','STA','hardware','expanded_regression'],
        timeout_retry_policy='Stop on any 20-second compiler/simulator child timeout; no retry, fixture reduction or timeout increase.')
    path=ROOT/'verification.json'
    if path.is_file():
        old=json.loads(path.read_text(encoding='utf-8'))
        if old.get('matrix_status')=='INCOMPLETE_TIMEOUT':raise RuntimeError('Prior timeout is terminal; no rerun allowed.')
        report['prior_failed_attempts']=old.get('prior_failed_attempts',[])
        if 'FAILED_OR_NOT_RUN' in old.get('status',[]):report['prior_failed_attempts'].append(old)
    def save():path.write_bytes((json.dumps(report,indent=2)+'\n').encode('utf-8'))
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite'
    env=os.environ.copy();env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    exe={name:str(suite/'bin'/f'{name}.exe') for name in ['iverilog','vvp']};temporary=''
    def run(args,reject=False,version=False):
        try:r=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            decode=lambda x:x.decode('utf-8',errors='replace') if isinstance(x,bytes) else (x or '')
            report['checks'].append(dict(command=args,exit_code=None,status='TIMEOUT',stdout=decode(error.stdout),stderr=decode(error.stderr),timeout_seconds=20))
            report['matrix_status']='INCOMPLETE_TIMEOUT';raise
        okay=(r.returncode>0 and 'binary_linear_recurrence_invalid_parameters' in r.stderr) if reject else r.returncode==0 and not r.stderr
        if not reject and args[0]=='iverilog' and not version:okay=okay and not r.stdout
        report['checks'].append(dict(command=args,exit_code=r.returncode,status='PASS' if okay else 'FAIL',stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20))
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    try:
        plans=[]
        for capacity,tag_w in PROFILES:
            inputs,expected,records,coverage=fixtures(capacity,tag_w)
            digests={name:hashlib.sha256(data.encode()).hexdigest() for name,data in [('inputs.txt',inputs),('expected.txt',expected)]}
            plans.append((capacity,tag_w,inputs,expected,records,coverage,digests))
        report['frozen_fixture_plan']=[dict(MAX_BITS=m,TAG_W=t,frames=len(records),beats=len(inputs.splitlines()),sha256=digests)
            for m,t,inputs,expected,records,coverage,digests in plans]
        report['fixture_plan_sha256']=hashlib.sha256(json.dumps(report['frozen_fixture_plan'],sort_keys=True).encode()).hexdigest()
        for name in SOURCES:
            data=(ROOT/name).read_bytes();data.decode('utf-8',errors='strict')
            assert b'\r' not in data and data.endswith(b'\n') and not data.startswith(b'\xef\xbb\xbf'),name
        report['source_sha256']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES}
        save()
        if not all(Path(name).is_file() for name in exe.values()):raise RuntimeError('NOT_RUN native Icarus/vvp required')
        report['tool']=run(['iverilog','-V'],version=True).splitlines()[0]
        run(['iverilog','-g2012','-Wall','-tnull','-s','binary_linear_recurrence','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','recurrence64','-f','example/files.f'])
        with tempfile.TemporaryDirectory(prefix='anscore_binary_recurrence_') as temporary:
            folder=Path(temporary)
            for capacity,tag_w,inputs,expected,records,coverage,digests in plans:
                (folder/'inputs.txt').write_bytes(inputs.encode());(folder/'expected.txt').write_bytes(expected.encode())
                frames=len(records);beats=len(inputs.splitlines());image=folder/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_binary_linear_recurrence',f'-Ptb_binary_linear_recurrence.MAX_BITS={capacity}',
                    f'-Ptb_binary_linear_recurrence.TAG_W={tag_w}',f'-Ptb_binary_linear_recurrence.FRAMES={frames}',
                    f'-Ptb_binary_linear_recurrence.BEATS={beats}','-o',str(image),'-f','files.f','sim/tb_binary_linear_recurrence.sv'])
                output=run(['vvp',str(image),f'+INPUTS={(folder/"inputs.txt").as_posix()}',
                    f'+EXPECTED={(folder/"expected.txt").as_posix()}',f'+TRACE={(folder/"trace.txt").as_posix()}'])
                match=re.search(r'^PASS frames=(\d+) beats=(\d+) outputs=(\d+) latency_checks=(\d+) max_latency=(\d+) tap_checks=(\d+) prediction_checks=(\d+) held_cycles=(\d+) source_stalls=(\d+) reset_probes=(\d+) fresh_checks=(\d+)$',output,re.M)
                if not match:raise RuntimeError('missing complete finite PASS marker')
                values=list(map(int,match.groups()));assert values[:4]==[frames,beats,frames,frames]
                assert values[-2:]==[20,20] and values[7]>0 and values[8]>0
                trace=(folder/'trace.txt').read_bytes();totals=check_trace(trace.decode('ascii'),records)
                report['profiles'].append(dict(MAX_BITS=capacity,TAG_W=tag_w,frames=frames,beats=beats,coverage=coverage,
                    error_patterns=[0,1,2],vectors_sha256=digests,observed_trace_sha256=hashlib.sha256(trace).hexdigest(),
                    latency_checks=values[3],maximum_first_latency=values[4],tap_checks=values[5],prediction_checks=values[6],
                    held_cycles=values[7],source_stalls=values[8],reset_probes=20,fresh_checks=20,oracle_checks=totals,result=output))
                print(output,flush=True)
            for name,value in [('MAX_BITS',0),('MAX_BITS',257),('TAG_W',0),('TAG_W',33)]:
                run(['iverilog','-g2012','-tnull','-s','binary_linear_recurrence',f'-Pbinary_linear_recurrence.{name}={value}','-f','files.f'],reject=True)
        assert len(report['checks'])==19
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'];report['matrix_status']='PASS'
    except subprocess.TimeoutExpired as error:
        report['status']=['NOT_RUN','HW_UNVERIFIED'];report['detail']=str(error)+'; stopped without retry';raise
    except (AssertionError,RuntimeError,OSError) as error:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=repr(error);raise
    finally:
        for check in report['checks']:
            check['command']=[x.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') if temporary else x for x in check['command']]
        report['source_sha256']={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES if (ROOT/name).is_file()}
        report['license_sha256']={name:hashlib.sha256((ROOT.parents[2]/name).read_bytes()).hexdigest() for name in ['LICENSE','NOTICE']}
        report['tools']=exe;save()


if __name__=='__main__':main()
