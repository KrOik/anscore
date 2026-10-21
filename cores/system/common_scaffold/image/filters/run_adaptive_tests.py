"""Exact rational-mean oracle; temporary fixtures/images, retained small logs."""
from fractions import Fraction
from pathlib import Path
import hashlib
import random
import sys
import tempfile

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/"integration"))
from tooling import evidence_dir,execute,write_json


def fixture(path,width,gaussian=0):
    rng=random.Random(0xADA+width)
    maximum=(1<<width)-1
    offsets=[-(1<<width),-1,0,1,maximum]
    cases=[]
    for value in [0,maximum//2,maximum]:
        for offset in offsets:
            for invert in (0,1):
                cases.append(([value]*9,offset,invert))
    for center in [0,maximum]:
        pixels=[maximum-center]*9
        pixels[4]=center
        for offset in offsets:
            for invert in (0,1):
                cases.append((pixels[:],offset,invert))
    for _ in range(600):
        cases.append(([rng.randrange(maximum+1) for _ in range(9)],
                      rng.randrange(-(1<<width),1<<width),rng.randrange(2)))
    for _ in range(200):
        cases.append(([rng.randrange(maximum+1) for _ in range(9)],
                      rng.randrange(max(-(1<<width),-3),min(maximum,3)+1),rng.randrange(2)))
    weights=[a*b for a in (1,2,1) for b in (1,2,1)] if gaussian else [1]*9
    rows=[]
    for index,(pixels,offset,invert) in enumerate(cases):
        local_mean=Fraction(sum(p*w for p,w in zip(pixels,weights)),sum(weights))
        selected=(Fraction(pixels[4])>local_mean-offset)^bool(invert)
        rows.append(' '.join(map(str,[*pixels,offset,invert,int(index%31==0),int(index%17==16),maximum if selected else 0]))+'\n')
    path.write_text(''.join(rows),encoding='ascii')
    return len(cases)


def main():
    evidence=evidence_dir('adaptive_threshold')
    sources=[HERE/'rtl/img_filter_adaptive_mean3x3.v',HERE/'rtl/img_filter_adaptive_gaussian3x3.v',HERE/'rtl/img_filter_stream_register.v',
             HERE/'sim/tb_img_filter_adaptive_mean3x3.v',Path(__file__).resolve()]
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    results=[]
    with tempfile.TemporaryDirectory(prefix='cip_adaptive_') as temporary:
        folder=Path(temporary)
        for gaussian,width in [(g,w) for g in (0,1) for w in (1,8,12,16)]:
            label=f'{"gaussian" if gaussian else "mean"}_width{width}'
            data=folder/'fixture.txt'
            checks=fixture(data,width,gaussian)
            image=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_img_filter_adaptive_mean3x3',
                     f'-Ptb_img_filter_adaptive_mean3x3.PIXEL_W={width}',
                     f'-Ptb_img_filter_adaptive_mean3x3.GAUSSIAN={gaussian}','-o',image,*sources[:4]],
                    HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',image,f'+fixture={data}'],HERE,evidence/f'{label}_simulation.log')
            kind='GAUSSIAN' if gaussian else 'MEAN'
            if f'ADAPTIVE_{kind} PASS width={width} checks={checks}' not in output:
                raise RuntimeError('Missing adaptive mean success marker')
            print(output.strip())
            results.append({'gaussian':bool(gaussian),'width':width,'checks':checks})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p)] for p in sources):
        raise RuntimeError('Source changed during simulation')
    write_json(evidence/'summary.json',{'status':'PASS','cases':results,'source_sha256':hashes,
               'scope':'external 3x3 windows, exact rational comparison, signed offset, inversion, markers, CE/backpressure/reset',
               'synthesis':'not_run','board':'not_run'})
    print(evidence)


if __name__=='__main__':
    main()
