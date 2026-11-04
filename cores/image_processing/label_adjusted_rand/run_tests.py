#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite pair-classification oracle; no contingency-count recurrence."""
from __future__ import annotations
from fractions import Fraction
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
BASELINE='e2ccd5380052e92a5430e97b6fdbf0621a17503c'
PROFILES=((1,1,1,1,1),(1,7,2,3,3),(7,1,3,4,8),(2,2,1,2,2),
          (3,3,2,3,3),(64,64,4,16,8),(1024,1,8,64,32),(1,1024,8,64,32))


def oracle(raw,errors):
    if errors:return (0,0,0,0,0,0,0,0,0,errors)
    data=[(a,b) for a,b,keep in raw if keep];n=len(data)
    members_a={};members_b={}
    for i,(a,b) in enumerate(data):
        members_a[a]=members_a.get(a,0)|(1<<i)
        members_b[b]=members_b.get(b,0)|(1<<i)
    future=(1<<n)-1;p=aa=bb=both=agree=0
    # Explicit unordered sample-pair classification, packed into index bitsets.
    # No joint table, bin square, choose-two bin formula or per-bin increment.
    for i,(a,b) in enumerate(data):
        future^=1<<i
        sa=members_a[a]&future;sb=members_b[b]&future
        p+=future.bit_count();aa+=sa.bit_count();bb+=sb.bit_count()
        both+=(sa&sb).bit_count();agree+=((sa&sb)|((~(sa|sb))&future)).bit_count()
    assert p==n*(n-1)//2 and agree==p-aa-bb+2*both
    equivalent=int(aa==bb==both)
    expected=Fraction(aa*bb,p) if p else Fraction(0)
    maximum=Fraction(aa+bb,2)
    metric=Fraction(1) if p==0 or maximum==expected else (Fraction(both)-expected)/(maximum-expected)
    num=2*(p*both-aa*bb);den=p*(aa+bb)-2*aa*bb
    assert den>=0
    degenerate=int(den==0)
    if degenerate:num=den=1
    assert Fraction(num,den)==metric and Fraction(-1,2)<=metric<=1
    assert equivalent==(metric==1)
    return num,den,n,p,aa,bb,both,equivalent,degenerate,0


def fixtures(w,h,l,k):
    n=w*h;rng=random.Random(20261110+31*w+101*h+k);frames=[]
    def add(a,b,keep=None,fault=0):
        frames.append((list(zip(a,b,keep if keep is not None else [1]*n)),fault))
    zero=[0]*n;cycle=[i%k for i in range(n)]
    add(zero,zero,[0]*n);add(zero,zero);add(zero,zero,[int(i==0) for i in range(n)])
    add(cycle,[(i+1)%k for i in cycle]);add(cycle,cycle,[int(i<k) for i in range(n)])
    add(zero,cycle);add(cycle,zero)
    add([i%min(k,2) for i in range(n)],[(i//2)%min(k,2) for i in range(n)])
    add([min(k-1,(i*2)//max(1,n)) for i in range(n)],cycle)
    add(cycle,list(reversed(cycle)),[int(i%3!=0) for i in range(n)])
    add([k-1]*n,[k-1]*n)
    if k>=2:
        a=[(i//2)%2 for i in range(n)];b=[i%2 for i in range(n)]
        add(a,b);add(b,a)
    if k<(1<<l):
        # Illegal codes are intentionally harmless on masked aligned pairs.
        add([k if i%2==0 else 0 for i in range(n)],[(1<<l)-1]*n,[0]*n)
    if (w,h)==(2,2):
        for pairs in itertools.product(itertools.product(range(2),repeat=2),repeat=n):
            add([a for a,b in pairs],[b for a,b in pairs])
    if (w,h)==(3,3):
        for mask in range(1<<n):
            add([(mask>>i)&1 for i in range(n)],[(mask>>((i+1)%n))&1 for i in range(n)])
    for _ in range(6):
        add([rng.randrange(k) for i in range(n)],[rng.randrange(k) for i in range(n)],
            [int(rng.randrange(5)!=0) for i in range(n)])
    add(zero,zero,fault=1);add(cycle,cycle,fault=2);add(zero,zero,fault=3)
    if k<(1<<l):
        bad=zero.copy();bad[-1]=k;add(bad,zero,fault=4)
        bad=zero.copy();bad[n//2]=k;add(zero,bad,fault=5)
        bad=zero.copy();bad[0]=(1<<l)-1;add(bad,zero,fault=6)
    return frames


def vectors(w,h,l,k,t):
    n=w*h;c=n.bit_length();p=max(1,(n*(n-1)//2).bit_length());u=2*p+2;d=2*p+1;mw=p+1
    lines=[];frames=fixtures(w,h,l,k)
    stats=dict(width=w,height=h,label_w=l,labels=k,tag_w=t,frames=len(frames),tokens=len(frames)*n,
               negative_ari=0,zero_ari=0,equivalent=0,degenerate=0,error_frames=0,masked_illegal_pairs=0,
               phase_reset_cancellations=11 if n==1 else 12)
    patterns=set()
    def lit(value,width):return f"{width}'h{value&((1<<width)-1):x}"
    for fi,(raw,fault) in enumerate(frames):
        tag=(fi*37+3)&((1<<t)-1);errors=0
        for i,(a,b,keep) in enumerate(raw):
            sof=i==0;eol=i%w==w-1
            if (fault==1 and i==n//2) or (fault in (3,5) and i==0):sof=not sof
            if (fault in (2,6) and i==n-1) or (fault==3 and i==0):eol=not eol
            errors|=int(sof!=(i==0) or eol!=(i%w==w-1))
            errors|=int(keep and (a>=k or b>=k))<<1
            stats['masked_illegal_pairs']+=int(not keep and (a>=k or b>=k))
            lines.append('put('+','.join((lit(a,l),lit(b,l),str(keep),str(int(sof)),str(int(eol)),
                                         lit(tag if i==0 else tag^((1<<t)-1),t),
                                         str(fi%3 if i%7==0 else 0),str(int(i==n-1))))+');')
        expected=oracle(raw,errors);num,den,count,pp,aa,bb,jj,eq,deg,err=expected
        patterns.add(err);stats['negative_ari']+=num<0;stats['zero_ari']+=not err and num==0
        stats['equivalent']+=eq;stats['degenerate']+=deg;stats['error_frames']+=bool(err)
        assert -(1<<(u-1))<=num<(1<<(u-1)) and den<(1<<d)
        delay=1 if errors else 3*mw+5+raw[-1][2]
        lines.append('get_result('+','.join((lit(num,u),lit(den,d),lit(count,c),lit(pp,p),lit(aa,p),lit(bb,p),lit(jj,p),
                                            str(eq),str(deg),lit(err,2),lit(tag,t),str(delay),str(2+fi%4)))+');')
    lines.append(f'if(frames!={len(frames)} || phase_resets!={stats["phase_reset_cancellations"]}) $fatal(1,"coverage mismatch");')
    stats['error_patterns']=sorted(patterns)
    return '\n'.join(lines)+'\n',stats


def main():
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join((str(suite/'bin'),str(suite/'lib'),env.get('PATH','')))
    iv=os.environ.get('IVERILOG') or shutil.which('iverilog',path=env['PATH'])
    vv=os.environ.get('VVP') or shutil.which('vvp',path=env['PATH'])
    report=dict(baseline_commit=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],profiles=[],commands=[],dependency_sha256={},
                not_run=['synthesis','PnR','STA','hardware','expanded regression'])
    def run(args,cwd,negative=False):
        result=subprocess.run([str(x) for x in args],cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        okay=(result.returncode>0 and 'label_adjusted_rand_invalid_parameters__see_README' in result.stderr) if negative else result.returncode==0 and not result.stderr.strip()
        report['commands'].append(dict(command=[str(x) for x in args],returncode=result.returncode,stdout=result.stdout,
                                       stderr=result.stderr,timeout_seconds=20,passed=okay))
        if not okay:raise RuntimeError(str(report['commands'][-1]))
        return result.stdout
    try:
        if not iv or not vv:raise RuntimeError('Icarus/vvp unavailable: NOT_RUN')
        run([iv,'-g2012','-Wall','-tnull','-s','label_adjusted_rand','-f','files.f'],ROOT)
        run([iv,'-g2012','-Wall','-tnull','-s','segmentation_agreement','-f','example/files.f'],ROOT)
        run([iv,'-g2012','-Wall','-tnull','-s','label_adjusted_rand','-Plabel_adjusted_rand.WIDTH=1024',
             '-Plabel_adjusted_rand.HEIGHT=1024','-Plabel_adjusted_rand.LABEL_W=8',
             '-Plabel_adjusted_rand.LABELS=64','-Plabel_adjusted_rand.TAG_W=32','-f','files.f'],ROOT)
        with tempfile.TemporaryDirectory(prefix='anscore_label_ari_') as name:
            temp=Path(name)
            for profile in PROFILES:
                text,stats=vectors(*profile);(temp/'vectors.svh').write_text(text,encoding='ascii',newline='\n')
                stats['vectors_sha256']=hashlib.sha256(text.encode('ascii')).hexdigest();top='tb_label_adjusted_rand'
                run([iv,'-g2012','-Wall','-I',temp,'-s',top,'-o',temp/'unit.vvp']+
                    [f'-P{top}.{key}={value}' for key,value in zip('WHLKT',profile)]+
                    [ROOT/'rtl/label_adjusted_rand.sv',ROOT/'sim/tb_label_adjusted_rand.sv'],temp)
                output=run([vv,temp/'unit.vvp'],temp)
                match=re.search(r'PASS ARI .*source_stalls=(\d+) held=(\d+) resets=(\d+)',output)
                assert match and int(match[1])>0 and int(match[2])>0 and int(match[3])==stats['phase_reset_cancellations'],output
                stats.update(source_stall_cycles=int(match[1]),held_result_cycles=int(match[2]),result=output.strip())
                report['profiles'].append(stats)
            invalid=(('WIDTH',0),('WIDTH',1025),('HEIGHT',0),('HEIGHT',1025),('LABEL_W',0),('LABEL_W',9),
                     ('LABELS',0),('LABELS',65),('LABEL_W',1),('LABELS',17),('TAG_W',0),('TAG_W',33))
            for key,value in invalid:
                run([iv,'-g2012','-tnull','-s','label_adjusted_rand',f'-Plabel_adjusted_rand.{key}={value}','-f','files.f'],ROOT,True)
        names=['.gitattributes','files.f','example/files.f','rtl/label_adjusted_rand.sv','example/segmentation_agreement.sv',
               'sim/tb_label_adjusted_rand.sv','run_tests.py','README.md','SOURCES.md']
        for name in names:
            data=(ROOT/name).read_bytes();data.decode('utf-8');assert b'\r' not in data and data.endswith(b'\n') and not data.startswith(b'\xef\xbb\xbf'),name
        assert (ROOT/'files.f').read_text().splitlines()==['rtl/label_adjusted_rand.sv']
        assert (ROOT/'example/files.f').read_text().splitlines()==['rtl/label_adjusted_rand.sv','example/segmentation_agreement.sv']
        report.update(status=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'],
                      invalid_parameter_rejections=len(invalid),source_sha256={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in names},
                      license_sha256={name:hashlib.sha256((REPO/name).read_bytes()).hexdigest() for name in ('LICENSE','NOTICE')},
                      packaging_checks=dict(status='PASS',source_files=9,UTF8_LF=True,exact_manifests=True),
                      oracle='Unordered sample-pair equality classification with index bitsets, then exact Fraction expected-index normalization',
                      resource_risk=dict(default='LOW',maximum='MEDIUM',measured=False))
        for name in ('frames','tokens','negative_ari','zero_ari','equivalent','degenerate','phase_reset_cancellations','source_stall_cycles','held_result_cycles'):
            report[name]=sum(p[name] for p in report['profiles'])
        print(f"PASS label_adjusted_rand profiles={len(PROFILES)} frames={report['frames']} tokens={report['tokens']} commands={len(report['commands'])}")
    except Exception as error:
        report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=str(error);raise
    finally:
        (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')


if __name__=='__main__':main()
