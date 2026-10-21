"""All AWB/CCM bypass combinations through actual canonical color stages."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P=ROOT/'cores/image_processing/isp_stream'


def main():
    sources=[P/'rtl/isp_mode_config.v',P/'rtl/rgb_color_chain.v',P/'tb/tb_isp_mode_color.v']+[
        ROOT/'cores/system/common_scaffold/image/isp'/s for s in ('img_isp_awb_gain.v','img_isp_ccm.v','img_isp_gamma_lut.v')]
    out=ROOT/'artifacts/isp_stream_25k'/datetime.now(timezone.utc).strftime('mode_color_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    report={'status':'IN_PROGRESS','sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]}}
    try:
        exe=out/'test.vvp'
        run=subprocess.run(['iverilog','-g2012','-s','tb_isp_mode_color','-o',str(exe)]+list(map(str,sources)),capture_output=True,text=True)
        (out/'compile.log').write_text(run.stdout+run.stderr)
        if run.returncode:raise RuntimeError(run.stderr)
        run=subprocess.run(['vvp',str(exe),'+output='+str(out/'pixels.bin')],capture_output=True,text=True,timeout=30)
        (out/'run.log').write_text(run.stdout+run.stderr)
        if run.returncode or 'PASS AWB/CCM identity bypass' not in run.stdout:raise RuntimeError(run.stdout+run.stderr)
        golden=bytearray()
        for f in range(4):
            for p in range(16):
                rgb=[(f*57+p*17)&255,(37+p*13)&255,(93+p*9)&255]
                gains=(256,256,256) if f&1 else (300,200,400)
                gained=[min(255,(v*g+128)//256) for v,g in zip(rgb,gains)]
                rows=((1024,0,0),(0,1024,0),(0,0,1024)) if f&2 else ((1024,128,-64),(-128,1024,128),(64,-128,1024))
                bias=(0,0,0) if f&2 else (-5,3,7)
                r,g,b=[max(0,min(255,(sum(a*v for a,v in zip(row,gained))+512)//1024+b)) for row,b in zip(rows,bias)]
                flags=int(p==0)|(int(p%4==3)<<1)|(int(p==15)<<2)
                golden+=bytes((b,g,r,f,0,flags))
        actual=(out/'pixels.bin').read_bytes()
        if actual!=golden:raise RuntimeError('AWB/CCM bypass golden mismatch')
        report.update(status='PASS',pixels=64,ordered_modes=['both enabled','AWB bypass','CCM bypass','AWB+CCM bypass'],output_sha256=hashlib.sha256(actual).hexdigest())
        print(run.stdout.splitlines()[0])
    except Exception as exc:
        report.update(status='FAIL',reason=str(exc));raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
