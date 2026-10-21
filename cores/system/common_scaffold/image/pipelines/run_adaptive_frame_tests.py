"""Pixel-stream adaptive threshold tests with direct 2D Fraction reference."""
from fractions import Fraction
from pathlib import Path
import hashlib
import random
import sys
import tempfile

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import evidence_dir,execute,write_json


def fixtures(folder,pixel_w,gaussian):
    maximum=(1<<pixel_w)-1
    minimum=-(1<<pixel_w)
    rng=random.Random(0xAF0+pixel_w)
    cases=[(3,3,0,0,0),(3,7,1,1,0),(7,3,-1,0,0),(8,6,max(minimum,-3),1,0),
           (5,5,maximum,0,0),(8,6,minimum,1,0),(3,3,0,1,0),
           (8,6,0,0,1),(8,6,1,1,2),(7,5,-1,0,0),
           (2,5,0,0,0),(33,3,0,0,0),(3,2,0,0,0)]
    inputs=[]
    outputs=[]
    weights=[u*v for u in (1,2,1) for v in (1,2,1)] if gaussian else [1]*9
    for index,(width,height,offset,invert,corrupt) in enumerate(cases):
        invalid=width<3 or height<3 or width>32
        error=1 if invalid else 2 if corrupt else 0
        tag=0x200+index
        inputs.append(f'{width} {height} {offset} {invert} {tag} {error}\n')
        if invalid:
            continue
        pixels=[rng.randrange(maximum+1) for _ in range(width*height)]
        if index==0:
            pixels=[0]*len(pixels)
        if index==1:
            pixels=[maximum]*len(pixels)
        if index==2:
            pixels=[maximum if i%2 else 0 for i in range(len(pixels))]
        for i,pixel in enumerate(pixels):
            sof=int(i==0)
            eol=int(i%width==width-1)
            if i==0 and corrupt==1:
                sof^=1
            if i==0 and corrupt==2:
                eol^=1
            inputs.append(f'{pixel} {sof} {eol}\n')
        for y in range(1,height-1):
            for x in range(1,width-1):
                taps=[pixels[(y+dy)*width+x+dx] for dy in (-1,0,1) for dx in (-1,0,1)]
                mean=Fraction(sum(w*p for w,p in zip(weights,taps)),sum(weights))
                selected=(Fraction(pixels[y*width+x])>mean-offset)^bool(invert)
                outputs.append(f'{maximum if selected else 0} {int(x==1 and y==1)} {int(x==width-2)} {int(x==width-2 and y==height-2)} {tag}\n')
    outputs.append('0 1 1 1 1365\n')
    (folder/'input.txt').write_text(''.join(inputs),encoding='ascii')
    (folder/'expected.txt').write_text(''.join(outputs),encoding='ascii')
    return {'pixel_width':pixel_w,'gaussian':bool(gaussian),'commands':len(cases)+1,'outputs':len(outputs),
            'dimension_errors':3,'marker_errors':2}


def main():
    evidence=evidence_dir('adaptive_frame')
    sources=[HERE/'img_adaptive_threshold_frame.v',HERE.parent/'window/img_window3x3_valid_draft.v',
             HERE.parent/'filters/rtl/img_filter_adaptive_mean3x3.v',
             HERE.parent/'filters/rtl/img_filter_adaptive_gaussian3x3.v',
             HERE.parent/'filters/rtl/img_filter_stream_register.v',HERE/'tb_img_adaptive_threshold_frame.v',
             Path(__file__).resolve()]
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    results=[]
    with tempfile.TemporaryDirectory(prefix='cip_adaptive_frame_') as temporary:
        for gaussian,pixel_w in [(g,w) for g in (0,1) for w in (1,8,12,16)]:
            label=f'g{gaussian}_w{pixel_w}'
            folder=Path(temporary)/label
            folder.mkdir()
            counts=fixtures(folder,pixel_w,gaussian)
            image=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_img_adaptive_threshold_frame',
                     f'-Ptb_img_adaptive_threshold_frame.PIXEL_W={pixel_w}',
                     f'-Ptb_img_adaptive_threshold_frame.GAUSSIAN={gaussian}','-o',image,*sources[:6]],
                    HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',image,f'+folder={folder}'],HERE,evidence/f'{label}_simulation.log')
            if f"ADAPTIVE_FRAME PASS outputs={counts['outputs']} commands={counts['commands']}" not in output:
                raise RuntimeError('Missing adaptive frame success marker')
            print(output.strip(),flush=True)
            results.append(counts)
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p)] for p in sources):
        raise RuntimeError('Source changed during adaptive frame tests')
    write_json(evidence/'summary.json',{'status':'PASS','cases':results,'source_sha256':hashes,
               'scope':'cropped pixel stream, Fraction mean/Gaussian, signed offsets/invert, config capture, markers/tags, CE/stalls/reset/recovery',
               'synthesis':'not_run','board':'not_run'})
    print(evidence)


if __name__=='__main__':
    main()
