"""Three complete CNN runs and synchronous layer readback through actual CSR RTL."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from model import infer

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/acceleration/cnn_infer_25k'


def main():
    out=ROOT/'artifacts/cnn_infer_25k'/datetime.now(timezone.utc).strftime('control_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl'/n for n in ('int8_dot_stream.v','cnn_serial_engine.v','cnn_control.v')]+[P/'tb/tb_cnn_control.v']
    all_sources=sources+[Path(__file__).resolve(),P/'tools/model.py',P/'tools/export_model.py']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in all_sources})
    try:
        subprocess.run([sys.executable,str(P/'tools/export_model.py'),'--output',str(out/'fixture')],check=True)
        exe=out/'test.vvp'
        r=subprocess.run(['iverilog','-g2012','-s','tb_cnn_control','-o',str(exe)]+list(map(str,sources)),capture_output=True,text=True)
        (out/'compile.log').write_text(r.stdout+r.stderr)
        if r.returncode:raise RuntimeError(r.stderr)
        r=subprocess.run(['vvp',str(exe),'+memdir='+str(out/'fixture'),'+output='+str(out/'readback.txt')],capture_output=True,text=True,timeout=180)
        (out/'run.log').write_text(r.stdout+r.stderr)
        if r.returncode or 'PASS CNN CSR3inputs' not in r.stdout:raise RuntimeError(r.stdout+r.stderr)
        model=json.loads((out/'fixture/model.json').read_text());expected=[]
        for run,name in enumerate(('ramp','checker','impulse')):
            image=json.loads((out/'fixture'/f'{name}.json').read_text())['input'];taps=infer(model,image)
            flat=sum((taps[n] for n in ('conv1_acc','conv1_quant','pool1','conv2_acc','conv2_quant','pool2','scores','top3')),[])
            expected.extend((run,i,v) for i,v in enumerate(flat))
        actual=[tuple(map(int,line.split())) for line in (out/'readback.txt').read_text().splitlines()]
        if actual!=expected:
            pair=next((p for p in zip(actual,expected) if p[0]!=p[1]),None)
            raise RuntimeError('CSR readback mismatch '+str(pair))
        report.update(status='PASS',network_inputs=3,readback_words=len(actual),readback_sha256=hashlib.sha256((out/'readback.txt').read_bytes()).hexdigest(),scope='actual CSR simulation; hard JTAG/UART physical binding pending')
        print('PASS CNN CSR:31791 complete layer readback words')
    except Exception as exc:
        report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
