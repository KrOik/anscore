"""Frozen isolated25K mapping of the complete lock-in datapath."""
from collections import Counter
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())


def main():
    names=['cores/signal_processing/lockin/rtl/lockin4.v','cores/signal_processing/dsp/src/dds_nco.v','cores/signal_processing/dsp/src/cordic.v',
           'cores/signal_processing/lockin/vectors/sine.mem','cores/signal_processing/lockin/vectors/cosine.mem']
    out=ROOT/'artifacts/lockin_dsp_25k'/datetime.now(timezone.utc).strftime('synth_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    hashes={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in names}
    hashes[str(Path(__file__).resolve().relative_to(ROOT))]=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    snap=out/'source_snapshot'
    for n,digest in hashes.items():
        dest=snap/n;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/n,dest)
        if hashlib.sha256(dest.read_bytes()).hexdigest()!=digest:raise RuntimeError('input changed')
    # Defer elaboration so DDS's unused default LUT filename is not opened;
    # the actual two instances use the frozen explicit sine/cosine parameters.
    script='read_verilog -defer '+' '.join(n for n in names if n.endswith('.v'))+'; synth_gowin -family gw5a -nolutram -noiopads -top lockin4 -json '+(out/'design.json').as_posix()+'; stat'
    (out/'synth.ys').write_text(script+'\n');print('Evidence='+str(out),flush=True)
    report=dict(status='FAIL',sources=hashes,scope='isolated synthesis; no routed Fmax/physical measurement')
    try:
        with (out/'synthesis.log').open('w') as log:r=subprocess.run(['yosys','-Q','-p',script],cwd=snap,stdout=log,stderr=subprocess.STDOUT)
        if r.returncode:raise RuntimeError('synthesis failed,exit='+str(r.returncode))
        report.update(status='PASS',cells=dict(Counter(c['type'] for c in json.loads((out/'design.json').read_text())['modules']['lockin4']['cells'].values())))
        print(report['cells'],flush=True)
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out),flush=True)


if __name__=='__main__':main()
