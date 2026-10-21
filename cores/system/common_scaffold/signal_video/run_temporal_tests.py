"""Recursive filtered-history temporal denoise with independent integer model."""
from pathlib import Path
import random
import sys
import tempfile
import hashlib

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def fixtures(folder,bits):
    rng=random.Random(4783);commands=[];inputs=[];outputs=[];limit=(1<<bits)-1
    history=None;shape=None
    def frame(mode,w,h,image,weight,threshold,bad=0):
        nonlocal history,shape
        if bad==8:history=None;shape=None
        valid=mode==0 and history is not None and shape==(w,h)
        result=[]
        for i,pixel in enumerate(image):
            previous=history[i] if valid else pixel
            result.append(pixel if not valid or abs(pixel-previous)>threshold else
                (pixel*weight+previous*(256-weight)+128)//256)
        error=2 if bad in [1,2] else 0
        commands.extend([mode,w,h,w,h,weight,threshold,error,bad,len(image)])
        inputs.extend(image);outputs.extend(v | (int(i==0)<<33) | (int(i%w==w-1)<<32) for i,v in enumerate(result))
        history=None if error else result;shape=(w,h)
    for w,h in [(1,1),(1,6),(8,1),(3,3),(5,4),(8,6)]:
        for i in range(24):
            image=[rng.getrandbits(bits) for _ in range(w*h)]
            if i%5==0:image=[0]*(w*h)
            if i%5==1:image=[limit]*(w*h)
            frame(1 if i==10 else 0,w,h,image,[0,1,63,127,128,129,255,256][i%8],
                [0,limit,limit//2][i%3],1 if i==7 else 2 if i==15 else 0)
    for mode,pixel,weight,threshold,bad in [(1,0,128,limit,0),(0,limit,128,limit,0),
        (0,0,0,limit,0),(0,limit,0,0,0),(0,0,256,limit,0),
        (0,limit,0,limit,8),(0,0,128,limit,0),(0,limit,128,limit,8)]:
        frame(mode,2,2,[pixel]*4,weight,threshold,bad)
    for mode,w,h,dw,dh,weight,threshold,error in [(2,2,2,2,2,0,0,1),(15,2,2,2,2,0,0,1),
        (0,0,2,0,2,0,0,2),(0,9,2,9,2,0,0,2),(0,2,7,2,7,0,0,2),
        (0,2,2,3,2,0,0,2),(0,2,2,2,2,257,0,2),(0,2,2,2,2,0xffffffff,0,2)]:
        commands.extend([mode,w,h,dw,dh,weight,threshold,error,0,0])
    if bits<32:commands.extend([0,2,2,2,2,128,1<<bits,2,0,0])
    frame(0,2,2,[0]*4,128,limit)  # Rejected commands retain filtered history.
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',inputs),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:08x}\n') for v in values))
    return {'commands':len(commands)//10,'pixels':len(inputs)}

def main():
    evidence=evidence_dir('temporal_adapter');cases=[]
    sources=[HERE/'rtl/cip_image_temporal_denoise.v',HERE/'sim/tb_cip_image_temporal_denoise.v',
        HERE.parent/'image/filters/rtl/img_filter_temporal_denoise.v']
    tracked=[*sources,Path(__file__)]
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    with tempfile.TemporaryDirectory(prefix='cip_temporal_') as temporary:
        for bits in [1,8,16,24,32]:
            folder=Path(temporary)/str(bits);folder.mkdir();counts=fixtures(folder,bits);binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_temporal_denoise',f'-Ptb_cip_image_temporal_denoise.DW={bits}',
                '-o',binary,*sources],HERE,evidence/f'w{bits}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',*[f'+{k}={v}' for k,v in counts.items()]],HERE,evidence/f'w{bits}_simulation.log')
            if f'TEMPORAL_DENOISE PASS width={bits}' not in output:raise RuntimeError('missing PASS')
            print(output.strip());cases.append({'width':bits,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):
        raise RuntimeError('source changed during regression')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run'})
    print(f'evidence={evidence}')

if __name__=='__main__':main()
