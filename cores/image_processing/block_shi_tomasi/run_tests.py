#!/usr/bin/env python3
"""Finite exact block corner scoring checks via integer matrix inertia."""
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
BASELINE='99b5c8c1b3530775bb9dca0e5b4d1df07a014f68'
DEPS=['../../signal_processing/dsp_isp_library/infra/fixedpoint/rtl/sqrt_unit.sv',
      '../../signal_processing/symmetric_eigen2x2/rtl/symmetric_eigen2x2.sv']


def oracle(raw,capacity,frac,width,threshold):
    gradients=[(x,y) for x,y,keep in raw if keep]
    if len(gradients)>capacity:return (0,0,0,2,0,0,0,0)
    if not gradients:return (0,0,0,1,0,0,0,0)
    a=sum(x*x for x,y in gradients);b=sum(x*y for x,y in gradients);d=sum(y*y for x,y in gradients)
    q=1<<frac
    # Search integer spectral bounds by PSD/negative-definite matrix inertia.
    # Neither discriminant nor square root nor RTL root-correction is evaluated.
    def predicate(z,upper):
        aa=a*q-z;dd=d*q-z;det=aa*dd-(b*q)**2
        return not (aa<0 and det>0) if upper else aa>=0 and dd>=0 and det>=0
    def spectral_floor(upper):
        low=0;high=(a+d)*q+1
        assert predicate(low,upper) and not predicate(high,upper)
        while high-low>1:
            middle=(low+high)//2
            if predicate(middle,upper):low=middle
            else:high=middle
        assert predicate(low,upper) and not predicate(low+1,upper)
        return low
    minimum=spectral_floor(False);maximum=spectral_floor(True);limit=(1<<(width-1))-1
    assert 0<=minimum<=maximum
    return (min(minimum,limit),min(maximum,limit),int(minimum>limit)|(int(maximum>limit)<<1),
            0,int(minimum>threshold),int(a==d and b==0),len(gradients),a+d)


def fixtures(bits,capacity):
    low=-(1<<(bits-1));high=(1<<(bits-1))-1
    def wrap(values):return [(x,y,1) for x,y in values] or [(low,high,0)]
    points=[[],[(0,0)],[(low,low)],[(low,0)],[(0,high)],
            [(low,0),(0,low)],[(low,low),(high,high)],[(1,1),(1,-1)],
            [(low,0),(0,low),(0,1)],[(low,0),(0,1)],
            [(0,0)]*capacity,[(low,low)]*capacity,
            [(low,0) if i%2==0 else (0,low) for i in range(capacity)],
            [(low,high)]*(capacity+1),[(1,0)]*(capacity+2)]
    if bits>=3:points.extend([[(2,0),(0,2),(0,1)],[(high,1),(high,0),(0,1)]])
    if bits==2 and capacity==4:
        grid=list(itertools.product(range(low,high+1),repeat=2))
        points.extend([list(pair) for pair in itertools.product(grid,repeat=2)])
    rng=random.Random(20261108+bits*101+capacity)
    for _ in range(24):
        points.append([(rng.randrange(low,high+1),rng.randrange(low,high+1))
                       for i in range(rng.randrange(1,min(capacity+4,24)+1))])
    frames=[]
    for i,values in enumerate(points):
        raw=wrap(values)
        if i%3==0:raw=[(low,high,0)]+raw+[(high,low,0)]
        frames.append(raw)
    frames.extend([[(low,high,0),(high,low,0)],
                   wrap([(low,0)]*capacity)+[(high,low,0)]*3,
                   [(low,high,0)]+wrap([(low,0),(0,low)])])
    return frames


def vectors(g,capacity,frac,width,tagw):
    frames=fixtures(g,capacity);countw=capacity.bit_length();stat=2*g+(capacity-1).bit_length()
    maxthreshold=(1<<(width-1))-1;rng=random.Random(20261108+g*31+capacity);calls=[]
    stats={'grad_w':g,'max_samples':capacity,'frac':frac,'score_w':width,'tag_w':tagw,
           'frames':len(frames),'input_tokens':0,'corner_frames':0,'isotropic_frames':0,
           'overflow_frames':0,'min_clipped_frames':0,'phase_reset_cancellations':12}
    def lit(v,w):return f"{w}'h{v&((1<<w)-1):x}"
    for i,raw in enumerate(frames):
        threshold=[0,1,maxthreshold,rng.randrange(maxthreshold+1)][i%4]
        tag=(i*19+3)&((1<<tagw)-1)
        expected=oracle(raw,capacity,frac,width,threshold)
        score,maximum,sat,status,corner,isotropic,count,energy=expected
        for j,(x,y,keep) in enumerate(raw):
            calls.append('put('+','.join((lit(x,g),lit(y,g),str(keep),str(int(j==len(raw)-1)),
                                          lit(threshold if j==0 else threshold^maxthreshold,width-1),
                                          lit(tag if j==0 else tag^((1<<tagw)-1),tagw),str(i%3 if j%3==0 else 0)))+');')
        retained_tail=raw[-1][2] and sum(keep for x,y,keep in raw[:-1])<capacity
        delay=1 if status else 4*(stat+frac+1)+6+(6 if retained_tail else 3)
        calls.append('get_result('+','.join((lit(score,width),lit(maximum,width),f"2'h{sat:x}",f"2'h{status:x}",
                                            str(corner),str(isotropic),lit(count,countw),lit(energy,stat+1),lit(tag,tagw),
                                            str(delay),str(i%5)))+');')
        stats['input_tokens']+=len(raw);stats['corner_frames']+=corner;stats['isotropic_frames']+=isotropic
        stats['overflow_frames']+=status==2;stats['min_clipped_frames']+=bool(sat&1)
    calls.append(f'if(frames!={len(frames)} || corner_frames!={stats["corner_frames"]} || isotropic_frames!={stats["isotropic_frames"]} || overflow_frames!={stats["overflow_frames"]} || min_clipped_frames!={stats["min_clipped_frames"]} || phase_resets!=12) $fatal(1,"coverage mismatch");')
    return '\n'.join(calls)+'\n',stats


def main():
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    iv=os.environ.get('IVERILOG') or shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH'])
    if not iv or not vv:raise RuntimeError('NOT_RUN: Icarus Verilog unavailable')
    records=[];profiles=[]
    def run(command,cwd,negative=False):
        p=subprocess.run([str(x) for x in command],cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        rec={'command':[str(x) for x in command],'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'timeout_seconds':20};records.append(rec)
        if negative:assert p.returncode>0 and 'block_shi_tomasi_invalid_parameter__see_README' in p.stderr,rec
        else:
            header='warning: Some design elements have no explicit time unit and/or\n       : time precision. This may cause confusing timing results.\n       : Affected design elements are:\n'
            diagnostic=p.stderr.strip()
            known=diagnostic.startswith(header) and all(re.fullmatch(r'       :   -- module fp_sqrt_(iter|pipe) declared here: .*sqrt_unit\.sv:[0-9]+',line) for line in diagnostic[len(header):].splitlines())
            assert p.returncode==0 and (not diagnostic or known),rec
        return p.stdout
    with tempfile.TemporaryDirectory(prefix='anscore_shi_tomasi_') as tmp:
        temp=Path(tmp);rtl=ROOT/'rtl/block_shi_tomasi.sv';tb=ROOT/'sim/tb_block_shi_tomasi.sv'
        run([iv,'-g2012','-Wall','-tnull','-s','block_shi_tomasi','-f','files.f'],ROOT)
        run([iv,'-g2012','-Wall','-tnull','-s','gradient_tile_score','-f','example/files.f'],ROOT)
        for g,m,f,r,t in ((2,1,0,3,1),(2,4,0,2,1),(3,5,4,8,3),(9,64,8,32,8),
                           (11,4,24,64,32),(2,1024,0,16,8),(8,16,24,8,8)):
            text,profile=vectors(g,m,f,r,t);(temp/'vectors.svh').write_text(text,encoding='ascii',newline='\n')
            top='tb_block_shi_tomasi'
            run([iv,'-g2012','-Wall','-I',temp,'-s',top,'-o','unit.vvp']+
                [f'-P{top}.{key}={v}' for key,v in zip('GMFRT',(g,m,f,r,t))]+[ROOT/d for d in DEPS]+[rtl,tb],temp)
            output=run([vv,'unit.vvp'],temp);assert 'PASS ShiTomasi' in output,output
            coverage=re.search(r'held=([0-9]+) source_stalls=([0-9]+) resets=([0-9]+)',output)
            assert coverage and int(coverage[2])>0 and int(coverage[3])==12,output
            profile['held_result_cycles']=int(coverage[1]);profile['source_stall_cycles']=int(coverage[2])
            profile['status']='UNIT_SIM_PASS';profile['result']=output.strip();profiles.append(profile)
        invalid=[('GRAD_W',1),('GRAD_W',12),('MAX_SAMPLES',0),('MAX_SAMPLES',1025),
                 ('GRAD_W',10),('FRAC',-1),('FRAC',25),('SCORE_W',1),('SCORE_W',65),('TAG_W',0),('TAG_W',33)]
        for key,value in invalid:
            run([iv,'-g2012','-tnull','-s','block_shi_tomasi',f'-Pblock_shi_tomasi.{key}={value}']+
                [ROOT/d for d in DEPS]+[rtl],temp,True)
    files=['.gitattributes','files.f','example/files.f','rtl/block_shi_tomasi.sv','example/gradient_tile_score.sv',
           'sim/tb_block_shi_tomasi.sv','run_tests.py','README.md','SOURCES.md']
    for p in files:assert b'\r' not in (ROOT/p).read_bytes(),p
    manifest=DEPS+['rtl/block_shi_tomasi.sv']
    assert (ROOT/'files.f').read_text().splitlines()==manifest
    assert (ROOT/'example/files.f').read_text().splitlines()==manifest+['example/gradient_tile_score.sv']
    baseline_hashes={};dependency_hashes={}
    for p in DEPS:
        dependency_path=(ROOT/p).resolve();repo_path=dependency_path.relative_to(REPO).as_posix()
        committed=subprocess.run(['git','show',f'{BASELINE}:{repo_path}'],cwd=REPO,
                                 capture_output=True,check=True,timeout=20).stdout
        baseline_hashes[p]=hashlib.sha256(committed).hexdigest()
        dependency_hashes[p]=hashlib.sha256(dependency_path.read_bytes()).hexdigest()
        assert baseline_hashes[p]==dependency_hashes[p],p
    report={'baseline_commit':BASELINE,'status':['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'],
            'oracle':'exact integer outer-product sums plus independent PSD/negative-definite inertia bisection; no sqrt',
            'profiles':profiles,'frames':sum(p['frames'] for p in profiles),'input_tokens':sum(p['input_tokens'] for p in profiles),
            'commands':records,'invalid_parameter_rejections':len(invalid),
            'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in files},
            'dependency_sha256':dependency_hashes,'dependency_baseline_sha256':baseline_hashes,
            'packaging_checks':{'status':'PASS','local_source_files':len(files),'local_sources_lf':True,
                                'manifest_closure_exact':True,'dependencies_match_baseline':True},
            'source_stall_cycles':sum(p['source_stall_cycles'] for p in profiles),
            'held_result_cycles':sum(p['held_result_cycles'] for p in profiles),
            'phase_reset_cancellations':sum(p['phase_reset_cancellations'] for p in profiles),
            'resource_risk':{'default':'LOW','maximum':'MEDIUM','measured':False},
            'not_run':['synthesis','PnR','STA','hardware','full regression']}
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(f"PASS block_shi_tomasi profiles={len(profiles)} frames={report['frames']} inputs={report['input_tokens']} commands={len(records)}")


if __name__=='__main__':main()
