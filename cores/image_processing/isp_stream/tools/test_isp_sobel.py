"""Exact full-size RAW/BLC/Bayer/AWB/CCM/Gamma independent golden."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/image_processing/isp_stream'


def main():
    sources = [P / 'rtl/raw_black_level_stream.v', P / 'rtl/raw_rgb_frontend.v', P / 'rtl/raw_bayer_mode_stream.v', P / 'rtl/rgb_color_chain.v', P / 'rtl/isp_stream_core.v', P / 'rtl/rgb_frame_statistics.v', P / 'rtl/isp_stream_with_statistics.v', P / 'rtl/gray_sobel_stream.v', P / 'rtl/isp_sobel_pipeline.v',
        ROOT / 'cores/system/common_scaffold/image/pipelines/img_bayer_window_frontend_draft.v',
        ROOT / 'cores/system/common_scaffold/image/window/img_window3x3_valid_draft.v',
        ROOT / 'cores/system/common_scaffold/image/isp/img_isp_bayer_interpolate.v',
        ROOT / 'cores/system/common_scaffold/image/isp/img_isp_awb_gain.v',
        ROOT / 'cores/system/common_scaffold/image/isp/img_isp_ccm.v',
        ROOT / 'cores/system/common_scaffold/image/isp/img_isp_gamma_lut.v', ROOT / 'cores/system/common_scaffold/image/isp/img_isp_awb_stats.v', P / 'tb/tb_isp_sobel_pipeline.v'] + [ROOT / 'cores/system/common_scaffold/image/filters/rtl' / n for n in ('img_edge_sobel3x3.v','img_edge_gradient3x3.v','img_filter_stream_register.v')]
    out = ROOT / 'artifacts/isp_stream_25k' / datetime.now(timezone.utc).strftime('isp_sobel_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [Path(__file__).resolve()]}, 'cases': []}
    try:
        for bits in (8, 10, 12):
            exe = out / f'raw{bits}.vvp'
            build = subprocess.run(['iverilog', '-g2012', '-s', 'tb_isp_sobel_pipeline', '-P',
                f'tb_isp_sobel_pipeline.RAW_BITS={bits}', '-o', str(exe)] + list(map(str, sources)), capture_output=True, text=True)
            (out / f'compile{bits}.log').write_text(build.stdout + build.stderr)
            if build.returncode:
                raise RuntimeError(build.stderr)
            pixels = out / f'raw{bits}.bin'
            run = subprocess.run(['vvp', str(exe), '+output=' + str(pixels)], capture_output=True, text=True, timeout=180)
            (out / f'run{bits}.log').write_text(run.stdout + run.stderr)
            match = re.search(r'PASS ISP Sobel bits=(\d+) pixels=(\d+) snapshots=7', run.stdout)
            if run.returncode or not match or int(match[1]) != bits:
                raise RuntimeError(run.stdout + run.stderr)
            golden = bytearray()
            final = bytearray()
            expected_stats=[]
            maximum = (1 << bits) - 1
            for f in range(7):
                start=len(golden)
                width = 320 if f == 4 else 640 if f == 5 else 5 if f == 6 else 5
                height = 240 if f == 4 else 480 if f == 5 else 5 if f == 6 else 5
                pattern = f % 4
                corrected = []
                for y in range(height):
                    row = []
                    for x in range(width):
                        plane = ((y % 2) ^ (pattern >> 1)) * 2 + ((x % 2) ^ (pattern & 1))
                        pixel = ((x * 23 + y * 37 + f * 57) & maximum) - ((plane * 13 + f * 7) & maximum) + maximum // 8
                        row.append(max(0, min(maximum, pixel)))
                    corrected.append(row)
                for y in range(1, height - 1):
                    for x in range(1, width - 1):
                        center = corrected[y][x]
                        h = (corrected[y][x-1] + corrected[y][x+1] + 1) // 2
                        v = (corrected[y-1][x] + corrected[y+1][x] + 1) // 2
                        cross = (corrected[y-1][x] + corrected[y][x-1] + corrected[y][x+1] + corrected[y+1][x] + 2) // 4
                        diag = (corrected[y-1][x-1] + corrected[y-1][x+1] + corrected[y+1][x-1] + corrected[y+1][x+1] + 2) // 4
                        site = ((y & 1) * 2 + (x & 1)) ^ pattern
                        r, g, b = ((center, cross, diag), (h, center, v), (v, center, h), (diag, cross, center))[site]
                        rgb8 = [v >> (bits-8) for v in (r,g,b)]
                        gained = [min(255,(pixel*gain+128)//256) for pixel,gain in zip(rgb8,(256+f*16,256-f*8,256+f*12))]
                        matrix = ((1024,128,-64),(-128,1024,128),(64,-128,1024)) if f%2 else ((1024,0,0),(0,1024,0),(0,0,1024))
                        biases = (-5,3,7) if f%2 else (0,0,0)
                        r,g,b = [min(255,max(0,(sum(a*v for a,v in zip(row,gained))+512)//1024+bias)) for row,bias in zip(matrix,biases)]
                        if f%2:r,g,b=(r*r+127)//255,255-g,(b+f*7)&255
                        flags = int(x == 1 and y == 1) | (int(x == width-2) << 1) | (int(x == width-2 and y == height-2) << 2)
                        golden += bytes((b, g, r, f, 0, flags))
                segment=golden[start:]
                expected_stats.append((f,(width-2)*(height-2),height-2,sum(segment[2::6]),sum(segment[1::6]),sum(segment[0::6])))
                iw,ih=width-2,height-2
                luma=[[(segment[(y*iw+x)*6+2]+2*segment[(y*iw+x)*6+1]+segment[(y*iw+x)*6])>>2 for x in range(iw)] for y in range(ih)]
                for y in range(1,ih-1):
                    for x in range(1,iw-1):
                        gx=sum(k*(luma[y+dy][x+1]-luma[y+dy][x-1]) for dy,k in ((-1,1),(0,2),(1,1)))
                        gy=sum(k*(luma[y+1][x+dx]-luma[y-1][x+dx]) for dx,k in ((-1,1),(0,2),(1,1)))
                        value=luma[y][x] if f%2 else min(255,(abs(gx)+abs(gy))>>2)
                        flags=int(x==1 and y==1)|(int(x==iw-2)<<1)|(int(x==iw-2 and y==ih-2)<<2)
                        final+=bytes((value,0,0,f,0,flags))
            golden=final
            actual = pixels.read_bytes()
            if actual != golden or len(actual) // 6 != int(match[2]):
                mismatch = next((i for i, pair in enumerate(zip(actual, golden)) if pair[0] != pair[1]), None)
                raise RuntimeError(f'frontend golden mismatch at byte {mismatch}')
            rows=re.findall(r'FRAME_STATS id=(\d+) pixels=(\d+) lines=(\d+) r=(\d+) g=(\d+) b=(\d+)',run.stdout)
            if [tuple(map(int,row)) for row in rows]!=expected_stats:raise RuntimeError('integrated statistics mismatch')
            report['cases'].append({'raw_bits': bits, 'pixels': len(actual)//6,
                'output_sha256': hashlib.sha256(actual).hexdigest(), 'statistics':expected_stats,'status': 'PASS'})
            print(match[0])
        report['status'] = 'PASS'
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
