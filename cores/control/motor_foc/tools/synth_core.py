"""Frozen GW5A core synthesis, no board pins/route/image/download claims."""
from collections import Counter
from datetime import datetime,timezone
from pathlib import Path
import hashlib,json,shutil,subprocess
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/control/motor_foc';C=ROOT/'cores/acceleration/operator_library'
def main():
    sources=sorted((P/'rtl').glob('*.v'))+[C/'rtl'/n for n in ['acc_clarke_s12.v','acc_park_s12.v','acc_inv_park_s12.v','acc_ipi_pid_s12.v']]+[ROOT/'cores/signal_processing/dsp/src/pid_core.v']+[ROOT/'cores/system/extended_library/src'/n for n in ['qei_dec.v','wdt_win.v']]
    # Explicit MULT12X12 primitives must remain actual device primitives.
    # Never include the behavioral model used by simulation.
    tables=[C/'tables'/n for n in ['park_s12_sincos.mem','inv_park_s12_sincos.mem']]
    inputs=sources+tables+[Path(__file__).resolve()]
    hashes={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    fingerprint=hashlib.sha256(json.dumps(hashes,sort_keys=True,separators=(',',':')).encode()).hexdigest()[:16]
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('synth_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    snap=out/'source_snapshot'
    for p in inputs:
        dest=snap/p.relative_to(ROOT);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest)
        if hashlib.sha256(dest.read_bytes()).hexdigest()!=hashes[p.relative_to(ROOT).as_posix()]:raise RuntimeError('source changed')
    (out/'tables').mkdir()
    for p in tables:shutil.copyfile(snap/p.relative_to(ROOT),out/'tables'/p.name)
    report=dict(status='IN_PROGRESS',target='GW5A-25A',top='motor_control_csr',sources=hashes,
                fingerprint=fingerprint,scope='core synthesis only,no IOBs/placement/timing/bitstream',board_downloaded=False)
    print('Evidence='+str(out),flush=True)
    try:
        script='read_verilog '+' '.join('"'+(snap/p.relative_to(ROOT)).as_posix()+'"' for p in sources)
        script+='; synth_gowin -family gw5a -nolutram -nowidelut -noiopads -top motor_control_csr -json "'+(out/'design.json').as_posix()+'"; check -assert; stat'
        (out/'synth.ys').write_text(script+'\n')
        cmd=['yosys','-Q','-T','-s',str(out/'synth.ys')];report['command']=cmd
        with (out/'synth.log').open('w') as log:r=subprocess.run(cmd,cwd=out,stdout=log,stderr=subprocess.STDOUT,timeout=600)
        if r.returncode:raise RuntimeError('synthesis exit '+str(r.returncode))
        design=json.loads((out/'design.json').read_text());cells=Counter(c['type'] for c in design['modules']['motor_control_csr']['cells'].values())
        if cells['MULT12X12']<1:raise AssertionError('explicit DSP primitives missing')
        # Yosys $scopeinfo holds hierarchy provenance, not executable logic.
        if any(t.startswith('$') and t!='$scopeinfo' for t in cells):raise AssertionError('unmapped internal cells')
        report.update(status='PASS',cells=dict(cells),netlist_sha256=hashlib.sha256((out/'design.json').read_bytes()).hexdigest())
        print('PASS core synthesis '+json.dumps(dict(cells),sort_keys=True),flush=True)
    except Exception as exc:report.update(status='FAIL',reason=str(exc));raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
