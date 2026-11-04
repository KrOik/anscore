#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded finite label-graph checks, using independent cell-side intersections."""
from __future__ import annotations
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

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
BASELINE='807d992b6b0e793c08ceba2d44993d21c1dd1583'
PROFILES=((1,1,1,1,1),(1,7,2,3,3),(7,1,3,3,8),(2,2,2,3,2),
          (3,3,2,2,3),(64,64,4,15,8),(1024,1,8,63,32),(1,1024,8,63,32))


def oracle(labels,w,h,maximum,errors):
    """XOR each region's unit-cell boundaries, then intersect region edge sets.

    This is independent of the RTL's left/up traversal, pair addressing and RAM
    recurrence. A disconnected occurrence of one ID is still the same region.
    """
    if errors:return [],(errors,0,0,0,0)
    boundaries={}
    for index,label in enumerate(labels):
        assert 0<=label<=maximum
        if label==0:continue
        x,y=index%w,index//w
        boundary=boundaries.setdefault(label,set())
        for side in (((x,y),(x+1,y)),((x,y+1),(x+1,y+1)),
                     ((x,y),(x,y+1)),((x+1,y),(x+1,y+1))):
            boundary.symmetric_difference_update((side,))
    edges=[]
    for a,b in itertools.combinations(sorted(boundaries),2):
        count=len(boundaries[a]&boundaries[b])
        if count:edges.append((a,b,count))
    total=sum(c for a,b,c in edges)
    assert total<=w*(h-1)+(w-1)*h
    return edges,(0,len(boundaries),sum(label!=0 for label in labels),len(edges),total)


def fixtures(w,h,l,k):
    n=w*h;rng=random.Random(20261109+w*31+h*101+k)
    frames=[]
    def add(values,fault=0):frames.append((list(values),fault))
    add([0]*n);add([1]*n);add([k]*n)
    add([1+(i%k) for i in range(n)])
    add([1+((i%w)%k) for i in range(n)])
    add([1+((i//w)%k) for i in range(n)])
    add([(1 if (i%w+i//w)%2 else k) for i in range(n)])
    add([(0 if (i%w+i//w)%2 else k) for i in range(n)])
    add([(1 if i==0 else k if i==n-1 else 0) for i in range(n)])
    add([(1 if i%w in (0,w-1) or i//w in (0,h-1) else k) for i in range(n)])
    if (w,h)==(2,2):
        for labels in itertools.product(range(k+1),repeat=n):add(labels)
    if (w,h)==(3,3):
        for mask in range(1<<n):add([1+((mask>>i)&1) for i in range(n)])
    for _ in range(6):add([rng.randrange(k+1) for i in range(n)])
    add([1]*n,1);add([k]*n,2);add([0]*n,3)
    if k<(1<<l)-1:
        bad=[1]*n;bad[-1]=k+1;add(bad,4)
        bad=[k]*n;bad[0]=(1<<l)-1;add(bad,5)
        bad=[0]*n;bad[n//2]=k+1;add(bad,6)
    return frames


def make_vectors(w,h,l,k,t):
    n=w*h;a=n.bit_length();s=(2*n).bit_length();v=k.bit_length()
    e=max(1,(k*(k-1)//2).bit_length());table=k*k
    records=[];frames=fixtures(w,h,l,k);edge_count=0;tokens=0;error_patterns=set();empty=0
    def lit(value,width):return f"{width}'h{value:x}"
    for fi,(labels,fault) in enumerate(frames):
        tag=(fi*37+3)&((1<<t)-1);errors=0
        for i,label in enumerate(labels):
            sof=i==0;eol=i%w==w-1
            if (fault==1 and i==n//2) or (fault==5 and i==0):sof=not sof
            if fault in (2,6) and i==n-1:eol=not eol
            if fault==3 and i==0:sof=not sof;eol=not eol
            errors|=int(sof!=(i==0) or eol!=(i%w==w-1))
            errors|=int(label>k)<<1
            records.append('put('+','.join((lit(label,l),str(int(sof)),str(int(eol)),
                                             lit(tag if i==0 else tag^((1<<t)-1),t),
                                             str(fi%3 if i%7==0 else 0),str(int(i==n-1))))+');')
        edges,summary=oracle(labels,w,h,k,errors)
        error_patterns.add(errors);empty+=not edges
        tail=labels[-1];left=labels[-2] if w>1 else 0;upper=labels[-1-w] if h>1 else 0
        tail_contacts=0 if errors else int(tail!=0 and left!=0 and tail!=left)+int(tail!=0 and upper!=0 and tail!=upper)
        previous=None
        for ei,(aa,bb,count) in enumerate(edges):
            address=(aa-1)*k+bb-1
            delay=6+2*tail_contacts+2*address if previous is None else 2*(address-previous)
            records.append(f'get_edge({lit(aa,l)},{lit(bb,l)},{lit(count,s)},{delay},{ei%4});')
            previous=address
        delay=4 if errors else (2*table+4+2*tail_contacts if previous is None else 2*(table-1-previous))
        err,nodes,fg,ec,sides=summary
        records.append('get_done('+','.join((lit(err,2),lit(nodes,v),lit(fg,a),lit(ec,e),lit(sides,s),lit(tag,t),str(delay),str(2+fi%4)))+');')
        tokens+=n;edge_count+=len(edges)
    resets=14-2*int(w<2 or k<2)-2*int(h<2 or k<2)-int(n<2 or k<2)
    records.append(f'if(frames!={len(frames)} || edges!={edge_count} || phase_resets!={resets}) $fatal(1,"coverage mismatch");')
    return '\n'.join(records)+'\n',{'width':w,'height':h,'label_w':l,'max_label':k,'tag_w':t,
        'frames':len(frames),'tokens':tokens,'edges':edge_count,'zero_edge_frames':empty,
        'error_patterns':sorted(error_patterns),'phase_reset_cancellations':resets}


def main():
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    iv=os.environ.get('IVERILOG') or shutil.which('iverilog',path=env['PATH'])
    vv=os.environ.get('VVP') or shutil.which('vvp',path=env['PATH'])
    report={'baseline_commit':BASELINE,'status':['NOT_RUN','HW_UNVERIFIED'],'profiles':[],'commands':[],
            'not_run':['synthesis','PnR','STA','hardware','expanded regression']}
    def run(args,cwd,negative=False):
        result=subprocess.run([str(x) for x in args],cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        okay=(result.returncode>0 and 'label_region_adjacency_invalid_parameters__see_README' in result.stderr) if negative else result.returncode==0 and not result.stderr.strip()
        report['commands'].append({'command':[str(x) for x in args],'returncode':result.returncode,
                                  'stdout':result.stdout,'stderr':result.stderr,'timeout_seconds':20,'pass':okay})
        if not okay:raise RuntimeError(str(report['commands'][-1]))
        return result.stdout
    try:
        if not iv or not vv:raise RuntimeError('Icarus/vvp unavailable: NOT_RUN')
        run([iv,'-g2012','-Wall','-tnull','-s','label_region_adjacency','-f','files.f'],ROOT)
        run([iv,'-g2012','-Wall','-tnull','-s','segmentation_graph','-f','example/files.f'],ROOT)
        run([iv,'-g2012','-Wall','-tnull','-s','label_region_adjacency',
             '-Plabel_region_adjacency.WIDTH=1024','-Plabel_region_adjacency.HEIGHT=1024',
             '-Plabel_region_adjacency.LABEL_W=8','-Plabel_region_adjacency.MAX_LABEL=63',
             '-Plabel_region_adjacency.TAG_W=32','-f','files.f'],ROOT)
        with tempfile.TemporaryDirectory(prefix='anscore_label_rag_') as temp_name:
            temp=Path(temp_name)
            for profile in PROFILES:
                text,stats=make_vectors(*profile);(temp/'vectors.svh').write_text(text,encoding='ascii',newline='\n')
                stats['vectors_sha256']=hashlib.sha256(text.encode('ascii')).hexdigest()
                top='tb_label_region_adjacency'
                run([iv,'-g2012','-Wall','-I',temp,'-s',top,'-o',temp/'unit.vvp']+
                    [f'-P{top}.{name}={value}' for name,value in zip('WHLKT',profile)]+
                    [ROOT/'rtl/label_region_adjacency.sv',ROOT/'sim/tb_label_region_adjacency.sv'],temp)
                output=run([vv,temp/'unit.vvp'],temp)
                match=re.search(r'PASS RAG .*source_stalls=(\d+) edge_holds=(\d+) done_holds=(\d+) resets=(\d+)',output)
                assert match and int(match[1])>0 and int(match[3])>0 and int(match[4])==stats['phase_reset_cancellations'],output
                if stats['edges']:assert int(match[2])>0,output
                stats.update(source_stall_cycles=int(match[1]),held_edge_cycles=int(match[2]),held_done_cycles=int(match[3]),result=output.strip())
                report['profiles'].append(stats)
            invalid=(('WIDTH',0),('WIDTH',1025),('HEIGHT',0),('HEIGHT',1025),('LABEL_W',0),('LABEL_W',9),
                     ('MAX_LABEL',0),('MAX_LABEL',64),('LABEL_W',1),('MAX_LABEL',16),('TAG_W',0),('TAG_W',33))
            for name,value in invalid:
                run([iv,'-g2012','-tnull','-s','label_region_adjacency',f'-Plabel_region_adjacency.{name}={value}','-f','files.f'],ROOT,True)
        names=['.gitattributes','files.f','example/files.f','rtl/label_region_adjacency.sv',
               'example/segmentation_graph.sv','sim/tb_label_region_adjacency.sv','run_tests.py','README.md','SOURCES.md']
        for name in names:
            data=(ROOT/name).read_bytes();data.decode('utf-8');assert b'\r' not in data and not data.startswith(b'\xef\xbb\xbf'),name
        assert (ROOT/'files.f').read_text().splitlines()==['rtl/label_region_adjacency.sv']
        assert (ROOT/'example/files.f').read_text().splitlines()==['rtl/label_region_adjacency.sv','example/segmentation_graph.sv']
        report.update(status=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'],
                      invalid_parameter_rejections=len(invalid),
                      source_sha256={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in names},
                      dependency_sha256={},license_sha256={name:hashlib.sha256((REPO/name).read_bytes()).hexdigest() for name in ('LICENSE','NOTICE')},
                      packaging_checks={'status':'PASS','source_files':9,'UTF8_LF':True,'exact_manifests':True},
                      oracle='Independent region unit-cell boundary XOR, then pairwise set intersection; no left/up recurrence',
                      resource_risk={'default':'LOW','maximum':'MEDIUM','measured':False})
        for name in ('frames','tokens','edges','phase_reset_cancellations','source_stall_cycles','held_edge_cycles','held_done_cycles'):
            report[name]=sum(p[name] for p in report['profiles'])
        print(f"PASS label_region_adjacency profiles={len(PROFILES)} frames={report['frames']} tokens={report['tokens']} edges={report['edges']} commands={len(report['commands'])}")
    except Exception as error:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=str(error)
        raise
    finally:
        (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')


if __name__=='__main__':main()
