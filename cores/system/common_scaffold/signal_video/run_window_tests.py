"""Independent 2-D row-major window serialization oracle."""
from pathlib import Path
import sys
import random
import tempfile
import hashlib

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json


def fixtures(folder,bits):
    rng=random.Random(88317)
    commands=[];inputs=[];outputs=[]
    def add(w,h,image=None,mode=0,error=0,bad=0,dims=None,p0=0,p1=0):
        dw,dh=dims or (w-2,h-2)
        expected=[]
        if image is not None:
            for y in range(h-2):
                for x in range(w-2):
                    for dy in range(3):
                        for dx in range(3):
                            v=image[(y+dy)*w+x+dx]
                            expected.append(v | (int(x==0 and y==0 and dx==0 and dy==0)<<33) |
                                            (int(x==w-3 and dx==2 and dy==2)<<32))
        commands.extend([mode,w,h,dw,dh,p0,p1,error,bad,len(image or []),len(expected)])
        inputs.extend(image or []);outputs.extend(expected)
    if 1<=bits<=32:
        for w,h in [(3,3),(3,6),(8,3),(4,5),(7,4),(8,6)]:
            for pattern in range(5):
                image=[rng.getrandbits(bits) for _ in range(w*h)]
                if pattern==0:image=[0]*(w*h)
                if pattern==1:image=[(1<<bits)-1]*(w*h)
                if pattern==2:image=[i% (1<<bits) for i in range(w*h)]
                if pattern==3:image=[(1<<bits)-1 if (i%w+i//w)%2 else 0 for i in range(w*h)]
                add(w,h,image)
        for bad in (1,2):add(5,4,[rng.getrandbits(bits) for _ in range(20)],error=2,bad=bad)
        for w,h in [(0,3),(2,3),(3,2),(9,3),(3,7)]:add(w,h,error=2,dims=(1,1))
        add(3,3,error=2,dims=(2,1));add(3,3,error=2,p0=1);add(3,3,error=2,p1=1)
        add(3,3,mode=1,error=1)
        add(3,3,[0]*9)
    else:
        add(3,3,error=2);add(3,3,mode=1,error=1)
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',[0]*len(inputs)),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join(format(v,'09x' if name=='expected' else '08x')+'\n' for v in values))
    return {'commands':len(commands)//11,'inputs':len(inputs),'outputs':len(outputs),'reset_cases':3 if 1<=bits<=32 else 0}


def main():
    evidence=evidence_dir('window_adapter');results=[]
    sources=[HERE/'rtl/cip_image_window.v',HERE.parent/'image/window/img_window3x3_valid_draft.v',HERE/'sim/tb_cip_image_window.v']
    tracked=[*sources,Path(__file__)]
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    with tempfile.TemporaryDirectory(prefix='cip_window_') as temporary:
        for bits in (1,8,12,24,32,33):
            label=f'w{bits}';folder=Path(temporary)/label;folder.mkdir();counts=fixtures(folder,bits);binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_window',f'-Ptb_cip_image_window.DW={bits}','-o',binary,*sources],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["inputs"]}',f'+outputs={counts["outputs"]}'],HERE,evidence/f'{label}_simulation.log')
            if f'WINDOW PASS width={bits} commands={counts["commands"]} pixels={counts["outputs"]}' not in output:raise RuntimeError('Missing window PASS marker')
            print(output.strip());results.append({'data_w':bits,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):raise RuntimeError('Source changed during tests')
    write_json(evidence/'summary.json',{'status':'PASS','cases':results,'source_sha256':hashes,'synthesis':'not_run','board':'not_run'})
    print(f'evidence={evidence}')


if __name__=='__main__':main()
