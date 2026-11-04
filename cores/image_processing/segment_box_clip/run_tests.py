#!/usr/bin/env python3
"""Finite geometry-intersection Fraction oracle and Icarus checks; no PPA."""
from __future__ import annotations
from fractions import Fraction
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
REPO=ROOT.parents[2]
BASELINE='f19addd5fec59ec6affee05af7195ca1758d40dc'


def oracle(command):
    x0,y0,x1,y1,xmin,ymin,xmax,ymax=command
    empty=(0,0,0,0,1,1,0,0,0,0)
    if xmin>xmax or ymin>ymax:return (*empty[:8],1,0)
    dx=x1-x0;dy=y1-y0
    def included(x,y):return xmin<=x<=xmax and ymin<=y<=ymax
    # Geometric boundary intersections, not four half-plane interval updates.
    candidates=[]
    if included(x0,y0):candidates.append(Fraction(0))
    if included(x1,y1):candidates.append(Fraction(1))
    if dx:
        for x in (xmin,xmax):
            t=Fraction(x-x0,dx);y=y0+t*dy
            if 0<=t<=1 and included(x,y):candidates.append(t)
    if dy:
        for y in (ymin,ymax):
            t=Fraction(y-y0,dy);x=x0+t*dx
            if 0<=t<=1 and included(x,y):candidates.append(t)
    if not candidates:return empty
    first=min(candidates);last=max(candidates)
    start=(x0+first*dx,y0+first*dy);end=(x0+last*dx,y0+last*dy)
    den0=first.denominator;den1=last.denominator
    numerators=[start[0]*den0,start[1]*den0,end[0]*den1,end[1]*den1]
    assert all(Fraction(n).denominator==1 for n in numerators)
    assert included(*start) and included(*end) and 0<=first<=last<=1
    return (*map(int,numerators),den0,den1,1,int(start==end),0,int(first>0)|(int(last<1)<<1))


def cases(bits):
    low=-(1<<(bits-1));high=(1<<(bits-1))-1
    frames=[]
    def add(segment,box):frames.append((*segment,*box))
    full=(low,low,high,high);unit=(0,0,1,1)
    for segment in ((low,low,high,high),(high,low,low,high),(0,0,0,0),
                    (low,0,high,0),(0,low,0,high),(1,1,0,0),(low,1,high,1),
                    (low,low,high,low),(0,1,1,0),(low,high,high,high)):
        add(segment,full);add(segment,unit)
    for box in ((0,0,0,0),(0,low,0,high),(low,0,high,0),(high,high,low,low),
                (1,0,0,1),(0,1,1,0)):
        add((low,low,high,high),box);add((0,0,0,0),box)
    if bits==2:
        for segment in itertools.product(range(low,high+1),repeat=4):
            for box in ((-1,-1,1,1),(0,0,1,1),(0,-1,0,1),(-1,0,1,0),(0,0,0,0)):
                add(segment,box)
    if bits==3:
        for segment in itertools.product(range(low,high+1),repeat=4):add(segment,(-1,-1,1,1))
    rng=random.Random(20261107+bits*73)
    for index in range(48):
        segment=tuple(rng.randrange(low,high+1) for _ in range(4))
        xx=sorted(rng.randrange(low,high+1) for _ in range(2));yy=sorted(rng.randrange(low,high+1) for _ in range(2))
        box=(xx[0],yy[0],xx[1],yy[1])
        if index%11==0:box=(high,low,low,high)
        add(segment,box)
    return frames


def vectors(bits,tagw):
    nw=2*bits+5;frames=cases(bits);lines=[];visible=points=errors=0
    def lit(v,width):return f"{width}'h{v&((1<<width)-1):x}"
    for index,command in enumerate(frames):
        result=oracle(command);tag=(index*29+3)&((1<<tagw)-1)
        lines.append('put('+','.join([*(lit(x,bits) for x in command),lit(tag,tagw),str(index%3)])+');')
        nums=result[:4];den0,den1,v,p,e,c=result[4:]
        lines.append('get_result('+','.join([*(lit(x,nw) for x in nums),lit(den0,bits+1),lit(den1,bits+1),
                                             str(v),str(p),str(e),f"2'h{c:x}",lit(tag,tagw),str(index%5)])+');')
        visible+=v;points+=p;errors+=e
    lines.append(f'if(commands!={len(frames)} || visible_cases!={visible} || point_cases!={points} || error_cases!={errors} || reset_cases!=9) $fatal(1,"coverage mismatch");')
    return '\n'.join(lines)+'\n',{'w':bits,'tag_w':tagw,'commands':len(frames),'visible':visible,'points':points,
                                    'errors':errors,'phase_reset_cancellations':9}


def main():
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    iv=os.environ.get('IVERILOG') or shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH'])
    if not iv or not vv:raise RuntimeError('NOT_RUN: Icarus Verilog unavailable')
    records=[];profiles=[]
    def run(command,cwd,negative=False):
        result=subprocess.run([str(x) for x in command],cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        record={'command':[str(x) for x in command],'returncode':result.returncode,'stdout':result.stdout,
                'stderr':result.stderr,'timeout_seconds':20};records.append(record)
        if negative:assert result.returncode>0 and 'invalid segment_box_clip parameters' in result.stdout+result.stderr,record
        else:assert result.returncode==0 and not result.stderr,record
        return result.stdout
    with tempfile.TemporaryDirectory(prefix='anscore_segment_clip_') as tmp:
        temp=Path(tmp);rtl=ROOT/'rtl/segment_box_clip.sv';example=ROOT/'example/fixed_roi_clip.sv';tb=ROOT/'sim/tb_segment_box_clip.sv'
        run([iv,'-g2012','-Wall','-tnull','-s','segment_box_clip','-s','fixed_roi_clip',rtl,example],temp)
        for bits,tagw in ((2,1),(3,3),(8,8),(12,8),(24,32)):
            text,profile=vectors(bits,tagw);(temp/'vectors.svh').write_text(text,encoding='ascii',newline='\n')
            run([iv,'-g2012','-Wall','-I',temp,'-s','tb_segment_box_clip','-Ptb_segment_box_clip.W='+str(bits),
                 '-Ptb_segment_box_clip.T='+str(tagw),'-o','unit.vvp',rtl,tb],temp)
            output=run([vv,'unit.vvp'],temp);assert 'PASS clip' in output,output
            profile['status']='UNIT_SIM_PASS';profile['result']=output.strip();profiles.append(profile)
        for key,value in (('W',1),('W',25),('TAG_W',0),('TAG_W',33)):
            (temp/'invalid.sv').write_text(f'module invalid_tb;segment_box_clip #(.{key}({value})) dut();initial #1 $finish;endmodule\n',encoding='ascii',newline='\n')
            run([iv,'-g2012','-s','invalid_tb','-o','invalid.vvp',rtl,'invalid.sv'],temp)
            run([vv,'invalid.vvp'],temp,True)
    files=['.gitattributes','files.f','rtl/segment_box_clip.sv','example/fixed_roi_clip.sv',
           'sim/tb_segment_box_clip.sv','run_tests.py','README.md','SOURCES.md']
    for p in files:assert b'\r' not in (ROOT/p).read_bytes(),p
    report={'baseline_commit':BASELINE,'status':['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'],
            'oracle':'exact Fraction segment-boundary intersection candidates; no Liang-Barsky half-plane updates',
            'profiles':profiles,'segments':sum(p['commands'] for p in profiles),'commands':records,
            'invalid_parameter_rejections':4,'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in files},
            'dependencies':[],'resource_risk':{'default':'LOW','maximum':'MEDIUM','measured':False},
            'not_run':['synthesis','PnR','STA','hardware','full regression']}
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(f"PASS segment_box_clip profiles={len(profiles)} segments={report['segments']} commands={len(records)}")


if __name__=='__main__':main()
