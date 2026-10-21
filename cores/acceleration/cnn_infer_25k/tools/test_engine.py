"""Complete RTL inference, comparing every emitted layer element to Python."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from model import infer

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P=ROOT/'cores/acceleration/cnn_infer_25k'


def main():
    out=ROOT/'artifacts/cnn_infer_25k'/datetime.now(timezone.utc).strftime('engine_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    sources=[P/'rtl/int8_dot_stream.v',P/'rtl/cnn_serial_engine.v',P/'tb/tb_cnn_serial_engine.v']
    tools=[Path(__file__).resolve(),P/'tools/model.py',P/'tools/export_model.py']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+tools})
    try:
        subprocess.run([sys.executable,str(P/'tools/export_model.py'),'--output',str(out/'fixture')],check=True)
        exe=out/'test.vvp'
        build=subprocess.run(['iverilog','-g2012','-s','tb_cnn_serial_engine','-o',str(exe)]+list(map(str,sources)),capture_output=True,text=True)
        (out/'compile.log').write_text(build.stdout+build.stderr)
        if build.returncode:raise RuntimeError(build.stderr)
        run=subprocess.run(['vvp',str(exe),'+memdir='+str(out/'fixture'),'+output='+str(out/'taps.txt')],capture_output=True,text=True,timeout=180)
        (out/'run.log').write_text(run.stdout+run.stderr)
        if run.returncode or 'PASS complete CNN3inputs' not in run.stdout:raise RuntimeError(run.stdout+run.stderr)
        actual=[tuple(map(int,line.split())) for line in (out/'taps.txt').read_text().splitlines()]
        model=json.loads((out/'fixture/model.json').read_text());expected=[]
        names=('conv1_acc','conv1_quant','pool1','conv2_acc','conv2_quant','pool2','scores','top3')
        for case,name in enumerate(('ramp','checker','impulse')):
            saved=json.loads((out/'fixture'/f'{name}.json').read_text());gold=infer(model,saved['input'])
            if saved!=gold:raise RuntimeError('fixture changed')
            # Engine emits acc and quant interleaved; compare stage/address maps,
            # preserving unique accounting and all integer values.
            for stage,tap in enumerate(names):
                expected.extend((case,stage,i,v) for i,v in enumerate(gold[tap]))
        if len(actual)!=len(set((r,s,i) for r,s,i,v in actual)) or sorted(actual)!=sorted(expected):
            mismatch=next((pair for pair in zip(sorted(actual),sorted(expected)) if pair[0]!=pair[1]),None)
            raise RuntimeError('layer mismatch '+str(mismatch))
        cases=re.findall(r'CNN_DONE run=(\d+) cycles=(\d+) error=0 taps=(\d+)',run.stdout)
        report.update(status='PASS',network_inputs=3,layer_values=len(actual),cases=cases,
                      tap_sha256=hashlib.sha256((out/'taps.txt').read_bytes()).hexdigest(),
                      scope='complete RTL simulation,random tap stalls,CE1; physical/PPA pending')
        print('PASS complete CNN RTL: '+str(len(actual))+' exact layer values')
    except Exception as exc:
        report['reason']=str(exc);raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
