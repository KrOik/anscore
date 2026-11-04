#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Freeze complete stimuli and independent integer certificates before HDL."""
from functools import lru_cache
from hashlib import sha256
from itertools import permutations
from math import comb, factorial
from pathlib import Path
import json
import random

ROOT=Path(__file__).resolve().parent
BASELINE='b6af9a4c6b843924c6eb4d45b2fdf362dcc8b333'
PROFILES=[(1,1,32,2),(2,3,32,2),(3,8,64,2),(5,8,16,2),(8,8,8,2),(12,32,1,1)]
TARGETS=['capture_idle','capture_masked','capture_first_row','capture_full_before_last',
 'capture_overflow_before_last','init','mask_start_first','row_read_first','scan_first',
 'dp_read_first','dp_add_first','write_first','mask_start_final','row_read_final',
 'scan_final','dp_read_final','dp_add_final','write_final','result_read','result_load',
 'first_computed','held_computed','held_short','held_overflow','held_upstream',
 'held_short_upstream','held_overflow_upstream','scan_interior','write_interior',
 'read_zero_contribution','first_zero','held_zero']
NEGATIVES=[('n0',0,8),('n13',13,8),('t0',8,0),('t33',8,33)]

def encoded(obj):return (json.dumps(obj,indent=2,sort_keys=True)+'\n').encode()
def digest(raw):return sha256(raw).hexdigest()
def write(path,raw):
    p=ROOT/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(raw);return digest(raw)

def ryser(rows):
    """Integer inclusion/exclusion of column subsets; no assignment DP."""
    n=len(rows);answer=0
    for subset in range(1,1<<n):
        product=1
        for row in rows:product*=(row&subset).bit_count()
        answer+=(-1 if (n-subset.bit_count())&1 else 1)*product
    return answer

@lru_cache(None)
def certificates(rows):
    """Every prefix-minor permanent via Ryser subset Mobius transforms."""
    n=len(rows);depth=1<<n;counts=[1]*depth;gold=[0]*depth;gold[0]=1
    for size,row in enumerate(rows,1):
        counts=[v*(row&s).bit_count() for s,v in enumerate(counts)]
        transform=counts.copy()
        for bit in range(n):
            flag=1<<bit
            for subset in range(depth):
                if subset&flag:transform[subset]-=transform[subset^flag]
        for subset in range(depth):
            if subset.bit_count()==size:
                gold[subset]=transform[subset]
                assert 0<=gold[subset]<=factorial(size)
    assert gold[-1]==ryser(rows)
    return tuple(gold)

def frame(rows,n,t,serial,style=0,upstream=False):
    rng=random.Random(0xB24D00+serial*19+n*31+t)
    tag=(1<<t)-1 if serial%7==0 else (37*serial+5)&((1<<t)-1)
    tokens=[]
    def token(row,keep,last=0,error=0):
        tokens.append((row,keep,last,error,tag if not tokens else rng.randrange(1<<t)))
    if style&1:token(rng.randrange(1<<n),0,error=int(upstream))
    for i,row in enumerate(rows):
        if style&2 and i%2==0:token(rng.randrange(1<<n),0)
        token(row,1,error=int(upstream and not(style&1) and i==0))
    if not tokens or style&4:token(rng.randrange(1<<n),0,error=int(upstream))
    elif upstream and not rows:tokens[-1]=(*tokens[-1][:3],1,tokens[-1][4])
    last=list(tokens[-1]);last[2]=1;tokens[-1]=tuple(last)
    if upstream and not any(x[3] for x in tokens):
        x=list(tokens[-1]);x[3]=1;tokens[-1]=tuple(x)
    return tuple(tokens)

def describe(tokens,n,t):
    assert tokens and tokens[-1][2] and not any(x[2] for x in tokens[:-1])
    rows=tuple(x[0] for x in tokens if x[1]);error=(len(rows)<n)+2*(len(rows)>n)+4*any(x[3] for x in tokens)
    value=0 if error else ryser(rows)
    cross=0
    if not error and n<=5:
        independent=sum(all(rows[i]&(1<<j) for i,j in enumerate(order)) for order in permutations(range(n)))
        assert value==independent;cross=1
    e=0 if error else sum(row.bit_count()*comb(n-1,i) for i,row in enumerate(rows))
    latency=0 if error else 3+((1<<n)-1)*(n+3)+2*e
    gold=() if error else certificates(rows)
    return dict(tokens=tokens,value=value,error=int(error),rows=min(n,len(rows)),tag=tokens[0][4],
                latency=latency,reads=e,gold=gold,permutation_crosscheck=cross)

def main_cases(n,t):
    full=(1<<n)-1;matrices=[]
    if n<=3:
        matrices=[tuple((bits>>(r*n))&full for r in range(n)) for bits in range(1<<(n*n))]
    else:
        half=n//2
        matrices=[(0,)*n,(full,)*n,tuple(1<<i for i in range(n)),tuple(1<<(n-1-i) for i in range(n)),
          tuple(full^((1<<i)-1) for i in range(n)),tuple((1<<(i+1))-1 for i in range(n)),(1,)*n,
          tuple(0 if i==n//2 else full for i in range(n)),(full^1,)*n,
          tuple((1<<half)-1 if i<=half else full for i in range(n)),
          tuple(full^(1<<i) for i in range(n)),
          tuple((1<<half)-1 if i<half else full^((1<<half)-1) for i in range(n)),
          tuple((1<<i)|(1<<((i+1)%n)) for i in range(n))]
        matrices += [tuple(1<<((i+shift)%n) for i in range(n)) for shift in range(n)]
        rng=random.Random(0xB24000+131*n+t)
        for density in [1,2,3]:
            for _ in range(5):matrices.append(tuple(sum((rng.randrange(4)<density)<<j for j in range(n)) for _ in range(n)))
        source=matrices[-3];order=list(range(n));rng.shuffle(order)
        matrices += [tuple(source[i] for i in order),tuple(sum(((row>>order[j])&1)<<j for j in range(n)) for row in source),
                     tuple(sum(((source[r]>>c)&1)<<r for r in range(n)) for c in range(n))]
        matrices=list(dict.fromkeys(matrices))
    result=[frame(rows,n,t,i,i%8) for i,rows in enumerate(matrices)]
    serial=len(result)
    extras=[([],1,False),([],5,True)]
    extras += [([full]*k,7,False) for k in range(n)]
    extras += [([full]*(n+1),7,False),([full]*(n+4),3,False),([full]*n,7,True),
               ([full]*n,4,True),([full]*n,0,True),([full]*(n-1),7,True),([full]*(n+2),7,True),
               ([full]*n,7,False),([0]*n,7,False)]
    for rows,style,error in extras:
        result.append(frame(rows,n,t,serial,style,error));serial+=1
    return [describe(x,n,t) for x in result]

def case_text(case):
    header=[len(case['tokens']),case['value'],case['error'],case['rows'],case['tag'],case['latency'],case['reads'],len(case['gold'])]
    lines=[' '.join(map(str,header))]+[' '.join(map(str,x)) for x in case['tokens']]
    lines += [' '.join(map(str,case['gold'][i:i+16])) for i in range(0,len(case['gold']),16)]
    return lines

def reset_owner(target,n,t):
    full=(1<<n)-1;rows=[full]*n;style=5;error=False
    if target==0:return ()
    if target==4:rows=[full]*(n+2)
    if target in [22,25]:rows=[full]*(n-1)
    if target in [23,26]:rows=[full]*(n+1)
    if target in [24,25,26]:error=True
    if target==29 and n>1:rows=[1]*n
    if target in [30,31]:rows=[0]*n
    return frame(rows,n,t,10000+target,style,error)

def aliases(n):
    if n==1:return {'3':2,'12':6,'13':7,'14':8,'15':9,'16':10,'17':11,'27':8,'28':11,'29':9}
    if n==2:return {'28':17}
    return {}

def main():
    assert not (ROOT/'MATRIX_FREEZE.json').exists() and not list(ROOT.rglob('*.sv')) and not list(ROOT.rglob('*.v'))
    profiles=[];children=['version','core_syntax','example_syntax']
    for n,t,main_group,reset_group in PROFILES:
        name=f'n{n}_t{t}';cases=main_cases(n,t);groups=[];resets=[]
        children.append(name+'_compile')
        for pos in range(0,len(cases),main_group):
            part=cases[pos:pos+main_group];group=f'{name}_main_{len(groups):02d}';path=f'sim/fixtures/{group}.txt'
            raw=('\n'.join([str(len(part))]+[line for case in part for line in case_text(case)])+'\n').encode()
            groups.append(dict(name=group,path=path,sha256=write(path,raw),first=pos,frames=len(part),
               inputs=sum(len(c['tokens']) for c in part),dp_certificates=sum(len(c['gold']) for c in part),
               compute_cycles=sum(c['latency'] for c in part),conservative_cycle_limit=sum(c['latency']+len(c['tokens'])+16 for c in part)+128))
            children.append(group)
        fresh=describe(frame([((1<<n)-1)]*n,n,t,0,5),n,t);fp=f'sim/fixtures/{name}_fresh.txt'
        fraw=('\n'.join(['1']+case_text(fresh))+'\n').encode();fhash=write(fp,fraw)
        for pos in range(0,len(TARGETS),reset_group):
            ids=list(range(pos,min(pos+reset_group,len(TARGETS))));group=f'{name}_reset_{len(resets):02d}';path=f'sim/fixtures/{group}.txt'
            lines=[str(len(ids))]
            for target in ids:
                owner=reset_owner(target,n,t);lines.append(f'{target} {len(owner)}');lines += [' '.join(map(str,x)) for x in owner]
            raw=('\n'.join(lines)+'\n').encode();resets.append(dict(name=group,path=path,sha256=write(path,raw),targets=ids,
                conservative_cycle_limit=len(ids)*(2*fresh['latency']+8*n+128)+128));children.append(group)
        v=max(1,factorial(n).bit_length());i=max(1,(n-1).bit_length());c=n.bit_length()
        errors=sorted(set(x['error'] for x in cases));assert errors==[0,1,2,4,5,6]
        profiles.append(dict(name=name,n=n,t=t,value_width=v,scalar_bits=8+c+t+2*n+i+3*v,
          ram_bits=n*n+(1<<n)*v,latency_bound=fresh['latency'],main_frames=len(cases),main_inputs=sum(len(x['tokens']) for x in cases),
          main_dp_certificates=sum(len(x['gold']) for x in cases),main_reads=sum(x['reads'] for x in cases),
          permutation_crosschecks=sum(x['permutation_crosscheck'] for x in cases),error_values=errors,main_groups=groups,
          fresh_fixture=fp,fresh_sha256=fhash,reset_groups=resets,reset_probes=len(TARGETS),fresh_recoveries=len(TARGETS),
          reset_aliases=aliases(n),first_fresh_tag=fresh['tag']))
    children += ['reject_'+key for key,_,_ in NEGATIVES]
    matrix=dict(baseline=BASELINE,stage='COMPLETE_INPUTS_ORACLES_SPLITS_BEFORE_ORIGINAL_HDL',timeout_seconds=20,
      profiles=profiles,children=children,negatives=NEGATIVES,reset_targets=[dict(id=i,name=x) for i,x in enumerate(TARGETS)],
      numeric_contract='fixed N1..12; kept row ordinal r, bit j is column j; exactly N kept rows; first accepted tag; mask ignores data only; LAST always frames; error bit0 short, bit1 overflow, bit2 upstream, all sticky independent; rows saturates N; any error value0; otherwise exact count in [0,N!]',
      oracle='Integer Ryser column-subset inclusion/exclusion; every DP prefix minor certified via independent Ryser Mobius transforms; N<=5 explicit complete permutation crosscheck; no upstream execution',
      schedule='11 states CAPTURE0 INIT1 MASK_START2 ROW_READ3 SCAN4 DP_READ5 DP_ADD6 WRITE7 RESULT_READ8 RESULT_LOAD9 OUTPUT10; per mask two setup+N scan+one write+two edges per eligible predecessor',
      latency='error0; otherwise 3+(2^N-1)*(N+3)+2*E, E=sum(row_ones[i]*choose(N-1,i)); all-ones attains bound; tail edge is0; single owner until response retirement; next accept following edge',
      resources='V=max(1,ceil(log2(N!+1))), I=max(1,ceil(log2 N)), C=ceil(log2(N+1)); scalar8+C+T+2N+I+3V includes both read-q; RAM N*N+2^N*V; default87/4160 max159/118928; no data multiply/divide/modulo/DSP',
      reset_policy='first post-edge observation then immediate reset without another active edge; ready/valid gates immediate; all32 targets/profile; every cancellation completes full-capacity all-ones fresh with every field held and actually retired; declared small-N aliases only',
      terminal_timeout='TIMEOUT terminal, no retry/reduction/extension',ordinary_failure='archive every original source/plan/receipt/NOT_RUN before root-authorized repair',
      not_run=['synthesis','PnR','STA','board','inherited regression','expanded matrix'],
      upstream=dict(repository='sympy/sympy',tag='sympy-1.14.0',tag_object='2f9c274d2021b5a43de627f703d3a8f8955a1038',commit='16fa855354eb7bcabd3fe10993841e03b1382692',
        source_path='sympy/matrices/determinant.py',source_bytes=34550,source_sha256='a434c36022c1496268bff8ff07e6591dda87dfe590feec2165ac2b5f710313d9',
        license_path='LICENSE',license_bytes=7885,license_sha256='07a5e9819f727b4986ad2829c7a29a6320d42575f720eb24d71b7fef573a0286',complete_source_and_license_read=True,imported_or_executed=False),
      preparation_sha256=digest(Path(__file__).read_bytes()),attribute_sha256=digest((ROOT/'.gitattributes').read_bytes()))
    raw=encoded(matrix);write('MATRIX_FREEZE.json',raw)
    print('FROZEN_BEFORE_RTL',digest(raw),'profiles',len(profiles),'children',len(children),'main',sum(p['main_frames'] for p in profiles),'resets',sum(p['reset_probes'] for p in profiles),flush=True)

if __name__=='__main__':main()
