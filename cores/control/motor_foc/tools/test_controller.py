"""Integrated controller protocol/fault regression; no mechanical-plant claim."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,shutil,subprocess
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/control/motor_foc';C=ROOT/'cores/acceleration/operator_library'
def main():
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('controller_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=list((P/'rtl').glob('*.v'))+[P/'tb/tb_motor_controller.v']+[C/'rtl'/n for n in ['acc_clarke_s12.v','acc_park_s12.v','acc_inv_park_s12.v','acc_ipi_pid_s12.v']]+[C/'sim/mult12x12_model.v',ROOT/'cores/signal_processing/dsp/src/pid_core.v']+[ROOT/'cores/system/extended_library/src'/n for n in ['qei_dec.v','wdt_win.v']]
    tables=[C/'tables'/n for n in ['park_s12_sincos.mem','inv_park_s12_sincos.mem']]
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+tables+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        (out/'tables').mkdir()
        for table in tables:shutil.copyfile(table,out/'tables'/table.name)
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_motor_controller','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=out,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        if 'PASS controller QEI/three modes/applied ownership' not in r.stdout:raise AssertionError('missing completion')
        report.update(status='PASS',scope='QEI/outer/FOC/safety connected; protocol/fault ownership only,not joint mechanical numerical acceptance')
        print(r.stdout.strip())
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
