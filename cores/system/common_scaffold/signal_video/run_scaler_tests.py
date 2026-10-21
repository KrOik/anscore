"""Independent rational-coordinate nearest/bilinear scaler regression."""
from pathlib import Path
import sys
import random
import tempfile
import hashlib

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'integration'))
from tooling import evidence_dir, execute, write_json


def reference(image, w, h, dw, dh, mode, pw, lanes):
    result = []
    for y in range(dh):
        for x in range(dw):
            qx, qy = x*w*256//dw, y*h*256//dh
            ix, fx = divmod(qx, 256)
            iy, fy = divmod(qy, 256)
            if mode == 0:
                value = image[min(h-1, iy+(fy>=128))*w+min(w-1, ix+(fx>=128))]
            else:
                value = 0
                for lane in range(lanes):
                    mask = (1 << pw)-1
                    def sample(xx, yy):
                        return (image[min(h-1, yy)*w+min(w-1, xx)] >> (lane*pw)) & mask
                    total = (sample(ix, iy)*(256-fx)*(256-fy) +
                             sample(ix+1, iy)*fx*(256-fy) +
                             sample(ix, iy+1)*(256-fx)*fy + sample(ix+1, iy+1)*fx*fy)
                    value |= ((total+32768)//65536) << (lane*pw)
            result.append(value | (int(x == 0 and y == 0) << 33) | (int(x == dw-1) << 32))
    return result


def fixtures(folder, bits, pw):
    rng = random.Random(33127)
    commands, inputs, outputs = [], [], []
    supported = 1 <= pw <= 16 and pw <= bits <= 32 and bits % pw == 0
    def add(w,h,dw,dh,mode,image=None,error=0,bad=0,p0=0,p1=0):
        numeric = reference(image,w,h,dw,dh,mode,pw,bits//pw) if image is not None else []
        commands.extend([mode,w,h,dw,dh,p0,p1,error,bad,len(image) if image is not None else 0,len(numeric)])
        inputs.extend(image or [])
        outputs.extend(numeric)
    if supported:
        for w,h,dw,dh in [(1,1,3,2),(1,6,2,3),(8,1,3,2),(2,2,5,3),(5,4,3,2),(8,6,8,6),(7,5,4,3),(3,2,8,6)]:
            for mode in (0,1):
                for pattern in range(4):
                    image = [rng.randrange(1<<bits) for _ in range(w*h)]
                    if pattern==0: image=[0]*(w*h)
                    if pattern==1: image=[(1<<bits)-1]*(w*h)
                    if pattern==2: image=[((1<<bits)-1) if (i%w+i//w)%2 else 0 for i in range(w*h)]
                    add(w,h,dw,dh,mode,image)
        for bad in (1,2):
            # Framing failure aborts capture and emits no output in this core.
            image=[rng.randrange(1<<bits) for _ in range(12)]
            commands.extend([1,4,3,5,4,0,0,2,bad,12,0]);inputs.extend(image)
        for shape in [(0,2,2,2),(9,2,2,2),(2,7,2,2),(2,2,0,2),(2,2,2,0)]:add(*shape,0,error=2)
        add(2,2,2,2,3,error=1)
        add(2,2,2,2,0,error=2,p0=1)
        add(2,2,2,2,0,error=2,p1=1)
        add(2,2,3,3,1,[0]*4)
    else:
        add(2,2,2,2,0,error=2)
        add(2,2,2,2,3,error=1)
    for name, values in [('commands',commands),('inputs',inputs),('auxiliary',[0]*len(inputs)),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join(format(v, '09x' if name=='expected' else '08x')+'\n' for v in values))
    return {'commands':len(commands)//11,'inputs':len(inputs),'outputs':len(outputs),'reset_cases':3 if supported else 0}


def main():
    evidence=evidence_dir('scaler_adapter')
    sources=[HERE/'rtl/cip_image_scaler.v',HERE/'rtl/cip_image_bicubic_frame.v']
    sources += [HERE.parents[2]/line.strip() for line in (HERE.parent/'image/rtl_sources.f').read_text().splitlines() if line.strip() and not line.startswith('#')]
    tracked=[*sources,HERE/'sim/tb_cip_image_scaler.v',Path(__file__)]
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    results=[]
    with tempfile.TemporaryDirectory(prefix='cip_scaler_') as temporary:
        for bits,pw in [(1,1),(8,8),(12,12),(24,8),(32,16),(10,8),(24,17)]:
            label=f'dw{bits}_pw{pw}'
            folder=Path(temporary)/label;folder.mkdir()
            counts=fixtures(folder,bits,pw)
            binary=folder/'sim.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_scaler',f'-Ptb_cip_image_scaler.DW={bits}',f'-Ptb_cip_image_scaler.PW={pw}','-o',binary,*sources,HERE/'sim/tb_cip_image_scaler.v'],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["inputs"]}',f'+outputs={counts["outputs"]}'],HERE,evidence/f'{label}_simulation.log')
            marker=f'SCALER PASS width={bits} pixel={pw} commands={counts["commands"]} pixels={counts["outputs"]}'
            if marker not in output:raise RuntimeError('Missing scaler PASS marker')
            print(output.strip());results.append({'data_w':bits,'pixel_w':pw,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p)] for p in tracked):raise RuntimeError('Source changed during regression')
    write_json(evidence/'summary.json',{'status':'PASS','cases':results,'source_sha256':hashes,'synthesis':'not_run','board':'not_run'})
    print(f'evidence={evidence}')


if __name__=='__main__':main()
