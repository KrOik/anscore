"""CSR adapter regression with real canonical atomic-config dependency."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT/'cores/image_processing/isp_stream'


def main():
    sources=[P/'rtl/isp_config_registers.v',ROOT/'cores/system/stream_bus_library/rtl/sys_atomic_config.v',P/'tb/tb_isp_config_registers.v']
    out=ROOT/'artifacts/isp_stream_25k'/datetime.now(timezone.utc).strftime('config_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    report={'status':'IN_PROGRESS','sources':{str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources+[Path(__file__).resolve()]}}
    try:
        exe=out/'test.vvp'
        run=subprocess.run(['iverilog','-g2012','-s','tb_isp_config_registers','-o',str(exe)]+list(map(str,sources)),capture_output=True,text=True)
        (out/'compile.log').write_text(run.stdout+run.stderr)
        if run.returncode:raise RuntimeError(run.stderr)
        run=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=30)
        (out/'run.log').write_text(run.stdout+run.stderr)
        if run.returncode or 'PASS ISP CSR atomic configuration' not in run.stdout:raise RuntimeError(run.stdout+run.stderr)
        report['status']='PASS';print(run.stdout.splitlines()[0])
    except Exception as exc:
        report.update(status='FAIL',reason=str(exc));raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
