#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite integer-RNE reference and exact unit-vector error-bound checks."""
from datetime import datetime,timezone
from pathlib import Path
from math import isqrt
import hashlib,itertools,json,os,random,re,shutil,subprocess,tempfile

ROOT=Path(__file__).resolve().parent
BASELINE='f19addd5fec59ec6affee05af7195ca1758d40dc'
DEPS=['../dsp_isp_library/infra/fixedpoint/rtl/sqrt_unit.sv',
      '../dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv']


def rne_ratio(numerator,denominator):
    q,r=divmod(abs(numerator),denominator)
    q+=int(2*r>denominator or (2*r==denominator and q%2))
    return -q if numerator<0 else q


def oracle(rows,limit,frac):
    values=[x for x,keep in rows if keep]
    if len(values)>limit:return [0],0,3,0,0,{'root_up':0,'root_down':0,'half_up':0,'half_down':0}
    if not values:return [0],0,1,0,0,{'root_up':0,'root_down':0,'half_up':0,'half_down':0}
    energy=sum(x*x for x in values)
    detail={'root_up':0,'root_down':0,'half_up':0,'half_down':0}
    if not energy:return [0]*len(values),1,2,len(values),0,detail
    radicand=energy<<(2*(frac+2));floor=isqrt(radicand)
    # Compare to the squared half-integer midpoint. An integer radicand
    # cannot equal an odd square divided by four, so root ties are impossible.
    assert 4*radicand!=(2*floor+1)**2
    up=int(4*radicand>(2*floor+1)**2);root=floor+up
    detail['root_up']=up;detail['root_down']=int(not up and floor*floor!=radicand)
    outputs=[];scale=1<<frac
    for x in values:
        numerator=x<<(2*frac+2);q,r=divmod(abs(numerator),root)
        if 2*r==root:detail['half_up' if q%2 else 'half_down']+=1
        output=rne_ratio(numerator,root)
        assert abs(output)<=scale
        # Independent comparison to the ideal irrational x/sqrt(S), checking
        # the 9/14-LSB bound by squaring positive rational interval endpoints.
        qmag=abs(output);u=abs(x)*scale
        assert 196*u*u <= (14*qmag+9)**2*energy
        if 14*qmag>9:assert 196*u*u >= (14*qmag-9)**2*energy
        outputs.append(output)
    return outputs,1,0,len(values),energy,detail


def vectors(w,limit,frac,tag_w):
    low=-(1<<(w-1));high=(1<<(w-1))-1;rng=random.Random(20261104+w*101+limit*13+frac)
    plain=[[],[0],[1],[-1],[low],[high],[1,1],[low,high],[low,1,0],
           [0]*limit,[low]*limit,[high]*limit,[1]*limit,
           [1]*(limit+1),[low,high]*(limit+1),[1,1,1,1]]
    if w>=3:plain.extend([[3,2,1,1,1],[-3,2,-1,1,1]])
    if w>=4:plain.extend([[5,5,3,2,1],[-5,5,-3,2,1],[low,1,-1,0,1]])
    if w==2 and limit==4:
        for length in range(1,4):plain.extend(itertools.product(range(low,high+1),repeat=length))
    for _ in range(24):
        plain.append([rng.randrange(low,high+1) for _ in range(rng.randrange(1,min(limit+3,20)+1))])
    frames=[]
    for index,values in enumerate(plain):
        rows=[(x,1) for x in values]
        if not rows:rows=[(low,0)]
        if index%3==0:rows=[(high,0)]+rows+[(low,0)]
        frames.append(rows)
    frames.extend([[(low,0),(high,0)],[(0,1),(low,0),(0,1)],[(high,0),(1,1),(low,0)]])
    c=max(1,(limit+1-1).bit_length());iw=max(1,(limit-1).bit_length());ew=2*w+(limit-1).bit_length()
    rn=(ew+2*(frac+2)+1)//2;dn=w+2*frac+2
    stats={'data_w':w,'max_len':limit,'frac':frac,'tag_w':tag_w,'frames':len(frames),'input_beats':0,
           'output_tokens':0,'normal_frames':0,'empty_frames':0,'zero_frames':0,'overflow_frames':0,
           'root_up':0,'root_down':0,'half_up':0,'half_down':0,'reset_phase_cancellations':12}
    def lit(x,width):return f"{width}'h{x&((1<<width)-1):x}"
    calls=[]
    for frame,rows in enumerate(frames):
        outputs,keep,status,count,energy,details=oracle(rows,limit,frac)
        stats[['normal_frames','empty_frames','zero_frames','overflow_frames'][status]]+=1
        for k,v in details.items():stats[k]+=v
        tag=(frame*13+5)&((1<<tag_w)-1)
        for index,(x,k) in enumerate(rows):
            beat_tag=tag if not index else (tag+index)&((1<<tag_w)-1)
            calls.append(f'put({lit(x,w)},{k},{int(index==len(rows)-1)},{lit(beat_tag,tag_w)},{frame%3 if index%3==0 else 0});')
        tail_retained=rows[-1][1] and sum(k for _,k in rows[:-1])<limit
        for index,value in enumerate(outputs):
            if index==0:
                delay=(rn+dn+6+tail_retained) if status==0 else (2+tail_retained) if status==2 else 1
            else:delay=1 if status==2 else dn+3
            calls.append(f'get_token({lit(value,frac+2)},{keep},{int(index==len(outputs)-1)},2\'h{status:x},{lit(count,c)},{lit(index,iw)},{lit(energy,ew)},{lit(tag,tag_w)},{int(delay)},{(frame+index)%5});')
        stats['input_beats']+=len(rows);stats['output_tokens']+=len(outputs)
    calls.append(f'if(frames!={len(frames)} || tokens!={stats["output_tokens"]} || reset_count!=13) $fatal(1,"coverage mismatch");')
    return '\n'.join(calls)+'\n',stats


def main():
    (ROOT/'verification.json').unlink(missing_ok=True)
    files=sorted(p for p in ROOT.rglob('*') if p.is_file())
    for p in files+[ROOT/d for d in DEPS]:
        if b'\r' in p.read_bytes():raise RuntimeError('LF source required: '+str(p))
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env['PATH']
    iv=str(suite/'bin/iverilog.exe') if (suite/'bin/iverilog.exe').is_file() else shutil.which('iverilog')
    vv=str(suite/'bin/vvp.exe') if (suite/'bin/vvp.exe').is_file() else shutil.which('vvp')
    if not iv or not vv:raise SystemExit('NOT_RUN: Icarus/vvp required')
    records=[];profiles=[]
    def run(command,cwd,negative=False):
        cmd=[str(x) for x in command];p=subprocess.run(cmd,cwd=cwd,env=env,capture_output=True,text=True,timeout=15)
        records.append({'command':cmd,'returncode':p.returncode,'stdout':p.stdout.strip(),'stderr':p.stderr.strip()})
        if negative:
            if not p.returncode or 'block_vector_normalize_invalid_parameter__see_README' not in p.stderr:raise RuntimeError(p.stdout+p.stderr)
        else:
            header='warning: Some design elements have no explicit time unit and/or\n       : time precision. This may cause confusing timing results.\n       : Affected design elements are:\n'
            diagnostic=p.stderr.strip()
            known=diagnostic.startswith(header) and all(re.fullmatch(r'       :   -- module fp_(sqrt|div)_(iter|pipe) declared here: .*(sqrt_unit|recip_div)\.sv:[0-9]+',line) for line in diagnostic[len(header):].splitlines())
            if p.returncode or (diagnostic and not known):raise RuntimeError(p.stdout+p.stderr)
        if p.stdout.strip():print(p.stdout.splitlines()[0] if '-V' in cmd else p.stdout.strip(),flush=True)
        return p
    with tempfile.TemporaryDirectory(prefix='anscore_vector_normalize_') as temp:
        tmp=Path(temp);version=run([iv,'-V'],tmp).stdout.splitlines()[0]
        run([iv,'-g2012','-Wall','-tnull','-s','block_vector_normalize','-f','files.f'],ROOT)
        run([iv,'-g2012','-Wall','-tnull','-s','normalize16_example','-f','example/files.f'],ROOT)
        for w,limit,f,t in [(2,1,0,1),(2,4,0,1),(3,5,1,3),(4,8,2,8),(8,7,8,8),(16,16,16,8),(24,64,22,32),(8,64,0,1)]:
            text,profile=vectors(w,limit,f,t);(tmp/'vectors.svh').write_bytes(text.encode());exe=tmp/'unit.vvp';top='tb_block_vector_normalize'
            run([iv,'-g2012','-Wall','-I',tmp,'-s',top,'-o',exe]+[f'-P{top}.{k}={v}' for k,v in zip('WLFT',(w,limit,f,t))]+
                [ROOT/d for d in DEPS]+[ROOT/'rtl/block_vector_normalize.sv',ROOT/'sim/tb_block_vector_normalize.sv'],tmp)
            p=run([vv,exe],tmp)
            if 'PASS normalize' not in p.stdout:raise RuntimeError('completion marker missing')
            profile['result']=p.stdout.strip();profiles.append(profile)
        assert sum(x['root_up'] for x in profiles)>0 and sum(x['root_down'] for x in profiles)>0
        assert sum(x['half_up'] for x in profiles)>0 and sum(x['half_down'] for x in profiles)>0
        invalid=[('DATA_W',1),('DATA_W',25),('MAX_LEN',0),('MAX_LEN',65),('FRAC',-1),('FRAC',23),('TAG_W',0),('TAG_W',33)]
        for key,value in invalid:
            run([iv,'-g2012','-tnull','-s','block_vector_normalize',f'-Pblock_vector_normalize.{key}={value}']+[ROOT/d for d in DEPS]+[ROOT/'rtl/block_vector_normalize.sv'],tmp,True)
    report={'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],'baseline':BASELINE,
            'checked_at_utc':datetime.now(timezone.utc).isoformat(),'tool_version':version,'profiles':profiles,
            'per_process_timeout_seconds':15,'commands':records,'invalid_parameter_rejections':len(invalid),
            'scope':'finite exact integer two-stage RNE oracle, squared rational error-bound validation, protocol/latency/reset and example compilation',
            'source_sha256':{str(p.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
            'dependency_sha256':{d:hashlib.sha256((ROOT/d).read_bytes()).hexdigest() for d in DEPS},
            'reproduce':'python -B cores/signal_processing/block_vector_normalize/run_tests.py',
            'not_run':['synthesis','PnR','STA','hardware','expanded regression']}
    (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
