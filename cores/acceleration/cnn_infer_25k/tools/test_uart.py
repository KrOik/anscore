"""Bit-serial board-top simulation,loading the complete model through UART."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from model import infer

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/acceleration/cnn_infer_25k'


def main():
    out=ROOT/'artifacts/cnn_infer_25k'/datetime.now(timezone.utc).strftime('uart_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=sorted((P/'rtl').glob('*.v'))+[P/'examples/25k/cnn_top.v',P/'tb/tb_cnn_uart.v',ROOT/'cores/system/stream_bus_library/board/sys_uart.v',ROOT/'cores/system/ip_test_shell/rtl/uart_csr_transport.v']
    report=dict(status='IN_PROGRESS',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve(),P/'tools/model.py',P/'tools/export_model.py']})
    try:
        subprocess.run([sys.executable,str(P/'tools/export_model.py'),'--output',str(out/'fixture')],check=True)
        exe=out/'test.vvp'
        r=subprocess.run(['iverilog','-g2012','-D',"CNN_BUILD_ID=64'h2505abcd12345678",'-s','tb_cnn_uart','-o',str(exe)]+list(map(str,sources)),capture_output=True,text=True)
        (out/'compile.log').write_text(r.stdout+r.stderr)
        if r.returncode:raise RuntimeError(r.stderr)
        print('UART full model simulation started: '+str(out),flush=True)
        r=subprocess.run(['vvp',str(exe),'+memdir='+str(out/'fixture')],capture_output=True,text=True,timeout=600)
        (out/'run.log').write_text(r.stdout+r.stderr)
        if r.returncode or 'PASS complete CNN physical-top' not in r.stdout:raise RuntimeError(r.stdout+r.stderr)
        model=json.loads((out/'fixture/model.json').read_text());image=json.loads((out/'fixture/ramp.json').read_text())['input'];gold=infer(model,image)
        actual=[(int(i),int(v)) for i,v in re.findall(r'UART_CNN_RESULT index=(\d+) value=(-?\d+)',r.stdout)]
        if actual!=list(enumerate(gold['scores']+gold['top3'])):raise RuntimeError('UART numerical result mismatch')
        report.update(status='PASS',scores=gold['scores'],top3=gold['top3'],scope='bit-serial simulation with accelerated UART8clock bits; not physical UART')
        print('PASS complete CNN bit-serial loading/inference/result readback')
    except Exception as exc:report.update(status='FAIL',reason=str(exc));raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out),flush=True)


if __name__=='__main__':main()
