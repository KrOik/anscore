"""Compile and retain frame-boundary handshake/configuration evidence."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P=ROOT/'cores/image_processing/video_compositor'
def main():
    out=ROOT/'artifacts/video_compositor_25k'/datetime.now(timezone.utc).strftime('frame_config_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    sources=[P/'rtl/frame_atomic_config.v',P/'tb/tb_frame_atomic_config.v',ROOT/'cores/system/stream_bus_library/rtl/sys_atomic_config.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_frame_atomic_config','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60)
            (out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        if 'PASS frame atomic config:' not in r.stdout:raise RuntimeError('missing completion')
        report['status']='PASS'
        print(r.stdout.strip())
    except Exception as exc:
        report['reason']=str(exc)
        raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
