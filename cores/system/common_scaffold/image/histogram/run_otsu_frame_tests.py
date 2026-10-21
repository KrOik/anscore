"""Same-frame Otsu capture/solve/replay tests using the Fraction oracle."""
from pathlib import Path
import hashlib
import random
import sys
import tempfile
from run_otsu_tests import threshold

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import evidence_dir,execute,write_json


def fixtures(folder,width,height):
    n=width*height
    rng=random.Random(0x0F7+width*17+height)
    patterns=[[0]*n,[200]*n,[255]*n,[255 if i%2 else 0 for i in range(n)],
              [(i*37+13)%256 for i in range(n)],[rng.randrange(256) for _ in range(n)]]
    cases=[(pixels,invert,0) for invert in (0,1) for pixels in patterns]
    cases += [(patterns[4],0,1),(patterns[5],1,2),(patterns[3],0,0)]
    inputs=[]
    expected=[]
    for index,(pixels,invert,corrupt) in enumerate(cases):
        hist=[pixels.count(i) for i in range(256)]
        t,error=threshold(hist)
        assert error==0
        code=2 if corrupt else 0
        tag=0x100+index
        inputs.append(f'{invert} {tag} {t} {code}\n')
        for i,pixel in enumerate(pixels):
            sof=int(i==0)
            eol=int(i%width==width-1)
            if i==0 and corrupt==1:
                sof^=1
            if i==0 and corrupt==2:
                eol^=1
            inputs.append(f'{pixel} {sof} {eol}\n')
            if not corrupt:
                value=255 if ((pixel>t)^bool(invert)) else 0
                expected.append(f'{value} {int(i==0)} {int(i%width==width-1)} {int(i==n-1)} {tag} {t}\n')
    # Recovery packet is driven explicitly after reset cancellation tests.
    for i in range(n):
        expected.append(f'0 {int(i==0)} {int(i%width==width-1)} {int(i==n-1)} 1365 0\n')
    (folder/'input.txt').write_text(''.join(inputs),encoding='ascii')
    (folder/'expected.txt').write_text(''.join(expected),encoding='ascii')
    return {'width':width,'height':height,'commands':len(cases)+1,'outputs':len(expected),'frame_errors':2}


def main():
    evidence=evidence_dir('otsu_frame')
    sources=[HERE/'rtl/img_hist_otsu_frame.v',HERE/'rtl/img_hist_accumulator.v',
             HERE/'rtl/img_hist_otsu_threshold.v',HERE/'rtl/img_hist_serial_multiply.v',
             HERE/'sim/tb_img_hist_otsu_frame.v',Path(__file__).resolve(),HERE/'run_otsu_tests.py']
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    results=[]
    with tempfile.TemporaryDirectory(prefix='cip_otsu_frame_') as temporary:
        for width,height,count_w in [(1,1,1),(5,3,8),(8,8,8),(7,4,5),(32,24,16),(8,8,6)]:
            invalid=int(width*height>(1<<count_w)-1)
            label=f'{width}x{height}_c{count_w}'
            folder=Path(temporary)/label
            folder.mkdir()
            counts=fixtures(folder,width,height) if not invalid else {'parameter_error':1}
            image=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_img_hist_otsu_frame',
                     f'-Ptb_img_hist_otsu_frame.WIDTH={width}',f'-Ptb_img_hist_otsu_frame.HEIGHT={height}',
                     f'-Ptb_img_hist_otsu_frame.COUNT_W={count_w}',f'-Ptb_img_hist_otsu_frame.INVALID={invalid}',
                     '-o',image,*sources[:5]],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',image,f'+folder={folder}'],HERE,evidence/f'{label}_simulation.log',timeout=180)
            marker='OTSU_FRAME INVALID PASS' if invalid else f"OTSU_FRAME PASS outputs={counts['outputs']} commands=16"
            if marker not in output:
                raise RuntimeError('Missing Otsu frame success marker')
            print(output.strip(),flush=True)
            results.append({'count_width':count_w,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p)] for p in sources):
        raise RuntimeError('Source changed during Otsu frame tests')
    write_json(evidence/'summary.json',{'status':'PASS','cases':results,'source_sha256':hashes,
               'scope':'same-frame strict Otsu/invert, tags/markers, malformed input, CE/stalls/reset and bad count capacity',
               'synthesis':'not_run','board':'not_run'})
    print(evidence)


if __name__=='__main__':
    main()
