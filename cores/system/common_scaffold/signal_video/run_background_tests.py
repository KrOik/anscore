"""Stateful arbitrary-precision Qn.8 EWMA background reference and packet tests."""
from pathlib import Path
import random
import sys
import tempfile
import hashlib

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def fixtures(folder,bits):
    rng=random.Random(1783);commands=[];inputs=[];outputs=[];limit=(1<<bits)-1
    history=None;shape=None
    def frame(mode,w,h,image,threshold,shift,freeze=0,force=0,bad=0):
        nonlocal history,shape
        if bad==8:history=None;shape=None
        valid=history is not None and shape==(w,h) and not force
        next_history=[];numeric=[]
        for i,pixel in enumerate(image):
            old=history[i] if valid else pixel*256
            difference=abs(pixel-old//256) if valid else 0
            foreground=valid and difference>threshold
            updated=old if freeze and foreground else old+(pixel*256-old)//(1<<shift)
            value=[updated//256,difference,limit if foreground else 0,updated][mode]
            next_history.append(updated);numeric.append(value)
        words=(bits+8+bits-1)//bits if mode==3 else 1
        result=[]
        for i,value in enumerate(numeric):
            for word in range(words):
                result.append(((value>>(word*bits))&limit) | (int(i==0 and word==0)<<33) |
                    (int(i%w==w-1 and word==words-1)<<32))
        error=2 if bad in [1,2] else 0
        commands.extend([mode,w,h,w,h,threshold,shift|(freeze<<8)|(force<<9),error,bad,len(image),len(result)])
        inputs.extend(image);outputs.extend(result);history=None if error else next_history;shape=(w,h)
    for w,h in [(1,1),(1,6),(8,1),(3,3),(5,4),(8,6)]:
        size=w*h
        for i in range(20):
            mode=i%4;shift=[0,1,2,4,8][i%5]
            image=([0]*size if i%5==0 else [limit]*size if i%5==1 else [rng.getrandbits(bits) for _ in range(size)])
            frame(mode,w,h,image,[0,limit,limit//2][i%3],shift,freeze=i%2,force=int(i==12),
                bad=1 if i==7 else 2 if i==15 else 0)
    # Fractional convergence, signed negative rounding and freeze/no-freeze transitions.
    for pixel,mode,freeze in [(limit,3,0),(0,3,0),(0,3,0),(limit,1,1),(limit,2,1),(0,0,0)]:
        frame(mode,2,2,[pixel]*4,0,8,freeze)
    for bad in [8,0,8,0]:frame(3,2,2,[rng.getrandbits(bits) for _ in range(4)],0,1,bad=bad)
    for mode,w,h,dw,dh,p0,p1,error in [(4,2,2,2,2,0,0,1),(15,2,2,2,2,0,0,1),
        (0,0,2,0,2,0,0,2),(0,9,2,9,2,0,0,2),(0,2,7,2,7,0,0,2),(0,2,2,3,2,0,0,2),
        (0,2,2,2,2,0,9,2),(0,2,2,2,2,0,0x10,2),(0,2,2,2,2,0,0x400,2)]:
        commands.extend([mode,w,h,dw,dh,p0,p1,error,0,0,0])
    if bits<32:commands.extend([0,2,2,2,2,1<<bits,0,2,0,0,0])
    frame(3,2,2,[0]*4,0,8)  # Invalid commands must retain the committed model.
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',inputs),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:08x}\n') for v in values))
    return {'commands':len(commands)//11,'pixels':len(inputs),'outputs':len(outputs)}

def main():
    evidence=evidence_dir('background_model_adapter');cases=[]
    sources=[HERE/'rtl/cip_image_background_model.v',HERE/'sim/tb_cip_image_background_model.v']
    tracked=[*sources,Path(__file__)]
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    with tempfile.TemporaryDirectory(prefix='cip_background_') as temporary:
        for bits in [1,8,16,24,32]:
            folder=Path(temporary)/str(bits);folder.mkdir();counts=fixtures(folder,bits);binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_background_model',f'-Ptb_cip_image_background_model.DW={bits}',
                '-o',binary,*sources],HERE,evidence/f'w{bits}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',*[f'+{k}={v}' for k,v in counts.items()]],HERE,evidence/f'w{bits}_simulation.log')
            if f'BACKGROUND_MODEL PASS width={bits}' not in output:raise RuntimeError('missing PASS')
            print(output.strip());cases.append({'width':bits,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):
        raise RuntimeError('source changed during regression')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run'})
    print(f'evidence={evidence}')

if __name__=='__main__':main()
