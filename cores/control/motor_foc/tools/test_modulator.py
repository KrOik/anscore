"""Independent four-product inverse rotation/common-mode duty oracle."""
from datetime import datetime,timezone
import hashlib,json,math,random,shutil,subprocess
from pathlib import Path
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/control/motor_foc';C=ROOT/'cores/acceleration/operator_library'
def golden(d,q,theta,period):
    dv=max(-1024,min(1023,d));qv=max(-1024,min(1023,q))
    c=round(1024*math.cos(2*math.pi*theta/256));s=round(1024*math.sin(2*math.pi*theta/256))
    alpha=(dv*c-qv*s+512)>>10;beta=(dv*s+qv*c+512)>>10
    flags=int(dv!=d)|(int(qv!=q)<<1)|(int(abs(alpha)>1023)<<2)|(int(abs(beta)>1023)<<3)
    phases=[alpha,(-alpha*1024+beta*1774+1024)>>11,(-alpha*1024-beta*1774+1024)>>11]
    common=(max(phases)+min(phases))//2;centered=[x-common for x in phases]
    over=any(abs(x)>1024 for x in centered)
    duties=[0 if period<4 else ((max(-1024,min(1024,x))+1024)*period+1024)>>11 for x in centered]
    return (*duties,period,int(period<4)|(int(over)<<1),flags)
def main():
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('modulator_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/svpwm_duty.v',P/'rtl/voltage_modulator.v',P/'tb/tb_voltage_modulator.v',C/'rtl/acc_inv_park_s12.v',C/'sim/mult12x12_model.v']
    table=C/'tables/inv_park_s12_sincos.mem'
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[table,Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        image=[((round(1024*math.cos(2*math.pi*k/256))&4095)<<12)|(round(1024*math.sin(2*math.pi*k/256))&4095) for k in range(256)]
        if image!=[int(x,16) for x in table.read_text().split()]:raise AssertionError('trig table')
        (out/'tables').mkdir();shutil.copyfile(table,out/'tables/inv_park_s12_sincos.mem')
        vectors=[];expected=[];inputs=[];rng=random.Random(2509007)
        for n in range(1024):
            if n<256:d,q,t,period=384,-256,n,1024
            elif n<512:d,q,t,period=[-2048,-1024,0,1023,2047][n%5],[-2048,0,2047][n%3],n%256,[0,1,3,4,5,100,65535][n%7]
            else:d,q,t,period=rng.randrange(-2048,2048),rng.randrange(-2048,2048),rng.randrange(256),rng.choice([4,5,16,100,1024,65535])
            expected.append((n,*golden(d,q,t,period)))
            inputs.append((d,q,t,period))
            vectors.append((d&4095)|((q&4095)<<12)|(t<<24)|(period<<32)|(n<<48))
        fixture=out/'vectors.mem';fixture.write_text(''.join(f'{x:020x}\n' for x in vectors))
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_voltage_modulator','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe),'+fixture='+str(fixture)])]:
            r=subprocess.run(cmd,cwd=out,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        actual=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('DUTY ')]
        if actual!=expected:
            mismatch=next(((a,b) for a,b in zip(actual,expected) if a!=b),('length',len(actual)))
            raise AssertionError(f'duty mismatch {mismatch}')
        if 'PASS inverse Park SVPWM duties' not in r.stdout:raise AssertionError('missing completion')
        line_cases=0;max_line_error=0.0
        for row,(d,q,t,period) in zip(actual,inputs):
            if row[-2] or period<100:continue
            d=max(-1024,min(1023,d));q=max(-1024,min(1023,q));angle=2*math.pi*t/256
            a=d*math.cos(angle)-q*math.sin(angle);b=d*math.sin(angle)+q*math.cos(angle)
            phase=[a,(-a+math.sqrt(3)*b)/2,(-a-math.sqrt(3)*b)/2]
            reconstructed=[v*2048/period for v in row[1:4]]
            line_error=max(abs((reconstructed[i]-reconstructed[j])-(phase[i]-phase[j])) for i,j in [(0,1),(1,2),(2,0)])
            if line_error>2048/period+4:raise AssertionError('average line-voltage modulation bound')
            max_line_error=max(max_line_error,line_error);line_cases+=1
        if line_cases<200:raise AssertionError('missing physical relation coverage')
        report.update(status='PASS',samples=1024,average_line_voltage_cases=line_cases,max_line_error_counts=max_line_error,invalid_period_samples=sum(bool(x[-2]&1) for x in expected),overmodulation_samples=sum(bool(x[-2]&2) for x in expected),scope='inversePark/common-mode duties and numerical average line voltage;not switching waveform/full FOC')
        print('PASS inversePark/SVPWM:1024exact duty/flags/period/IDs,all256angles,invalidperiods,overmodulation,II1/stalls')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
