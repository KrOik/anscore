"""Cropped bilateral frame ABI with independent 2-D fixed-point reference."""
from pathlib import Path
import math
import random
import hashlib
import sys
import tempfile

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def fixtures(folder,bits,gray):
    rng=random.Random(6151);maximum=(1<<gray)-1;commands=[];inputs=[];outputs=[]
    weights=[int(math.floor(65535*math.exp(-i/16)+0.5)) for i in range(256)]
    def add(w=5,h=4,ss=256,sr=4096,mode=0,error=0,bad=0,dims=None,pattern=0):
        dw,dh=dims or (w-2,h-2);pixels=[];result=[]
        if error==0 or bad:
            pixels=[rng.randrange(maximum+1) for _ in range(w*h)]
            if pattern==1:pixels=[0]*(w*h)
            if pattern==2:pixels=[maximum]*(w*h)
            if pattern==3:pixels=[maximum if (i%w+i//w)%2 else 0 for i in range(w*h)]
            if pattern==4:pixels=[maximum if i==w*(h//2)+w//2 else 0 for i in range(w*h)]
            for y in range(1,h-1):
                for x in range(1,w-1):
                    center=pixels[y*w+x];num=0;den=0
                    for dy in [-1,0,1]:
                        for dx in [-1,0,1]:
                            sample=pixels[(y+dy)*w+x+dx]
                            index=((dx*dx+dy*dy)*524288)//(ss*ss)+((sample-center)**2*524288)//(sr*sr)
                            weight=weights[min(255,index)];num+=sample*weight;den+=weight
                    result.append((num+den//2)//den)
        commands.extend([mode,w,h,dw&65535,dh&65535,ss,sr,error,len(pixels),len(result)])
        for i,pixel in enumerate(pixels):
            sof=i==0;eol=i%w==w-1
            if bad==1 and i==0:sof=False
            if bad==2 and i==len(pixels)-1:eol=not eol
            if bad==3 and i==0:pixel|=1<<gray
            inputs.append(pixel|(int(sof)<<33)|(int(eol)<<32))
        outputs.extend(v|(int(i==0)<<33)|(int(i%dw==dw-1)<<32) for i,v in enumerate(result))
    if not(1<=gray<=12 and gray<=bits<=32):
        commands=[0,3,3,1,1,256,4096,2,0,0,1,3,3,1,1,256,4096,1,0,0]
        for name in ['commands','inputs','outputs']:
            values=commands if name=='commands' else []
            (folder/f'{name}.hex').write_text(''.join(f'{v:08x}\n' for v in values))
        return {'commands':2,'inputs':0,'outputs':0,'width':bits,'gray':gray,'scope':'rejection_only'}
    for ss,sr in [(1,1),(256,4096),(65535,65535)]:
        for pattern in range(5):
            for w,h in [(3,3),(5,4),(8,5)]:add(w,h,ss,sr,pattern=pattern)
    add(error=2,bad=1);add(error=2,bad=2)
    if bits>gray:add(error=2,bad=3)
    add(mode=1,error=1);add(w=2,error=2);add(h=2,error=2);add(w=9,error=2)
    add(ss=0,error=2);add(sr=0,error=2);add(ss=65536,error=2);add(sr=65536,error=2)
    add(dims=(5,4),error=2)
    for name,values in [('commands',commands),('inputs',inputs),('outputs',outputs)]:
        (folder/f'{name}.hex').write_text(''.join((f'{v:09x}\n' if name!='commands' else f'{v:08x}\n') for v in values))
    return {'commands':len(commands)//10,'inputs':len(inputs),'outputs':len(outputs),'width':bits,'gray':gray,'scope':'functional'}

def main():
    evidence=evidence_dir('bilateral_adapter');cases=[]
    sources=[HERE/'rtl/cip_image_bilateral_filter.v',HERE/'rtl/cip_image_bilateral_frame.v',
        HERE/'sim/tb_cip_image_bilateral.v',HERE.parent/'image/window/img_window3x3_valid_draft.v',
        HERE.parent/'image/filters/rtl/img_filter_bilateral3x3.v',HERE.parent/'image/filters/rtl/img_filter_exp_weight.v']
    tracked=[*sources,Path(__file__)]
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    with tempfile.TemporaryDirectory(prefix='cip_bilateral_') as temporary:
        for bits,gray in [(1,1),(8,8),(12,12),(24,8),(32,12),(4,8),(24,13)]:
            label=f'w{bits}_g{gray}';folder=Path(temporary)/label;folder.mkdir();counts=fixtures(folder,bits,gray);binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_bilateral',f'-Ptb_cip_image_bilateral.DW={bits}',
                f'-Ptb_cip_image_bilateral.GB={gray}','-o',binary,*sources],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',*[f'+{k}={counts[k]}' for k in ['commands','inputs','outputs']]],HERE,evidence/f'{label}_simulation.log')
            if f'BILATERAL PASS width={bits}' not in output:raise RuntimeError('missing PASS')
            print(output.strip());cases.append(counts)
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):raise RuntimeError('source changed')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run'})
    print(f'evidence={evidence}')

if __name__=='__main__':main()
