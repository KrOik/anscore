"""Otsu solver against exact Fraction class-mean variance, no float golden."""
from fractions import Fraction
from pathlib import Path
import hashlib
import random
import sys
import tempfile

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import evidence_dir,execute,write_json


def threshold(hist):
    total=sum(hist)
    if total==0:
        return 0,2
    total_sum=sum(i*c for i,c in enumerate(hist))
    w0=s0=0
    best_score=Fraction(-1)
    best=0
    for t,c in enumerate(hist):
        w0+=c
        s0+=t*c
        w1=total-w0
        if not w0 or not w1:
            continue
        mean0=Fraction(s0,w0)
        mean1=Fraction(total_sum-s0,w1)
        score=w0*w1*(mean0-mean1)**2
        if score>best_score:
            best_score=score
            best=t
    return best,0


def fixture(path,width):
    maximum=(1<<width)-1
    rng=random.Random(0x0750+width)
    cases=[[0]*256]
    for level in (91,255):
        h=[0]*256;h[level]=maximum;cases.append(h)
    h=[0]*256;h[0]=maximum;h[255]=maximum;cases.append(h)
    h=[0]*256;h[20]=maximum;h[128]=max(1,maximum//3);h[230]=max(1,maximum//2);cases.append(h)
    cases.append([maximum]*256)
    cases.append([rng.randrange(maximum+1) for _ in range(256)])
    h=[0]*256
    for level in (1,2,4,17,18,198,200,254):
        h[level]=rng.randrange(1,maximum+1)
    cases.append(h)
    rows=[]
    for h in cases:
        t,error=threshold(h)
        rows.append(f'{t} {error}\n')
        rows.extend(f'{c}\n' for c in h)
    path.write_text(''.join(rows),encoding='ascii')
    return len(cases)


def main():
    evidence=evidence_dir('otsu')
    sources=[HERE/'rtl/img_hist_serial_multiply.v',HERE/'rtl/img_hist_otsu_threshold.v',
             HERE/'sim/tb_img_hist_otsu_threshold.v',Path(__file__).resolve()]
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    results=[]
    with tempfile.TemporaryDirectory(prefix='cip_otsu_') as temporary:
        folder=Path(temporary)
        for width in (1,8,16,24):
            data=folder/'fixture.txt'
            checks=fixture(data,width)
            image=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_img_hist_otsu_threshold',
                     f'-Ptb_img_hist_otsu_threshold.COUNT_W={width}','-o',image,*sources[:3]],
                    HERE,evidence/f'count{width}_compile.log')
            output=execute(['vvp',image,f'+fixture={data}'],HERE,evidence/f'count{width}_simulation.log',timeout=180)
            if f'OTSU PASS count_width={width} checks={checks}' not in output:
                raise RuntimeError('Missing Otsu success marker')
            print(output.strip(),flush=True)
            results.append({'count_width':width,'histograms':checks})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p)] for p in sources):
        raise RuntimeError('Source changed during Otsu tests')
    write_json(evidence/'summary.json',{'status':'PASS','cases':results,'source_sha256':hashes,
               'scope':'256-bin exact Otsu solver, extremes/ties/empty, CE, response stalls, reset',
               'synthesis':'not_run','board':'not_run'})
    print(evidence)


if __name__=='__main__':
    main()
