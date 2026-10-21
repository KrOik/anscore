"""Actual bitserial UART -> bank window -> three scanouts -> golden CRC reads."""
from datetime import datetime,timezone
import hashlib,json,subprocess,zlib
from pathlib import Path
from test_dual_osd import blend
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/image_processing/video_compositor'
def sources():
    return [P/'rtl'/f for f in ['video_uart_control.v','video_control.v','video_results_csr.v','raster_osd_output.v','dual_osd_stream.v','video_frame_crc.v']]+[P/'examples/25k/video_top.v',ROOT/'cores/system/common_scaffold/image/multiframe/img_mf_rgb_blend_pipe.v',ROOT/'cores/system/common_scaffold/image/video_scanout/video_timing_generator.sv',ROOT/'cores/system/stream_bus_library/rtl/sys_atomic_config.v',ROOT/'cores/system/stream_bus_library/board/sys_uart.v',ROOT/'cores/system/ip_test_shell/rtl/uart_csr_transport.v']
def main():
    out=ROOT/'artifacts/video_compositor_25k'/datetime.now(timezone.utc).strftime('uart_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    files=sources()+[P/'tb/tb_video_uart.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files+[Path(__file__).resolve(),P/'tools/test_dual_osd.py']})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-D',"VIDEO_BUILD_ID=64'h123456789abcdef0",'-s','tb_video_uart','-o',str(exe)]+list(map(str,files))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=90);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        observed=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('SNAP ')]
        expected=[]
        for epoch,g in [(0,0),(0,1),(0,2),(1,0)]:
            raw=bytearray();base=0xf0a050 if epoch else 0x123456+g*0x10101
            for y in range(3):
                for x in range(4+g):raw.extend(blend(blend(base^((x<<16)|(y<<8)),0x654321,128),0xabcdef,64).to_bytes(3,'little'))
            expected.append((epoch,g,0,zlib.crc32(raw),(4+g)*3,0,epoch+1))
        if observed!=expected:raise AssertionError(f'UART snapshots {observed} != {expected}')
        if 'PASS video UART banked control' not in r.stdout:raise AssertionError('missing completion')
        report.update(status='PASS',snapshots=4,uart_bit_clocks=8,scope='simulated serial physical top; no board measurement')
        print('PASS video bitserial UART:4exact CRC/version snapshots,bankselection/errors,ACK/re-run')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
