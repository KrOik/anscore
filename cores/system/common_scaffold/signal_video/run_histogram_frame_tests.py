"""Independent global histogram and CDF-min normalized HE frame regression."""
from pathlib import Path
import random
import hashlib
import sys
import tempfile

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def equalize(image):
    counts=[image.count(i) for i in range(256)]
    cdf=0;minimum=next(c for c in counts if c);lut=[]
    for i,count in enumerate(counts):
        cdf+=count
        lut.append(i if minimum==len(image) else max(0,(cdf-minimum)*255//(len(image)-minimum)))
    return counts,[lut[v] for v in image]

def fixtures(folder,adapter=0,bits=32,hist=1):
    rng=random.Random(2307);commands=[];inputs=[];outputs=[]
    def add(op,w,h,image,bad=0,error=0):
        if image is None:
            commands.extend([op,w,h,error,bad,0,0]);return
        algorithm=(0 if hist else 1) if adapter else op
        numeric=equalize(image)[algorithm];result=[]
        words=(32+bits-1)//bits if adapter and hist else 1
        for i,value in enumerate(numeric):
            for word in range(words):
                data=(value>>(word*bits))&((1<<bits)-1)
                sof=i==0 and word==0
                eol=(i==255 if algorithm==0 else i%w==w-1) and word==words-1
                result.append(data | (int(sof)<<33) | (int(eol)<<32))
        commands.extend([op,w,h,error,bad,len(image),len(result)])
        inputs.extend(image);outputs.extend(result)
    for op in ([0] if adapter else [0,1]):
        for w,h in [(1,1),(1,6),(8,1),(3,3),(5,4),(8,6)]:
            for pattern in range(7):
                size=w*h
                image=[[0]*size,[255]*size,[137]*size,
                    [i%256 for i in range(size)],
                    [0 if i%2 else 255 for i in range(size)],
                    [rng.randrange(256) for _ in range(size)],
                    [91 if i<size-1 else 92 for i in range(size)]][pattern]
                bad=int(pattern==5)
                add(op,w,h,image,bad,2 if bad else 0)
    for op in ([0] if adapter else [0,1]):add(op,32,16,[91]*503+[92]*9)
    for w,h in [(0,2),(33,2),(2,17)]:add(0,w,h,None,error=2)
    if adapter:
        add(1,2,2,None,error=1);add(15,2,2,None,error=1)
        for bad in [4,5,6]:add(0,2,2,None,bad,2)
        add(0,2,2,[1,2,3,4],7,2)
        if bits>8:add(0,2,2,[1,2,3,4],3,2)
    for name,values in [('commands',commands),('inputs',inputs),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:08x}\n') for v in values))
    return {'commands':len(commands)//7,'pixels':len(inputs),'outputs':len(outputs)}


def main():
    evidence=evidence_dir('histogram_frame')
    sources=[HERE/'rtl/cip_image_histogram_frame.v',HERE.parent/'image/histogram/rtl/img_hist_ratio_u8.v',
        HERE/'sim/tb_cip_image_histogram_frame.v',HERE/'rtl/cip_image_histogram.v',HERE/'rtl/cip_image_he.v']
    tracked=[*sources,Path(__file__)]
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    cases=[]
    with tempfile.TemporaryDirectory(prefix='cip_hist_') as temporary:
        profiles=[(0,32,1)]+[(1,b,h) for h in [0,1] for b in [8,12,16,24,32]]
        for adapter,bits,hist in profiles:
            label=f'a{adapter}_w{bits}_h{hist}';folder=Path(temporary)/label;folder.mkdir()
            counts=fixtures(folder,adapter,bits,hist);binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_histogram_frame',
                f'-Ptb_cip_image_histogram_frame.ADAPTER={adapter}',f'-Ptb_cip_image_histogram_frame.DW={bits}',
                f'-Ptb_cip_image_histogram_frame.HIST={hist}','-o',binary,*sources],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',*[f'+{k}={v}' for k,v in counts.items()]],HERE,evidence/f'{label}_simulation.log')
            if f'HISTOGRAM_FRAME PASS commands={counts["commands"]}' not in output:raise RuntimeError('missing PASS')
            print(output.strip());cases.append({'adapter':adapter,'width':bits,'histogram':hist,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):
        raise RuntimeError('source changed during regression')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run','scope':'engine plus serialized histogram and HE adapters'})
    print(f'evidence={evidence}')

if __name__=='__main__':main()
