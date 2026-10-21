"""Execute signed dot RTL checks and bind evidence to exact source hashes."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P=ROOT/'cores/acceleration/cnn_infer_25k'


def main():
    sources=[P/'rtl/int8_dot_stream.v',P/'tb/tb_int8_dot_stream.v']
    out=ROOT/'artifacts/cnn_infer_25k'/datetime.now(timezone.utc).strftime('dot_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]})
    try:
        exe=out/'test.vvp'
        for name,cmd in [('compile',['iverilog','-g2012','-s','tb_int8_dot_stream','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            result=subprocess.run(cmd,capture_output=True,text=True,timeout=60)
            (out/(name+'.log')).write_text(result.stdout+result.stderr)
            if result.returncode:raise RuntimeError(name+' failed: '+result.stdout+result.stderr)
        if 'PASS INT8 dot' not in result.stdout:raise RuntimeError('missing terminal PASS')
        report.update(status='PASS',scope='isolated dot simulation; not full CNN inference or physical performance')
        print(result.stdout.splitlines()[-2])
    except Exception as exc:
        report['reason']=str(exc);raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
