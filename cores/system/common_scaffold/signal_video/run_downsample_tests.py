"""Independent exact overlap-area and point-decimation reference."""
from pathlib import Path
import random,sys,tempfile,hashlib
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def reference(image,w,h,dw,dh,bits,lanes,mode,sx,sy):
    if mode:return [image[y*w+x] for y in range(0,h,sy) for x in range(0,w,sx)]
    result=[];mask=(1<<bits)-1
    for oy in range(dh):
        for ox in range(dw):
            sums=[0]*lanes
            for iy in range(h):
                wy=max(0,min((iy+1)*dh,(oy+1)*h)-max(iy*dh,oy*h))
                for ix in range(w):
                    wx=max(0,min((ix+1)*dw,(ox+1)*w)-max(ix*dw,ox*w))
                    for lane in range(lanes):sums[lane]+=((image[iy*w+ix]>>(lane*bits))&mask)*wx*wy
            result.append(sum(((v+w*h//2)//(w*h))<<(lane*bits) for lane,v in enumerate(sums)))
    return result

def fixtures(folder,bits,gray):
    rng=random.Random(1909);commands=[];inputs=[];outputs=[]
    supported=gray>0 and bits%gray==0 and bits<=32 and 1<=gray<=16
    def add(w,h,dw,dh,mode=0,sx=0,sy=0,error=0,bad=0,image=None):
        numeric=[]
        if image is not None:
            numeric=reference(image,w,h,dw,dh,gray,bits//gray,mode,sx,sy)
            if bad and mode==0:numeric=[]
        commands.extend([mode,w,h,dw,dh,sx,sy,error,bad,len(image or []),len(numeric)])
        inputs.extend(image or [])
        outputs.extend(v|(int(i==0)<<33)|(int(i%dw==dw-1)<<32) for i,v in enumerate(numeric))
    if supported:
        for w,h in [(1,1),(1,6),(8,1),(3,3),(5,4),(8,6)]:
            for dw in sorted(set([1,w,max(1,w-1),max(1,w//2)])):
                for dh in sorted(set([1,h,max(1,h-1),max(1,h//2)])):
                    for pattern in range(3):
                        image=[rng.getrandbits(bits) for _ in range(w*h)]
                        if pattern==0:image=[(1<<bits)-1]*(w*h)
                        if pattern==1:image=[((1<<bits)-1) if i%2 else 0 for i in range(w*h)]
                        add(w,h,dw,dh,image=image)
            for sx,sy in [(1,1),(2,3),(7,5),(65535,65535)]:
                add(w,h,(w+sx-1)//sx,(h+sy-1)//sy,1,sx,sy,image=[rng.getrandbits(bits) for _ in range(w*h)])
        for mode in [0,1]:
            for bad in [1,2]:add(5,4,3,2,mode,2 if mode else 0,2 if mode else 0,2,bad,[rng.getrandbits(bits) for _ in range(20)])
        for args in [(0,2,0,1,0,0,0,2),(9,2,1,1,0,0,0,2),(2,7,1,1,0,0,0,2),(2,2,3,1,0,0,0,2),(2,2,1,1,0,1,0,2),(2,2,1,1,1,0,1,2),(2,2,1,1,1,65536,1,2),(2,2,2,2,1,2,2,2),(2,2,1,1,2,0,0,1)]:add(*args)
    else:add(2,2,1,1,error=2)
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',inputs),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:08x}\n') for v in values))
    return {'commands':len(commands)//11,'pixels':len(inputs),'outputs':len(outputs),'width':bits,'gray':gray,'scope':'functional' if supported else 'rejection_only'}

def main():
    evidence=evidence_dir('downsample_adapter');cases=[]
    sources=[HERE/'rtl/cip_image_downsample.v',HERE/'sim/tb_cip_image_downsample.v',HERE.parent/'image/geometry/rtl/img_geo_area_resample.v',HERE.parent/'image/geometry/rtl/img_geo_crop_decimate.v',HERE.parent/'image/geometry/rtl/geo_serial_divider.v']
    tracked=[*sources,Path(__file__)]
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    with tempfile.TemporaryDirectory(prefix='cip_downsample_') as temporary:
        for bits,gray in [(1,1),(8,8),(12,12),(24,8),(32,16),(7,8),(24,0)]:
            label=f'w{bits}_g{gray}';folder=Path(temporary)/label;folder.mkdir();counts=fixtures(folder,bits,gray);binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_downsample',f'-Ptb_cip_image_downsample.DW={bits}',
                f'-Ptb_cip_image_downsample.GB={gray}','-o',binary,*sources],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["pixels"]}',f'+outputs={counts["outputs"]}'],HERE,evidence/f'{label}_simulation.log')
            if f'DOWNSAMPLE PASS width={bits}' not in output:raise RuntimeError('missing PASS')
            print(output.strip());cases.append(counts)
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):raise RuntimeError('source changed')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run'})
    print(f'evidence={evidence}')

if __name__=='__main__':main()
