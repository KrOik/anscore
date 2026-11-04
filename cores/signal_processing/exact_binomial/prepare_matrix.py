#!/usr/bin/env python3
"""Freeze the complete finite binomial matrix before original HDL exists."""
from collections import Counter
from functools import lru_cache
import hashlib
import json
import math
from pathlib import Path

ROOT=Path(__file__).resolve().parent
BASELINE='20e2db4aded8858ff63e132c2399fb416aa48ed0'
PROFILES=[(1,1),(2,3),(5,8),(16,8),(32,8),(64,32)]
NEGATIVES=[('n0',0,8),('n65',65,8),('t0',32,0),('t33',32,33)]
U64=(1<<64)-1
CHUNK=128


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


@lru_cache(None)
def coefficient(n,k):
    if k>n:return 0
    return math.factorial(n)//(math.factorial(k)*math.factorial(n-k))


def oracle(limit,n,k):
    if n>limit:return 0,1
    value=coefficient(n,k)
    if n<=10:
        assert value==sum(mask.bit_count()==k for mask in range(1<<n))
    return value,0


def schedule(limit,n,k):
    if n>limit or k>n or k==0 or k==n:return 0,0,0
    k=min(k,n-k)
    cells=k*n-k*(k-1)//2
    return n+k+3+3*cells,cells,k


def matrix(limit):
    values=[(n,k) for n in range(limit+1) for k in range(limit+2)]
    values += [(limit+1,0),(limit+1,limit+1),(limit+1,U64),
               (U64,0),(U64,1),(U64,U64),(0,U64),(limit,U64)]
    for bit in range(64):
        values += [(1<<bit,0),(1<<bit,U64),(limit,1<<bit),(0,1<<bit)]
    return list(dict.fromkeys(values))


def reset_targets():
    names=['idle','init_first','init_last','row_setup_first',
           'read_cur_first','read_prev_first','write_first',
           'read_cur_final_row_top','read_prev_final_row_top','write_final_row_top',
           'read_cur_last','read_prev_last','write_last','result_read','result_load',
           'held_computed','held_k0','held_k_gt_n','held_n_invalid','held_n0_k0',
           'held_n_invalid_priority','first_full_column_row','init_middle',
           'write_interior','first_computed']
    states=[0,1,1,2,3,4,5,3,4,5,3,4,5,6,7,8,8,8,8,8,8,2,1,5,8]
    return [dict(id=i,name=name,state=states[i]) for i,name in enumerate(names)]


def reset_rows(limit,t):
    result=[]
    for target in range(25):
        owner=(limit,limit//2)
        if target==16:owner=(limit,0)
        elif target==17:owner=(limit,limit+1)
        elif target==18:owner=(limit+1,0)
        elif target==19:owner=(0,0)
        elif target==20:owner=(limit+1,U64)
        fresh=(limit,limit//2)
        otag=((1<<(t-1))| (target*19+1))&((1<<t)-1)
        ftag=((1<<t)-1-target*7)&((1<<t)-1)
        result.append((target,*owner,otag,*oracle(limit,*owner),*fresh,ftag,*oracle(limit,*fresh)))
    return result


def write_main(relative,rows):
    path=ROOT/relative;path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text('\n'.join(f'{n:016x} {k:016x} {tag:08x} {v:016x} {e}' for n,k,tag,v,e in rows)+'\n',encoding='utf-8',newline='\n')
    return sha(path)


def write_reset(relative,rows):
    path=ROOT/relative;path.parent.mkdir(parents=True,exist_ok=True)
    lines=[]
    for target,n,k,tag,v,e,fn,fk,ft,fv,fe in rows:
        lines.append(f'{target} {n:016x} {k:016x} {tag:08x} {v:016x} {e} {fn:016x} {fk:016x} {ft:08x} {fv:016x} {fe}')
    path.write_text('\n'.join(lines)+'\n',encoding='utf-8',newline='\n')
    return sha(path)


def main():
    assert not (ROOT/'MATRIX_FREEZE.json').exists(),'immutable matrix exists'
    assert not list(ROOT.rglob('*.v')) and not list(ROOT.rglob('*.sv')),'matrix precedes any original HDL'
    profiles=[]
    for limit,t in PROFILES:
        name=f'n{limit}_t{t}';rows=[];stats=Counter();groups=[]
        for i,(n,k) in enumerate(matrix(limit)):
            tag=[0,(1<<t)-1,1<<(t-1),i*37+3][i%4]&((1<<t)-1)
            v,e=oracle(limit,n,k);latency,cells,half=schedule(limit,n,k)
            assert v<(1<<limit)
            rows.append((n,k,tag,v,e));stats['frames']+=1;stats['errors']+=e
            stats['extended_zero']+=n<=limit and k>n
            stats['n0_k0']+=n==0 and k==0;stats['cells']+=cells;stats['compute_cycles']+=latency
            stats['max_latency']=max(stats['max_latency'],latency);stats['max_value']=max(stats['max_value'],v)
        for first in range(0,len(rows),CHUNK):
            block=rows[first:first+CHUNK];relative=f'sim/fixtures/{name}_main_{first//CHUNK:02d}.txt'
            cycles=sum(schedule(limit,row[0],row[1])[0] for row in block)
            groups.append(dict(name=Path(relative).stem,path=relative,sha256=write_main(relative,block),
                               first=first,frames=len(block),compute_cycles=cycles,
                               conservative_cycle_estimate=cycles+12*len(block)+64))
        bound=schedule(limit,limit,limit//2)[0]
        reset_relative=f'sim/fixtures/{name}_reset.txt'
        alias=list(range(1,16))+list(range(21,25)) if limit==1 else ([22,23] if limit==2 else [])
        nw=max(1,limit.bit_length());kw=max(1,(limit//2).bit_length())
        profiles.append(dict(name=name,n=limit,t=t,statistics=dict(stats),groups=groups,
                             reset_fixture=reset_relative,reset_sha256=write_reset(reset_relative,reset_rows(limit,t)),
                             reset_probes=25,fresh_recoveries=25,reset_alias_targets=alias,
                             latency_bound=bound,reset_conservative_cycle_estimate=50*(bound+16)+128,
                             scalar_bits=3*limit+2*nw+2*kw+t+5,ram_bits=(limit//2+1)*limit))
    children=['version','core_syntax','example_syntax']
    for p in profiles:
        children+=[p['name']+'_compile']+[g['name']+'_simulate' for g in p['groups']]+[p['name']+'_reset_simulate']
    children+=['reject_'+x[0] for x in NEGATIVES]
    plan=dict(baseline=BASELINE,stage='COMPLETE_FINITE_MATRIX_BEFORE_ORIGINAL_HDL',timeout_seconds=20,
              profiles=profiles,negatives=NEGATIVES,children=children,reset_targets=reset_targets(),
              primary_oracle='exact factorial(N)//(factorial(K)*factorial(N-K)); full64 priority first; K>N zero',
              small_crosscheck='every legal N<=10 and K in each frozen row independently counted over all 2^N subset bitmaps',
              numeric_contract='N>MAX_N error1/value0 first; else K>N success0; K0 or K=N success1; N0K0 is1; no narrowing before checks',
              source_policy='next real frozen token held continuously through actual acceptance; every output field held at least three stalled edges',
              main_group_policy='immutable consecutive chunks of128 rows, fixed before HDL; no later split or shrink',
              input_order='hex16 N, hex16 K, hex8 TAG, hex16 VALUE, decimal ERROR',
              reset_order='decimal TARGET; five OWNER main fields; five FRESH main fields',
              reset_policy='immediate first observed requested boundary reset before next active edge; immediate ready/valid gate; cancel owner; complete held full-capacity fresh transaction and actual retirement',
              aliases='MAX_N1 all computation boundaries1..15/21..24 alias held valid endpoint result; MAX_N2 init_middle22 aliases init_last and write_interior23 aliases final write',
              schedule='9states; init k+1 words; N row setups; 3 edges per descending Pascal update; 2 final read/load edges',
              latency='special0; otherwise N+k+3+3*(k*N-k*(k-1)/2), k=min(K,N-K)',
              terminal_timeout='stop and preserve TIMEOUT/NOT_RUN; no retry/reduction/larger deadline',
              ordinary_failure='archive exact all sources, plan, receipt and NOT_RUN suffix; obtain root repair scope before edit',
              not_run=['synthesis','PnR','STA','board','inherited regression','expanded matrix'],
              upstream=dict(math_commit='529f3a759d83aa9437613666ea6293c9336d4069',source_bytes=2997,
                            source_sha256='a3ab37b3f0b14f76f66f7cabceed7299f2f7e75c08284238388489bad1ad9df5',
                            boost_commit='199ef13d6034c85232431130142159af3adfce22',license_bytes=1338,
                            license_sha256='c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566',
                            fixed_tag='boost-1.88.0',full_read_before_hdl=True,math_gitlink_verified=True),
              preparation_sha256=sha(Path(__file__)),attribute_sha256=sha(ROOT/'.gitattributes'))
    (ROOT/'MATRIX_FREEZE.json').write_text(json.dumps(plan,indent=2)+'\n',encoding='utf-8',newline='\n')
    print('MATRIX_FROZEN',sha(ROOT/'MATRIX_FREEZE.json'),'children',len(children))
    for p in profiles:print(p['name'],p['statistics'],'main_groups',len(p['groups']),'largest_estimate',max(g['conservative_cycle_estimate'] for g in p['groups']),'reset_estimate',p['reset_conservative_cycle_estimate'])


if __name__=='__main__':main()
