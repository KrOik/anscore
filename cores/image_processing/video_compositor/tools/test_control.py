"""Real CSR -> three finite raster/OSD runs -> held results -> repeat run."""
from datetime import datetime,timezone
import hashlib,json,subprocess,zlib
from pathlib import Path
from test_dual_osd import blend
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/image_processing/video_compositor'
def main():
    out=ROOT/'artifacts/video_compositor_25k'/datetime.now(timezone.utc).strftime('control_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl'/f for f in ['video_control.v','video_results_csr.v','raster_osd_output.v','dual_osd_stream.v','video_frame_crc.v']]+[P/'tb/tb_video_control.v',ROOT/'cores/system/common_scaffold/image/multiframe/img_mf_rgb_blend_pipe.v',ROOT/'cores/system/common_scaffold/image/video_scanout/video_timing_generator.sv',ROOT/'cores/system/stream_bus_library/rtl/sys_atomic_config.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve(),P/'tools/test_dual_osd.py']})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_video_control','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=90);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        observed=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('SNAP ')]
        expected=[]
        for epoch in range(2):
            for g in range(3):
                raw=bytearray();base=0xf0a050 if epoch==1 and g==0 else 0x123456+g*0x10101
                for y in range(4):
                    for x in range(8+g):raw.extend(blend(blend(base^((x<<16)|(y<<8)),0x654321,128),0xabcdef,64).to_bytes(3,'little'))
                expected.append((epoch,g,0,zlib.crc32(raw),(8+g)*4,0,2 if epoch==1 and g==0 else 1,2,3 if epoch==0 else 1))
        if observed!=expected:raise AssertionError(f'snapshots {observed} != {expected}')
        if 'PASS video control integration' not in r.stdout:raise AssertionError('missing completion')
        if 'PASS control invalid geometry/abort/recovery' not in r.stdout:raise AssertionError('missing recovery coverage')
        report.update(status='PASS',snapshots=6,normal_frames=12,error_recovery_frames=2,scope='runtime CSR finite runs/result ownership and invalid geometry/abort/recovery; physical transport/build pending')
        print('PASS real video CSR:6golden snapshots,12normal+2recovery frames,held responses,overrun,ACK/re-run,invalid geometry/abort/recovery')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
