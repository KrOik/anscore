"""RGB pass-through plus independent per-frame sums/counts/saturation oracle."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/image_processing/isp_stream'


def main():
    sources = [P / 'rtl/rgb_frame_statistics.v', ROOT / 'cores/system/common_scaffold/image/isp/img_isp_awb_stats.v', P / 'tb/tb_rgb_frame_statistics.v']
    out = ROOT / 'artifacts/isp_stream_25k' / datetime.now(timezone.utc).strftime('statistics_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [Path(__file__).resolve()]}, 'cases': []}
    try:
        golden = bytearray()
        frames = []
        for f in range(4):
            width = (1,5,320,640)[f]
            height = (1,3,240,480)[f]
            sums = [0,0,0]
            for y in range(height):
                for x in range(width):
                    r,g,b = (x*19+y*31+f*43)&255, (x*37+y*17+f*11)&255, (x*7+y*53+f*29)&255
                    sums = [a+v for a,v in zip(sums,(r,g,b))]
                    flags = int(x==0 and y==0)|(int(x==width-1)<<1)|(int(x==width-1 and y==height-1)<<2)
                    golden += bytes((b,g,r,f+200,0,flags))
            frames.append((f+200,width*height,height,sums))
        for bits in (48,8):
            exe = out / f'sum{bits}.vvp'
            build = subprocess.run(['iverilog','-g2012','-s','tb_rgb_frame_statistics','-P',
                f'tb_rgb_frame_statistics.SUM_WIDTH={bits}','-o',str(exe)] + list(map(str,sources)),capture_output=True,text=True)
            (out / f'compile{bits}.log').write_text(build.stdout+build.stderr)
            if build.returncode:raise RuntimeError(build.stderr)
            pixels = out / f'rgb{bits}.bin'
            run = subprocess.run(['vvp',str(exe),'+output='+str(pixels)],capture_output=True,text=True,timeout=90)
            (out / f'run{bits}.log').write_text(run.stdout+run.stderr)
            if run.returncode or f'PASS frame statistics SUM_WIDTH={bits}' not in run.stdout:
                raise RuntimeError(run.stdout+run.stderr)
            actual = pixels.read_bytes()
            if actual!=golden:raise RuntimeError('pass-through pixels/metadata mismatch')
            rows = re.findall(r'STATS id=(\d+) pixels=(\d+) lines=(\d+) r=(\d+) g=(\d+) b=(\d+) overflow=(\d+)',run.stdout)
            limit=(1<<bits)-1
            expected=[(fid,count,lines,*[min(limit,s) for s in sums],int(any(s>limit for s in sums))) for fid,count,lines,sums in frames]
            if [tuple(map(int,row)) for row in rows]!=expected:raise RuntimeError('sum/count/overflow golden mismatch')
            report['cases'].append({'sum_width':bits,'pixels':len(actual)//6,'frames':4,
                'output_sha256':hashlib.sha256(actual).hexdigest(),'stats':expected,'status':'PASS'})
            print(f'PASS frame statistics SUM_WIDTH={bits},384016pixels,4snapshots independent golden')
        report['status']='PASS'
    except Exception as exc:
        report.update(status='FAIL',reason=str(exc));raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
        print('Evidence='+str(out))


if __name__=='__main__':main()
