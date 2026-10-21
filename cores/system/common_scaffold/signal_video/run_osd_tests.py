"""Full-raster RGB alpha/key overlay command and independent pixel regression."""
from pathlib import Path
import random
import sys
import tempfile
import hashlib

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def fixtures(folder,bits):
    rng=random.Random(4093);commands=[];inputs=[];auxiliary=[];outputs=[]
    if bits==24:
        for mode in range(4):
            for w,h in [(1,1),(1,6),(8,1),(3,3),(5,4),(8,6)]:
                for alpha in [0,1,127,128,129,255,256]:
                    for pattern in range(3):
                        size=w*h;key=[0,0xff00ff,0xffffff][pattern]
                        a=[rng.getrandbits(24) for _ in range(size)]
                        b=[key if (i+pattern)%3==0 else rng.getrandbits(24) for i in range(size)]
                        if pattern==1:a=[0xff0000]*size;b=[key if i%2 else 0x00ffff for i in range(size)]
                        if pattern==2:a=[0xffffff]*size;b=[key if i%2 else 0 for i in range(size)]
                        result=[]
                        for base,overlay in zip(a,b):
                            enabled=mode!=0 and not(mode>=2 and overlay==key)
                            weight=256 if mode==3 else alpha
                            value=base if not enabled else sum((((base>>shift&255)*(256-weight)+
                                (overlay>>shift&255)*weight+128)//256)<<shift for shift in [0,8,16])
                            result.append(value)
                        bad=0 if alpha in [0,128,256] else [2 if alpha==127 else 1,3,4][pattern]
                        commands.extend([mode,w,h,w,h,alpha,key,2 if bad else 0,bad,size])
                        inputs.extend(a);auxiliary.extend(b)
                        outputs.extend(v | (int(i==0)<<33) | (int(i%w==w-1)<<32) for i,v in enumerate(result))
        for mode,w,h,dw,dh,alpha,key,error in [(4,2,2,2,2,0,0,1),(15,2,2,2,2,0,0,1),
            (0,0,2,0,2,0,0,2),(1,9,2,9,2,0,0,2),(2,2,7,2,7,0,0,2),
            (1,2,2,3,2,0,0,2),(1,2,2,2,2,257,0,2),(1,2,2,2,2,0xffffffff,0,2),
            (2,2,2,2,2,128,0x1000000,2)]:commands.extend([mode,w,h,dw,dh,alpha,key,error,0,0])
    else:
        for mode in range(5):commands.extend([mode,2,2,2,2,128,0,1 if mode>3 else 2,0,0])
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',auxiliary),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:08x}\n') for v in values))
    return {'commands':len(commands)//10,'pixels':len(inputs)}

def main():
    evidence=evidence_dir('osd_adapter');cases=[]
    sources=[HERE/'rtl/cip_image_osd.v',HERE/'sim/tb_cip_image_osd.v',
        HERE.parent/'image/multiframe/img_mf_rgb_blend_pipe.v']
    tracked=[*sources,Path(__file__)]
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    with tempfile.TemporaryDirectory(prefix='cip_osd_') as temporary:
        for bits in [24,8,16,32]:
            folder=Path(temporary)/str(bits);folder.mkdir();counts=fixtures(folder,bits);binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_osd',f'-Ptb_cip_image_osd.DW={bits}',
                '-o',binary,*sources],HERE,evidence/f'w{bits}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',*[f'+{k}={v}' for k,v in counts.items()]],HERE,evidence/f'w{bits}_simulation.log')
            if f'OSD PASS width={bits}' not in output:raise RuntimeError('missing PASS')
            print(output.strip());cases.append({'width':bits,**counts,'scope':'functional' if bits==24 else 'rejection_only'})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):
        raise RuntimeError('source changed during regression')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run'})
    print(f'evidence={evidence}')

if __name__=='__main__':main()
