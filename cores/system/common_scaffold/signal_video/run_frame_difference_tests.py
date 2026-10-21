"""Paired and internal-history grayscale difference with independent frame model."""
from pathlib import Path
import random
import sys
import tempfile
import hashlib

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def fixtures(folder,bits):
    rng=random.Random(1771);commands=[];inputs=[];auxiliary=[];outputs=[]
    limit=(1<<bits)-1;history=None;shape=None
    def frame(mode,w,h,current,previous,threshold=0,bad=0):
        nonlocal history,shape
        if bad==8:history=None;shape=None
        reference=previous if mode<2 else (history if shape==(w,h) and history is not None else current)
        differences=[abs(a-b) for a,b in zip(current,reference)]
        result=[limit if d>threshold else 0 for d in differences] if mode&1 else differences
        error=2 if bad in [1,2,3,4] else 0
        commands.extend([mode,w,h,w,h,threshold,0,error,bad,len(current)])
        inputs.extend(current);auxiliary.extend(previous)
        outputs.extend(v | (int(i==0)<<33) | (int(i%w==w-1)<<32) for i,v in enumerate(result))
        if mode>=2:history=None if error else list(current);shape=(w,h)
    for w,h in [(1,1),(1,6),(8,1),(3,3),(5,4),(8,6)]:
        size=w*h
        for i,mode in enumerate([2,2,3,0,1,3,2,0,3,2,3,2]):
            a=[rng.getrandbits(bits) for _ in range(size)]
            b=[rng.getrandbits(bits) for _ in range(size)]
            if i==0:a=[0]*size
            if i==1:a=[limit]*size
            if i==3:a=[0]*size;b=[limit]*size
            threshold=[0,limit,limit//2][i%3]
            bad={5:1,7:3,9:2}.get(i,0)
            frame(mode,w,h,a,b,threshold,bad)
    # Strict threshold ties, paired auxiliary EOL errors, and reset of committed history.
    for mode in [0,1,2,3]:
        frame(mode,2,2,[0,limit,0,limit],[0,0,limit,limit],limit,4 if mode==0 else 0)
    for mode,bad in [(2,0),(2,0),(2,8),(3,0),(3,8),(2,0)]:
        frame(mode,2,2,[rng.getrandbits(bits) for _ in range(4)],[0]*4,0,bad)
    for mode,w,h,dw,dh,threshold,param1,error in [
        (4,2,2,2,2,0,0,1),(15,2,2,2,2,0,0,1),(0,0,2,0,2,0,0,2),
        (0,9,2,9,2,0,0,2),(0,2,7,2,7,0,0,2),(0,2,2,3,2,0,0,2),(0,2,2,2,2,0,1,2)]:
        commands.extend([mode,w,h,dw,dh,threshold,param1,error,0,0])
    if bits<32:commands.extend([0,2,2,2,2,1<<bits,0,2,0,0])
    frame(2,2,2,[0]*4,[0]*4)  # Rejected commands must preserve committed history.
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',auxiliary),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:08x}\n') for v in values))
    return {'commands':len(commands)//10,'pixels':len(inputs)}

def main():
    evidence=evidence_dir('frame_difference_adapter');cases=[]
    sources=[HERE/'rtl/cip_image_frame_difference.v',HERE/'sim/tb_cip_image_frame_difference.v']
    tracked=[*sources,Path(__file__)]
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    with tempfile.TemporaryDirectory(prefix='cip_difference_') as temporary:
        for bits in [1,8,16,24,32]:
            folder=Path(temporary)/str(bits);folder.mkdir();counts=fixtures(folder,bits);binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_frame_difference',f'-Ptb_cip_image_frame_difference.DW={bits}',
                '-o',binary,*sources],HERE,evidence/f'w{bits}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',*[f'+{k}={v}' for k,v in counts.items()]],HERE,evidence/f'w{bits}_simulation.log')
            if f'FRAME_DIFFERENCE PASS width={bits}' not in output:raise RuntimeError('missing PASS')
            print(output.strip());cases.append({'width':bits,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):
        raise RuntimeError('source changed during regression')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run'})
    print(f'evidence={evidence}')

if __name__=='__main__':main()
