"""Independent replicated-border grayscale morphology frame regression."""
from pathlib import Path
import random
import tempfile
import sys
import hashlib

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def morphology(image,w,h,mask,maximum):
    offsets=[(i%3-1,i//3-1) for i in range(9) if mask>>i&1]
    sign=-1 if maximum else 1
    return [(max if maximum else min)(image[min(h-1,max(0,y+sign*dy))*w+
        min(w-1,max(0,x+sign*dx))] for dx,dy in offsets)
        for y in range(h) for x in range(w)]

def fixtures(folder,bits,adapter=0):
    rng=random.Random(719);commands=[];inputs=[];outputs=[];limit=(1<<bits)-1
    for op in range(5):
        for w,h in [(1,1),(1,6),(8,1),(3,3),(5,4),(8,6)]:
            for mask in [1,16,256,0x155,0xba,0x1ff]:
                image=[rng.getrandbits(bits) for _ in range(w*h)]
                image[0]=limit;image[-1]=0
                lo=morphology(image,w,h,mask,False);hi=morphology(image,w,h,mask,True)
                result=[lo,hi,morphology(lo,w,h,mask,True),
                    morphology(hi,w,h,mask,False),[max(0,a-b) for a,b in zip(hi,lo)]][op]
                bad=int(mask==0xba and w==5)
                commands.extend([op,w,h,mask,2 if bad else 0,bad]);inputs.extend(image);outputs.extend(result)
    for op,w,h,mask,error in [(5,2,2,511,1),(0,0,2,511,2),(1,9,2,511,2),(2,2,7,511,2),(3,2,2,0,2)]:
        commands.extend([op,w,h,mask,error,0])
    if adapter:
        commands.extend([0,2,2,0x200,2,0]);commands.extend([15,2,2,511,1,0])
    for name,values in [('commands',commands),('inputs',inputs),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join(f'{v:08x}\n' for v in values))
    return {'width':bits,'commands':len(commands)//6,'pixels':len(outputs)}

def main():
    evidence=evidence_dir('morph_frame');cases=[]
    sources=[HERE/'rtl/cip_image_morph_frame.v',HERE/'sim/tb_cip_image_morph_frame.v',HERE/'rtl/cip_image_morphology.v']
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [*sources,Path(__file__)]}
    with tempfile.TemporaryDirectory(prefix='cip_morph_') as temporary:
        for bits,adapter in [(b,a) for a in [0,1] for b in [1,8,16,24,32]]:
            folder=Path(temporary)/f"w{bits}_a{adapter}";folder.mkdir();case=fixtures(folder,bits,adapter);case["adapter"]=adapter;binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_morph_frame',f'-Ptb_cip_image_morph_frame.DW={bits}',f'-Ptb_cip_image_morph_frame.ADAPTER={adapter}',
                '-o',binary,*sources],HERE,evidence/f'w{bits}_a{adapter}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',f'+commands={case["commands"]}',f'+pixels={case["pixels"]}'],HERE,evidence/f'w{bits}_a{adapter}_simulation.log')
            if f'MORPH_FRAME PASS width={bits}' not in output:raise RuntimeError('missing PASS')
            print(output.strip());cases.append(case)
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run','scope':'engine and legacy adapter'})
    print(f'evidence={evidence}')

if __name__=='__main__':main()
