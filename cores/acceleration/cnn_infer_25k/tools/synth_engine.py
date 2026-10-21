"""Frozen-input isolated CNN synthesis; no board pads or physical Fmax claim."""
from collections import Counter
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P=ROOT/'cores/acceleration/cnn_infer_25k'


def main():
    out=ROOT/'artifacts/cnn_infer_25k'/datetime.now(timezone.utc).strftime('engine_synth_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    sources=[P/'rtl/int8_dot_stream.v',P/'rtl/cnn_serial_engine.v']
    snapshot=out/'source_snapshot';snapshot.mkdir()
    hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]}
    for p in sources+[Path(__file__).resolve()]:
        shutil.copyfile(p,snapshot/p.name)
        if hashlib.sha256((snapshot/p.name).read_bytes()).hexdigest()!=hashes[str(p.relative_to(ROOT))]:raise RuntimeError('source changed during copy')
    script='read_verilog '+ ' '.join((snapshot/p.name).as_posix() for p in sources)+'; synth_gowin -family gw5a -noiopads -top cnn_serial_engine -json '+(out/'design.json').as_posix()+'; stat'
    (out/'synth.ys').write_text(script+'\n')
    report=dict(status='IN_PROGRESS',sources=hashes,scope='isolated GW5A synthesis without pads; no P&R,physical Fmax or board inference')
    (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Evidence='+str(out),flush=True)
    try:
        with (out/'synthesis.log').open('w') as log:
            run=subprocess.run(['yosys','-Q','-p',script],stdout=log,stderr=subprocess.STDOUT)
        if run.returncode:raise RuntimeError('synthesis failed,exit='+str(run.returncode))
        cells=Counter(c['type'] for c in json.loads((out/'design.json').read_text())['modules']['cnn_serial_engine']['cells'].values())
        report.update(status='PASS',cells=dict(cells));print(dict(cells),flush=True)
    except Exception as exc:
        report.update(status='FAIL',reason=str(exc));raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out),flush=True)


if __name__=='__main__':main()
