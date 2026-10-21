"""Word-preserving mirror/flip and right-angle rotation reference regression."""
from pathlib import Path
import random
import sys
import hashlib
import tempfile

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def reference(image,w,h,mode,rotate):
    rows=[image[y*w:(y+1)*w] for y in range(h)]
    if rotate:
        if mode==1:rows=[list(col) for col in zip(*rows[::-1])]
        elif mode==2:rows=[row[::-1] for row in rows[::-1]]
        elif mode==3:rows=[list(col) for col in zip(*rows)][::-1]
    else:
        if mode&1:rows=[row[::-1] for row in rows]
        if mode&2:rows=rows[::-1]
    return [v for row in rows for v in row],len(rows[0]),len(rows)

def fixtures(folder,bits,rotate):
    rng=random.Random(937);commands=[];inputs=[];outputs=[];limit=(1<<bits)-1
    for mode in range(4):
        for w,h in [(1,1),(1,6),(8,1),(3,3),(5,4),(8,6)]:
            for pattern in range(6):
                size=w*h
                image=[[0]*size,[limit]*size,[i&limit for i in range(size)],
                    [rng.getrandbits(bits) for _ in range(size)],
                    [limit if i%2 else 0 for i in range(size)],
                    [(i*0x5321a9)&limit for i in range(size)]][pattern]
                result,dw,dh=reference(image,w,h,mode,rotate)
                bad=1 if pattern==3 else 2 if pattern==5 else 0
                commands.extend([mode,w,h,dw,dh,0,0,2 if bad else 0,bad,size]);inputs.extend(image)
                outputs.extend(v | (int(i==0)<<33) | (int(i%dw==dw-1)<<32) for i,v in enumerate(result))
    for mode,w,h,dw,dh,p0,p1,error in [(6 if rotate else 4,2,2,2,2,0,0,1),(15,2,2,2,2,0,0,1),
        (0,0,2,0,2,0,0,2),(0,9,2,9,2,0,0,2),(0,2,7,2,7,0,0,2),
        (0,2,2,3,2,0,0,2),(0,2,2,2,2,1,0,2),(0,2,2,2,2,0,1,2)]:
        commands.extend([mode,w,h,dw,dh,p0,p1,error,0,0])
    for name,values in [('commands',commands),('inputs',inputs),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:08x}\n') for v in values))
    return {'commands':len(commands)//10,'pixels':len(inputs)}

def main():
    evidence=evidence_dir('permutation_adapters');cases=[]
    sources=[HERE/'rtl'/f'{name}.v' for name in ['cip_image_permute_frame','cip_image_mirror_flip','cip_image_rotate','cip_image_rotate_angle_frame']]
    sources.append(HERE/'sim/tb_cip_image_permutation.v')
    sources += [HERE.parents[2]/line.strip() for line in (HERE.parent/'image/rtl_sources.f').read_text().splitlines()
                if line.strip() and not line.startswith('#')]
    tracked=[*sources,Path(__file__)]
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    with tempfile.TemporaryDirectory(prefix='cip_permute_') as temporary:
        for rotate in [0,1]:
            for bits in [1,8,16,24,32]:
                label=f'r{rotate}_w{bits}';folder=Path(temporary)/label;folder.mkdir()
                counts=fixtures(folder,bits,rotate);binary=folder/'test.vvp'
                execute(['iverilog','-g2012','-s','tb_cip_image_permutation',f'-Ptb_cip_image_permutation.DW={bits}',
                    f'-Ptb_cip_image_permutation.ROTATE={rotate}','-o',binary,*sources],HERE,evidence/f'{label}_compile.log')
                output=execute(['vvp',binary,f'+folder={folder}',*[f'+{k}={v}' for k,v in counts.items()]],HERE,evidence/f'{label}_simulation.log')
                if f'PERMUTATION PASS width={bits}' not in output:raise RuntimeError('missing PASS')
                print(output.strip());cases.append({'width':bits,'rotate':rotate,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):
        raise RuntimeError('source changed during regression')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run'})
    print(f'evidence={evidence}')

if __name__=='__main__':main()
