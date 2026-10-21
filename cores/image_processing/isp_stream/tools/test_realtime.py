"""Actual synthesizable source -> ISP chain, 50MHz/30fps finite simulation."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/image_processing/isp_stream'


def golden_frame(w, h, f):
    raw = [[(71+23*x+37*y+57*f)&1023 for x in range(w)] for y in range(h)]
    rgb, luma = [], []
    for y in range(1, h-1):
        row = []
        for x in range(1, w-1):
            c = raw[y][x]
            horizontal = (raw[y][x-1]+raw[y][x+1]+1)//2
            vertical = (raw[y-1][x]+raw[y+1][x]+1)//2
            cross = (raw[y-1][x]+raw[y][x-1]+raw[y][x+1]+raw[y+1][x]+2)//4
            diag = (raw[y-1][x-1]+raw[y-1][x+1]+raw[y+1][x-1]+raw[y+1][x+1]+2)//4
            r, g, b = ((c,cross,diag),(horizontal,c,vertical),(vertical,c,horizontal),(diag,cross,c))[(y&1)*2+(x&1)]
            r, g, b = r>>2, g>>2, b>>2
            rgb.append((r,g,b));row.append((r+2*g+b)>>2)
        luma.append(row)
    output = bytearray()
    for y in range(1, h-3):
        for x in range(1, w-3):
            gx = sum(k*(luma[y+dy][x+1]-luma[y+dy][x-1]) for dy,k in ((-1,1),(0,2),(1,1)))
            gy = sum(k*(luma[y+1][x+dx]-luma[y-1][x+dx]) for dx,k in ((-1,1),(0,2),(1,1)))
            value = luma[y][x] if f%2 else min(255,(abs(gx)+abs(gy))>>2)
            flags = int(x==1 and y==1)|(int(x==w-4)<<1)|(int(x==w-4 and y==h-4)<<2)
            output += bytes((value,f,0,flags))
    stats = (w,h,f,(w-2)*(h-2),h-2) + tuple(sum(p[c] for p in rgb) for c in range(3))
    return output, stats


def main():
    sources = sorted((P/'rtl').glob('*.v')) + [ROOT/'cores/system/common_scaffold/image'/s for s in (
        'pipelines/img_bayer_window_frontend_draft.v','window/img_window3x3_valid_draft.v',
        'isp/img_isp_bayer_interpolate.v','isp/img_isp_awb_gain.v','isp/img_isp_ccm.v','isp/img_isp_gamma_lut.v','isp/img_isp_awb_stats.v',
        'filters/rtl/img_edge_sobel3x3.v','filters/rtl/img_edge_gradient3x3.v','filters/rtl/img_filter_stream_register.v')] + [P/'tb/tb_isp_realtime.v']
    out = ROOT/'artifacts/isp_stream_25k'/datetime.now(timezone.utc).strftime('realtime_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status':'IN_PROGRESS','sources':{str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources+[Path(__file__).resolve()]}}
    try:
        exe = out/'test.vvp'
        run = subprocess.run(['iverilog','-g2012','-s','tb_isp_realtime','-o',str(exe)]+list(map(str,sources)),capture_output=True,text=True)
        (out/'compile.log').write_text(run.stdout+run.stderr)
        if run.returncode:
            raise RuntimeError(run.stderr)
        run = subprocess.run(['vvp',str(exe),'+output='+str(out/'pixels.bin')],capture_output=True,text=True,timeout=600)
        (out/'run.log').write_text(run.stdout+run.stderr)
        if run.returncode or 'PASS real-time RAW-to-Sobel' not in run.stdout:
            raise RuntimeError(run.stdout+run.stderr)
        expected = bytearray();stats = []
        for w,h,n in ((320,240,3),(640,480,2)):
            for f in range(n):
                pixels, snapshot = golden_frame(w,h,f);expected+=pixels;stats.append(snapshot)
        actual = (out/'pixels.bin').read_bytes()
        if actual!=expected:
            mismatch=next((i for i,(a,b) in enumerate(zip(actual,expected)) if a!=b),None)
            raise RuntimeError(f'pixel/metadata mismatch byte={mismatch} lengths={len(actual)}/{len(expected)}')
        found=re.findall(r'REALTIME_STATS size=(\d+)x(\d+) id=(\d+) pixels=(\d+) lines=(\d+) r=(\d+) g=(\d+) b=(\d+)',run.stdout)
        if [tuple(map(int,s)) for s in found]!=stats:
            raise RuntimeError('real-time RGB statistics mismatch')
        report.update(status='PASS',clock_hz=50000000,period_cycles=1666667,output_pixels=len(actual)//4,statistics=stats,output_sha256=hashlib.sha256(actual).hexdigest(),scope='finite simulation, not physical qualification')
        print(run.stdout)
    except Exception as exc:
        report.update(status='FAIL',reason=str(exc));raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':
    main()
