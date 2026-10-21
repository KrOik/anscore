"""Canonical watchdog -> first fault supervisor -> actual protected carrier."""
from datetime import datetime,timezone
import hashlib,json,subprocess
from pathlib import Path
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/control/motor_foc'
def main():
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('safety_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl'/n for n in ['motor_safety.v','pwm3_atomic.v','pwm3_protection.v']]+[P/'tb/tb_motor_safety.v',ROOT/'cores/system/extended_library/src/wdt_win.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_motor_safety','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        faults=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('FAULT ')]
        if [x[0] for x in faults]!=[3,2,1,4,5,3] or [x[2] for x in faults]!=[1,2,3,4,5,6] or any(x[1]<=0 for x in faults):raise AssertionError('first-fault cause/time/count mismatch')
        if faults[0][3]<4 or faults[0][-1]!=1 or faults[3][4]!=1:raise AssertionError('watchdog event coverage')
        if 'PASS motor safety applied watchdog/firstcause/encoder/gates/recovery' not in r.stdout:raise AssertionError('missing completion')
        if 'PASS single-clock disabled clear retained across monitor beat' not in r.stdout:raise AssertionError('missing pulse clear coverage')
        report.update(status='PASS',fault_cases=6,scope='actual watchdog/firstfault/protected carrier;not physical gate qualification')
        print('PASS safety:6exact firstfaults,applied heartbeat aggregation,timeout/early,encoder/external/control gates,pulse clear/recovery')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
