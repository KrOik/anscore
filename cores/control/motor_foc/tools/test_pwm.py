"""Exercise actual canonical PWM plus three complementary protection lanes."""
from datetime import datetime,timezone
import hashlib,json,subprocess
from pathlib import Path
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/control/motor_foc'
def main():
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('pwm_protection_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/pwm3_protection.v',P/'tb/tb_pwm3_protection.v',ROOT/'cores/system/extended_library/src/pwm_gen.v']
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_pwm3_protection','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        samples=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('GATES ')]
        if len(samples)<300 or any(h&l or (f and(h or l)) for raw,h,l,f in samples):raise AssertionError('overlap/fault gate violation')
        if 'PASS PWM3 protection deadtime/fault/clear/config/recovery' not in r.stdout:raise AssertionError('missing completion')
        report.update(status='PASS',sampled_cycles=len(samples),scope='digital deadtime/fault reference only;not motor closed-loop or power-stage certification')
        print(f'PASS PWM protection:{len(samples)}cycles,deadtime2/3,subclockfault,latchedclear/config/recovery')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
