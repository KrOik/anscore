"""Normal Bayer and cropped-center bypass, independent full-size RAW golden."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P=ROOT/'cores/image_processing/isp_stream'


def main():
    sources=[P/'rtl/raw_bayer_mode_stream.v',P/'tb/tb_raw_bayer_mode_stream.v',
             ROOT/'cores/system/common_scaffold/image/window/img_window3x3_valid_draft.v',
             ROOT/'cores/system/common_scaffold/image/isp/img_isp_bayer_interpolate.v']
    out=ROOT/'artifacts/isp_stream_25k'/datetime.now(timezone.utc).strftime('bayer_modes_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    report={'status':'IN_PROGRESS','sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]},'cases':[]}
    try:
        for bits in (8,10,12):
            exe=out/f'raw{bits}.vvp'
            run=subprocess.run(['iverilog','-g2012','-s','tb_raw_bayer_mode_stream','-P',f'tb_raw_bayer_mode_stream.RAW_BITS={bits}','-o',str(exe)]+list(map(str,sources)),capture_output=True,text=True)
            (out/f'compile{bits}.log').write_text(run.stdout+run.stderr)
            if run.returncode:raise RuntimeError(run.stderr)
            actual_path=out/f'raw{bits}.bin'
            run=subprocess.run(['vvp',str(exe),'+output='+str(actual_path)],capture_output=True,text=True,timeout=180)
            (out/f'run{bits}.log').write_text(run.stdout+run.stderr)
            match=re.search(r'PASS Bayer mode stream bits=(\d+) pixels=(\d+)',run.stdout)
            if run.returncode or not match or int(match[1])!=bits:raise RuntimeError(run.stdout+run.stderr)
            golden=bytearray();mask=(1<<bits)-1
            for f in range(9):
                w=320 if f==4 else 640 if f==5 else 3 if f in (6,8) else 5 if f==7 else 7
                h=240 if f==4 else 480 if f==5 else 3 if f in (6,8) else 5 if f==7 else 6
                raw=[[(23*x+37*y+57*f)&mask for x in range(w)] for y in range(h)]
                for y in range(1,h-1):
                    for x in range(1,w-1):
                        c=raw[y][x]
                        horizontal=(raw[y][x-1]+raw[y][x+1]+1)//2
                        vertical=(raw[y-1][x]+raw[y+1][x]+1)//2
                        cross=(raw[y-1][x]+raw[y][x-1]+raw[y][x+1]+raw[y+1][x]+2)//4
                        diag=(raw[y-1][x-1]+raw[y-1][x+1]+raw[y+1][x-1]+raw[y+1][x+1]+2)//4
                        rgb=(c,c,c) if f in (4,6,7) else ((c,cross,diag),(horizontal,c,vertical),(vertical,c,horizontal),(diag,cross,c))[((y&1)*2+(x&1))^(f%4)]
                        r,g,b=(v>>(bits-8) for v in rgb)
                        flags=int(x==1 and y==1)|(int(x==w-2)<<1)|(int(x==w-2 and y==h-2)<<2)
                        golden+=bytes((b,g,r,f,0,flags))
            actual=actual_path.read_bytes()
            if actual!=golden or len(actual)//6!=int(match[2]):
                mismatch=next((i for i,(a,b) in enumerate(zip(actual,golden)) if a!=b),None)
                raise RuntimeError(f'pixel/metadata mismatch byte={mismatch} lengths={len(actual)}/{len(golden)}')
            report['cases'].append({'raw_bits':bits,'pixels':len(actual)//6,'output_sha256':hashlib.sha256(actual).hexdigest(),'status':'PASS'})
            print(match[0])
        report['status']='PASS'
    except Exception as exc:
        report.update(status='FAIL',reason=str(exc));raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
