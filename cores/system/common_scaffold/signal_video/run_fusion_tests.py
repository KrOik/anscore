"""Scalar/RGB alpha blend against independent unbounded integer reference."""
from pathlib import Path
import random
import sys
import tempfile
import hashlib

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def fixtures(folder,bits):
    rng=random.Random(3301);commands=[];inputs=[];auxiliary=[];outputs=[];limit=(1<<bits)-1
    for mode in ([0,1] if bits==24 else [0]):
        for w,h in [(1,1),(1,6),(8,1),(3,3),(5,4),(8,6)]:
            for weight in [0,1,63,127,128,129,255,256]:
                for pattern in range(6):
                    size=w*h
                    a=[rng.getrandbits(bits) for _ in range(size)]
                    b=[rng.getrandbits(bits) for _ in range(size)]
                    if pattern==0:a=[0]*size;b=[limit]*size
                    if pattern==1:a=[limit]*size;b=[0]*size
                    if pattern==2:a=[0]*size;b=[1]*size
                    if pattern==3:a=[i&limit for i in range(size)];b=[(limit-i)&limit for i in range(size)]
                    if mode==1 and pattern==3:a=[0xff0000]*size;b=[0x00ffff]*size
                    result=[]
                    for base,other in zip(a,b):
                        if mode==0:value=(base*(256-weight)+other*weight+128)//256
                        else:value=sum((((base>>shift&255)*(256-weight)+(other>>shift&255)*weight+128)//256)<<shift for shift in [0,8,16])
                        result.append(value)
                    bad={1:1,2:2,3:3,4:4}.get(pattern,0)
                    commands.extend([mode,w,h,w,h,weight,0,2 if bad else 0,bad,size])
                    inputs.extend(a);auxiliary.extend(b)
                    outputs.extend(v | (int(i==0)<<33) | (int(i%w==w-1)<<32) for i,v in enumerate(result))
    for mode,w,h,dw,dh,p0,p1,error in [(2,2,2,2,2,0,0,1),(15,2,2,2,2,0,0,1),
        (0,0,2,0,2,0,0,2),(0,9,2,9,2,0,0,2),(0,2,7,2,7,0,0,2),
        (0,2,2,3,2,0,0,2),(0,2,2,2,2,257,0,2),(0,2,2,2,2,0xffffffff,0,2),(0,2,2,2,2,0,1,2)]:
        commands.extend([mode,w,h,dw,dh,p0,p1,error,0,0])
    if bits!=24:commands.extend([1,2,2,2,2,128,0,2,0,0])
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',auxiliary),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:08x}\n') for v in values))
    return {'commands':len(commands)//10,'pixels':len(inputs)}

def main():
    evidence=evidence_dir('fusion_adapter');cases=[]
    sources=[HERE/'rtl/cip_image_fusion.v',HERE/'sim/tb_cip_image_fusion.v',
        HERE.parent/'image/multiframe/img_mf_rgb_blend_partial_pipe.v',
        HERE.parent/'image/multiframe/cip_fusion_scalar_multiply.v']
    tracked=[*sources,Path(__file__)]
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    with tempfile.TemporaryDirectory(prefix='cip_fusion_') as temporary:
        for bits in [1,8,16,24,32]:
            folder=Path(temporary)/str(bits);folder.mkdir();counts=fixtures(folder,bits);binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_fusion',f'-Ptb_cip_image_fusion.DW={bits}',
                '-o',binary,*sources],HERE,evidence/f'w{bits}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',*[f'+{k}={v}' for k,v in counts.items()]],HERE,evidence/f'w{bits}_simulation.log')
            if f'FUSION PASS width={bits}' not in output:raise RuntimeError('missing PASS')
            print(output.strip());cases.append({'width':bits,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):
        raise RuntimeError('source changed during regression')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run'})
    print(f'evidence={evidence}')

if __name__=='__main__':main()
