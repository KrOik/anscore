"""Actual synthesizable source -> ISP chain, 50MHz/30fps finite simulation."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/image_processing/isp_stream'


def golden_frame(mode):
    w=h=7;seed=(71+17*mode)&1023;pattern=mode%4;levels=(13,29,41,57)
    raw=[]
    for y in range(h):
        row=[]
        for x in range(w):
            v=(seed+23*x+37*y)&1023
            if not mode&1:v=max(0,min(1023,v-levels[((y&1)*2+(x&1))^pattern]+21))
            row.append(v)
        raw.append(row)
    sums=[0,0,0];luma=[]
    for y in range(1,h-1):
        row=[]
        for x in range(1,w-1):
            c=raw[y][x];horizontal=(raw[y][x-1]+raw[y][x+1]+1)//2;vertical=(raw[y-1][x]+raw[y+1][x]+1)//2
            cross=(raw[y-1][x]+raw[y][x-1]+raw[y][x+1]+raw[y+1][x]+2)//4
            diag=(raw[y-1][x-1]+raw[y-1][x+1]+raw[y+1][x-1]+raw[y+1][x+1]+2)//4
            rgb=(c,c,c) if mode&2 else ((c,cross,diag),(horizontal,c,vertical),(vertical,c,horizontal),(diag,cross,c))[((y&1)*2+(x&1))^pattern]
            rgb=[v>>2 for v in rgb]
            gains=(256,256,256) if mode&4 else (300,200,400)
            gained=[min(255,(v*g+128)//256) for v,g in zip(rgb,gains)]
            rows=((1024,0,0),(0,1024,0),(0,0,1024)) if mode&8 else ((1024,128,-64),(-128,1024,128),(64,-128,1024))
            bias=(0,0,0) if mode&8 else (-5,3,7)
            rgb=[max(0,min(255,(sum(a*v for a,v in zip(r,gained))+512)//1024+b)) for r,b in zip(rows,bias)]
            for channel in range(3):sums[channel]+=rgb[channel]
            row.append((rgb[0]+2*rgb[1]+rgb[2])>>2)
        luma.append(row)
    output=bytearray()
    for y in range(1,4):
        for x in range(1,4):
            gx=sum(k*(luma[y+d][x+1]-luma[y+d][x-1]) for d,k in ((-1,1),(0,2),(1,1)))
            gy=sum(k*(luma[y+1][x+d]-luma[y-1][x+d]) for d,k in ((-1,1),(0,2),(1,1)))
            value=luma[y][x] if mode&32 else min(255,(abs(gx)+abs(gy))>>2)
            flags=int(x==1 and y==1)|(int(x==3)<<1)|(int(x==3 and y==3)<<2)
            output+=bytes((value,0,0,flags))
    return output,sums


def main():
    sources = sorted((P/'rtl').glob('*.v')) + [ROOT/'cores/system/common_scaffold/image'/s for s in (
        'pipelines/img_bayer_window_frontend_draft.v','window/img_window3x3_valid_draft.v',
        'isp/img_isp_bayer_interpolate.v','isp/img_isp_awb_gain.v','isp/img_isp_ccm.v','isp/img_isp_gamma_lut.v','isp/img_isp_awb_stats.v',
        'filters/rtl/img_edge_sobel3x3.v','filters/rtl/img_edge_gradient3x3.v','filters/rtl/img_filter_stream_register.v')] + [P/'tb/tb_isp_all_modes.v', ROOT/'cores/system/stream_bus_library/rtl/sys_atomic_config.v',ROOT/'cores/system/stream_bus_library/rtl/sys_register_snapshot.v',ROOT/'cores/system/ip_test_shell/rtl/logic_probe8.v', ROOT/'cores/storage/buffer_dma/rtl/frame_stream_monitor.v']
    out = ROOT/'artifacts/isp_stream_25k'/datetime.now(timezone.utc).strftime('all_modes_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status':'IN_PROGRESS','sources':{str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources+[Path(__file__).resolve()]}}
    try:
        exe = out/'test.vvp'
        run = subprocess.run(['iverilog','-g2012','-s','tb_isp_all_modes','-o',str(exe)]+list(map(str,sources)),capture_output=True,text=True)
        (out/'compile.log').write_text(run.stdout+run.stderr)
        if run.returncode:
            raise RuntimeError(run.stderr)
        run = subprocess.run(['vvp',str(exe),'+output='+str(out/'pixels.bin')],capture_output=True,text=True,timeout=60)
        (out/'run.log').write_text(run.stdout+run.stderr)
        if run.returncode or 'PASS all64 ISP bypass combinations' not in run.stdout:
            raise RuntimeError(run.stdout+run.stderr)
        expected=bytearray();expected_stats={};expected_crc={}
        import zlib
        for mode in range(64):
            pixels,sums=golden_frame(mode);expected+=pixels
            expected_stats[mode+1]=sums;expected_crc[mode+1]=zlib.crc32(pixels[::4])
        actual = (out/'pixels.bin').read_bytes()
        if actual!=expected:
            mismatch=next((i for i,(a,b) in enumerate(zip(actual,expected)) if a!=b),None)
            raise RuntimeError(f'pixel/metadata mismatch byte={mismatch} lengths={len(actual)}/{len(expected)}')
        found={int(n):int(value,16) for n,value in re.findall(r'CONTROL_CRC run=(\d+) value=([0-9a-fA-F]+)',run.stdout)}
        if found!=expected_crc:raise RuntimeError(f'CRC mismatch {found} / {expected_crc}')
        for channel,offset in (('R',0),('G',1),('B',2)):
            found={int(n):int(value) for n,value in re.findall(r'CONTROL_'+channel+r' run=(\d+) value=(\d+)',run.stdout)}
            if found!={n:values[offset] for n,values in expected_stats.items()}:raise RuntimeError('CSR RGB statistics mismatch')
        report.update(status='PASS',output_pixels=len(actual)//4,run_crc=expected_crc,statistics=expected_stats,output_sha256=hashlib.sha256(actual).hexdigest(),scope='runtime control simulation, not physical qualification')
        print(run.stdout.splitlines()[-2])
    except Exception as exc:
        report.update(status='FAIL',reason=str(exc));raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':
    main()
