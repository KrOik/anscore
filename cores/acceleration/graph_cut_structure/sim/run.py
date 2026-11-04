#!/usr/bin/env python3
"""Finite cut-structure checks with independent deletion/component oracle."""
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parents[2]
BASELINE='c778301aa12d1b9bf4290b1a982f4c6325713fcd'

def components(n,edges,removed=None):
    """Merge explicit disjoint Python sets, with the removed vertex absent."""
    groups=[{i} for i in range(n) if i!=removed]
    for a,b in edges:
        if removed in (a,b):continue
        ga=next(g for g in groups if a in g);gb=next(g for g in groups if b in g)
        if ga is not gb:ga.update(gb);groups.remove(gb)
    return sorted(groups,key=min)

def reference(n,edges):
    groups=components(n,edges);c=len(groups);labels={v:i for i,g in enumerate(groups) for v in g}
    after=[len(components(n,edges,i)) for i in range(n)]
    bridges={edge for edge in edges if len(components(n,edges-{edge}))>c}
    return [{'node':i,'component':labels[i],'components':c,'after':after[i],
             'degree':sum(i in e for e in edges),'bridge_count':len(bridges),'cut':int(after[i]>c),
             'bridges':sum(1<< (b if a==i else a) for a,b in bridges if i in (a,b))} for i in range(n)]

def fixtures(n):
    frames=[];pairs=list(itertools.combinations(range(n),2))
    def add(edges):frames.append(edges or [(0xffffffff,0xffffffff,1,0)])
    def simple(edges):return [(a,b,1,1) for a,b in edges]
    add([]);add(simple(pairs));add(simple((i,i+1) for i in range(n-1)))
    add(simple((0,i) for i in range(1,n)))
    add(simple({tuple(sorted((i,(i+1)%n))) for i in range(n) if n>1}))
    add(simple((i,i+1) for i in range(0,n-1,2)))
    add([(i,i,1,1) for i in range(n)])
    chain=simple((i,i+1) for i in range(n-1))
    if n>1:
        add(chain+[(1,0,0,1)]);add(chain+[(1,0,0,1),(0,1,1,1)])
    if n<=4:
        for bits in range(1<<len(pairs)):
            add(simple(p for k,p in enumerate(pairs) if bits>>k&1))
    rng=random.Random(20261111+n)
    for k in range(12):
        edges=[e for e in pairs if rng.randrange(4)<(k%3+1)]
        raw=simple(edges);rng.shuffle(raw);add([(n,0xffffffff,1,0)]+raw)
        if k<4:
            replay=simple((b,a) for a,b in edges);rng.shuffle(replay);add(replay)
    add([(n,0,1,1)]);add([(0,0xffffffff,0,1)]);add(chain+[(0xffffffff,0xffffffff,1,1)])
    return frames

def pack(fields):
    value=0
    for datum,width in fields:
        assert 0<=datum<1<<width,(datum,width)
        value=(value<<width)|datum
    return f'{value:x}'

def vectors(n,t):
    inputs=[];refs=[]
    for index,raw in enumerate(fixtures(n)):
        edges=set();bad=False;tag=(index*19+7)&((1<<t)-1)
        for k,(a,b,present,keep) in enumerate(raw):
            if keep:
                if a>=n or b>=n:bad=True
                elif a!=b:
                    edge=tuple(sorted((a,b)))
                    if present:edges.add(edge)
                    else:edges.discard(edge)
            inputs.append(pack([(a,32),(b,32),(present,1),(keep,1),(int(k==len(raw)-1),1),
                                (tag if k==0 else tag^((1<<t)-1),t)]))
        refs.append({'bad':bad,'tag':tag,'edges':sorted(edges),'expected':[] if bad else reference(n,edges)})
    return inputs,refs

def verify(path,refs,n,t):
    iw=max(1,(n-1).bit_length());cw=n.bit_length()
    fields=[('keep',1),('last',1),('error',1),('tag',t),('node',iw),('component',iw),('components',cw),
            ('after',cw),('degree',cw),('bridge_count',cw),('cut',1),('bridges',n)]
    actual=[]
    for line in path.read_text().splitlines():
        bits=int(line,16);row={}
        for key,width in reversed(fields):row[key]=bits&((1<<width)-1);bits>>=width
        assert bits==0;actual.append(row)
    cursor=0;replay={};replays=0;cutnodes=bridgegraphs=0
    for ref in refs:
        count=1 if ref['bad'] else n;chunk=actual[cursor:cursor+count];cursor+=count;assert len(chunk)==count
        for k,row in enumerate(chunk):
            expected={key:0 for key,width in fields}
            expected.update(keep=int(not ref['bad']),last=int(k==count-1),error=int(ref['bad']),tag=ref['tag'])
            if not ref['bad']:expected.update(ref['expected'][k])
            assert row==expected,(ref,k,row,expected)
        if not ref['bad']:
            expected=ref['expected'];masks=[r['bridges'] for r in chunk]
            assert all((masks[i]>>j&1)==(masks[j]>>i&1) for i in range(n) for j in range(n))
            assert sum(x.bit_count() for x in masks)==2*chunk[0]['bridge_count']
            assert all(r['cut']==(r['after']>r['components']) for r in chunk)
            solution=tuple(tuple(r[key] for key,width in fields if key!='tag') for r in chunk)
            key=tuple(tuple(e) for e in ref['edges'])
            if key in replay:assert replay[key]==solution;replays+=1
            replay[key]=solution;cutnodes+=sum(r['cut'] for r in chunk);bridgegraphs+=bool(chunk[0]['bridge_count'])
    assert cursor==len(actual)
    return {'deterministic_replays':replays,'cut_vertices_checked':cutnodes,'graphs_with_bridges':bridgegraphs,
            'actual_sha256':hashlib.sha256(path.read_bytes()).hexdigest()}

def main():
    (ROOT/'verification.json').write_text(json.dumps({'status':['NOT_RUN','HW_UNVERIFIED']})+'\n',encoding='utf-8',newline='\n')
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    commands=[];profiles=[]
    def run(cmd,cwd,negative=False):
        p=subprocess.run([str(x) for x in cmd],cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        record={'argv':[str(x) for x in cmd],'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'timeout_seconds':20}
        commands.append(record)
        if negative:assert p.returncode>0 and 'graph_cut_structure_invalid_parameters__see_README' in p.stderr,record
        else:assert p.returncode==0 and not p.stderr,record
        return p.stdout
    run([iv,'-V'],ROOT)
    run([iv,'-g2012','-Wall','-tnull','-s','graph_cut_structure','-s','graph_resilience16','-f','files.f','examples/graph_resilience16.sv'],ROOT)
    with tempfile.TemporaryDirectory(prefix='anscore_cutgraph_') as tmp:
        target=Path(tmp)
        for n,t in [(1,1),(2,3),(4,8),(7,8),(16,8),(64,32)]:
            inputs,refs=vectors(n,t);assert len(inputs)<=100001
            data=('\n'.join(inputs)+'\n').encode();(target/'input.hex').write_bytes(data)
            run([iv,'-g2012','-Wall','-s','tb_graph_cut_structure',f'-Ptb_graph_cut_structure.N={n}',
                 f'-Ptb_graph_cut_structure.T={t}','-o','sim.vvp',ROOT/'rtl/graph_cut_structure.sv',ROOT/'sim/tb_graph_cut_structure.sv'],target)
            outcount=sum(1 if r['bad'] else n for r in refs)
            output=run([vv,'sim.vvp',f'+INPUT={target/"input.hex"}',f'+OUTPUT={target/"actual.hex"}',
                        f'+COUNT={len(inputs)}',f'+OUTCOUNT={outcount}'],target)
            cov=re.search(r'PASS cutgraph records=(\d+) blocked=(\d+) held=(\d+) resets=(\d+) max_latency=(\d+) bound=(\d+)',output);assert cov,output
            assert int(cov[1])==outcount and int(cov[2])>0 and int(cov[3])>0 and int(cov[4])==(15 if n==1 else 17)
            profiles.append({'NUM_NODES':n,'TAG_W':t,'status':'PASS','frames':len(refs),'input_tokens':len(inputs),
                             'output_tokens':outcount,'bad_frames':sum(r['bad'] for r in refs),'reset_probes':int(cov[4]),
                             'blocked_cycles':int(cov[2]),'held_cycles':int(cov[3]),'maximum_checked_first_latency':int(cov[5]),
                             'conservative_first_bound':int(cov[6]),'output':output.strip(),
                             'input_sha256':hashlib.sha256(data).hexdigest(),**verify(target/'actual.hex',refs,n,t)})
            print(f'PASS cutgraph N={n} frames={len(refs)}',flush=True)
        invalid=[('NUM_NODES',0),('NUM_NODES',65),('TAG_W',0),('TAG_W',33)]
        for key,value in invalid:
            run([iv,'-g2012','-tnull','-s','graph_cut_structure',f'-Pgraph_cut_structure.{key}={value}','-f','files.f'],ROOT,True)
    files=['.gitattributes','files.f','rtl/graph_cut_structure.sv','examples/graph_resilience16.sv','sim/tb_graph_cut_structure.sv','sim/run.py']
    for f in files:
        raw=(ROOT/f).read_bytes();raw.decode('utf-8',errors='strict');assert b'\r' not in raw
    report={'baseline_commit':BASELINE,'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
            'oracle':'independent set-union components for original graph and each vertex/edge deletion; no DFS/lowlink recurrence',
            'profiles':profiles,'commands':commands,'invalid_parameter_rejections':len(invalid),
            'frames':sum(p['frames'] for p in profiles),'output_tokens':sum(p['output_tokens'] for p in profiles),
            'reset_probes':sum(p['reset_probes'] for p in profiles),
            'source_sha256':{f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in files},
            'not_run':['synthesis','PnR','STA','hardware','expanded regression']}
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(f'PASS cutgraph profiles={len(profiles)} frames={report["frames"]} commands={len(commands)}')
if __name__=='__main__':main()
