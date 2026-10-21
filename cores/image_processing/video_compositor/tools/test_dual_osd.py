"""Independent integer golden for two canonical RGB alpha/key layers."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import random
import re
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/image_processing/video_compositor'


def blend(base,aux,weight):
    return sum((((((base>>shift)&255)*(256-weight)+((aux>>shift)&255)*weight+128)>>8)&255)<<shift for shift in (0,8,16))


def main():
    out=ROOT/'artifacts/video_compositor_25k'/datetime.now(timezone.utc).strftime('dual_osd_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/dual_osd_stream.v',P/'tb/tb_dual_osd_stream.v',ROOT/'cores/system/common_scaffold/image/multiframe/img_mf_rgb_blend_pipe.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        rng=random.Random(0x2508);vectors=[];expected=[]
        for n in range(1024):
            base,a,b=[rng.randrange(1<<24) for _ in range(3)]
            key0=a if n%3==0 else rng.randrange(1<<24);key1=b if n%5==0 else rng.randrange(1<<24)
            alpha0=[0,1,64,128,255,256,257,511][n%8];alpha1=rng.choice([0,1,32,128,255,256,257,511])
            enable=(n//8)%4;key_enable=(n//32)%4
            sof=int(n%64==0);eol=int(n%8==7);last=int(n%64==63);frame=0x80000000+n//64
            error=int(bool((enable&1 and alpha0>256) or (enable&2 and alpha1>256)))
            pixel=base
            if enable&1 and not(key_enable&1 and a==key0):pixel=blend(pixel,a,alpha0) if not error else 0
            if enable&2 and not(key_enable&2 and b==key1):pixel=blend(pixel,b,alpha1) if not error else 0
            if error:pixel=0
            vectors.append(base|(a<<24)|(b<<48)|(key0<<72)|(key1<<96)|(alpha0<<120)|(alpha1<<129)|(enable<<138)|(key_enable<<140)|(sof<<142)|(eol<<143)|(last<<144)|(n<<145)|(frame<<161))
            expected.append((n,pixel,sof,eol,last,n,frame,error))
        mem=out/'vectors.mem';mem.write_text(''.join(f'{v:049x}\n' for v in vectors))
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_dual_osd_stream','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe),'+fixture='+str(mem)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError('\n'.join((r.stdout+r.stderr).splitlines()[-12:]))
        actual=[tuple(map(int,x)) for x in re.findall(r'OSD index=(\d+) rgb=(\d+) sof=(\d+) eol=(\d+) last=(\d+) user=(\d+) frame=(\d+) error=(\d+)',r.stdout)]
        if actual!=expected or 'PASS dual OSD stream' not in r.stdout:raise RuntimeError('independent RGB/metadata mismatch')
        report.update(status='PASS',pixels=1024,scope='two-layer elastic RGB/key/alpha arithmetic; multi-output timing/config/25K board pending')
        print('PASS dual OSD:1024exact pixels/metadata,alpha/key/enable/errors,randomgaps/stalls')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
