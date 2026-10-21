"""Persistent independent external-memory model for frame write/replay commands."""
from pathlib import Path
import sys
import random
import tempfile
import hashlib

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json


def fixtures(folder,bits):
    rng=random.Random(18273);commands=[];inputs=[];outputs=[];memory={}
    def add(w,h,mode=0,image=None,error=0,bad=0,base=256,stride=None,dims=None,p0=0,p1=0):
        stride=4*w+8 if stride is None else stride
        dw,dh=dims or (w,h);values=[]
        if image is not None and bad!=7:
            for i,v in enumerate(image):memory[base+(i//w)*stride+4*(i%w)]=v
        if not error and mode in (0,2):
            values=[memory.get(base+y*stride+4*x,0) for y in range(h) for x in range(w)]
        commands.extend([mode,w,h,dw,dh,p0,p1,error,bad,len(image or []),len(values),base,stride])
        inputs.extend(image or [])
        outputs.extend(v | (int(i==0)<<33) | (int(i%w==w-1)<<32) for i,v in enumerate(values))
    if 1<=bits<=32:
        for w,h in [(1,1),(1,6),(8,1),(3,3),(5,4),(8,6)]:
            for mode in (0,1):
                for pattern in range(3):
                    image=[rng.getrandbits(bits) for _ in range(w*h)]
                    if pattern==0:image=[0]*(w*h)
                    if pattern==1:image=[(1<<bits)-1]*(w*h)
                    add(w,h,mode,image);add(w,h,2);add(w,h,2)
        # Distinct padded-stride banks retain contents across later writes.
        add(3,2,1,[rng.getrandbits(bits) for _ in range(6)],base=1024,stride=32)
        add(3,2,1,[rng.getrandbits(bits) for _ in range(6)],base=2048,stride=16)
        add(3,2,2,base=1024,stride=32);add(3,2,2,base=2048,stride=16)
        for bad in (1,2):
            add(3,2,0,[rng.getrandbits(bits) for _ in range(6)],error=2,bad=bad)
            add(3,2,2)
        add(3,2,1,[rng.getrandbits(bits)],error=3,bad=7)
        add(3,2,2,error=3,bad=8)
        add(3,2,0,[0]*6)
        for w,h in [(0,2),(9,2),(2,7)]:add(w,h,error=2,stride=64)
        add(2,2,error=2,dims=(1,2));add(2,2,3,error=1)
        add(2,2,error=2,p0=1);add(2,2,error=2,p1=1)
        add(2,2,error=2,base=257);add(2,2,error=2,stride=9);add(2,2,error=2,stride=4)
        add(2,2,error=2,base=0xfffffffc,stride=16)
        add(3,2,2)
    else:
        add(2,2,error=2);add(2,2,3,error=1)
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',[0]*len(inputs)),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join(format(v,'09x' if name=='expected' else '08x')+'\n' for v in values))
    return {'commands':len(commands)//13,'inputs':len(inputs),'outputs':len(outputs),'reset_cases':3 if 1<=bits<=32 else 0}


def main():
    evidence=evidence_dir('framebuffer_adapter');results=[]
    sources=[HERE/'rtl/cip_image_framebuffer.v',HERE/'sim/tb_cip_image_framebuffer.v']
    tracked=[*sources,Path(__file__)];hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    with tempfile.TemporaryDirectory(prefix='cip_framebuffer_') as temporary:
        for bits in (1,8,12,24,32,33):
            label=f'w{bits}';folder=Path(temporary)/label;folder.mkdir();counts=fixtures(folder,bits);binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_framebuffer',f'-Ptb_cip_image_framebuffer.DW={bits}','-o',binary,*sources],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["inputs"]}',f'+outputs={counts["outputs"]}'],HERE,evidence/f'{label}_simulation.log')
            if f'FRAMEBUFFER PASS width={bits} commands={counts["commands"]} pixels={counts["outputs"]}' not in output:raise RuntimeError('Missing framebuffer PASS marker')
            print(output.strip());results.append({'data_w':bits,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):raise RuntimeError('Source changed during tests')
    write_json(evidence/'summary.json',{'status':'PASS','cases':results,'source_sha256':hashes,'synthesis':'not_run','board':'not_run'})
    print(f'evidence={evidence}')


if __name__=='__main__':main()
