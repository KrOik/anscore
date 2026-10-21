"""Independent four-product Park and integer Clarke oracle for elastic chain."""
from datetime import datetime,timezone
import hashlib,json,math,random,shutil,subprocess
from pathlib import Path
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/control/motor_foc';C=ROOT/'cores/acceleration/operator_library'
def main():
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('transform_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=[P/'rtl/current_transform.v',P/'tb/tb_current_transform.v',C/'rtl/acc_clarke_s12.v',C/'rtl/acc_park_s12.v',C/'sim/mult12x12_model.v']
    table=C/'tables/park_s12_sincos.mem'
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[table,Path(__file__).resolve()]})
    print('Evidence='+str(out),flush=True)
    try:
        # Independently regenerate mathematical table and check source image.
        cos=[round(1024*math.cos(2*math.pi*k/256)) for k in range(256)]
        sin=[round(1024*math.sin(2*math.pi*k/256)) for k in range(256)]
        if [int(x,16) for x in table.read_text().split()]!=[((c&4095)<<12)|(s&4095) for c,s in zip(cos,sin)]:raise AssertionError('trig image differs from mathematical Q10 table')
        (out/'tables').mkdir();shutil.copyfile(table,out/'tables/park_s12_sincos.mem')
        rng=random.Random(0x2509);vectors=[];expected=[];faults=0
        for n in range(1024):
            if n<512:
                t=2*math.pi*(n%256)/256;amp=384 if n<256 else 511
                ia,ib,ic=[round(amp*math.cos(t+delta)) for delta in (0,-2*math.pi/3,2*math.pi/3)]
                theta=n%256;tol=2;enable=1
            else:
                ia,ib,ic=[rng.randrange(-512,512) for _ in range(3)];theta=rng.randrange(256);tol=rng.randrange(256);enable=n%2
            alpha=ia;beta=((ia+2*ib)*1182+1024)>>11;beta2=((ib-ic)*1182+1024)>>11
            residual=abs(beta-beta2);sensor=int(enable and residual>tol);faults+=sensor
            a=max(-1024,min(1023,alpha));b=max(-1024,min(1023,beta))
            d=(a*cos[theta]+b*sin[theta]+512)>>10;q=(-a*sin[theta]+b*cos[theta]+512)>>10
            flags=int(alpha!=a)|(int(beta!=b)<<1)|(int(abs(d)>1023)<<2)|(int(abs(q)>1023)<<3)
            expected.append((n,d,q,alpha,beta,residual,flags,sensor,0))
            vectors.append((ia&1023)|((ib&1023)<<10)|((ic&1023)<<20)|(theta<<30)|(tol<<38)|(enable<<46)|(n<<47))
        fixture=out/'vectors.mem';fixture.write_text(''.join(f'{v:018x}\n' for v in vectors))
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb_current_transform','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe),'+fixture='+str(fixture)])]:
            r=subprocess.run(cmd,cwd=out,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        actual=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('TRANSFORM ')]
        if actual!=expected:raise AssertionError('Clarke/Park/metadata/fault numerical mismatch')
        if 'PASS current transform' not in r.stdout:raise AssertionError('missing completion')
        report.update(status='PASS',samples=1024,sensor_fault_samples=faults,continuous_samples=128,scope='canonical current-transform chain only;no closed-loop motor/25K build')
        print(f'PASS transform:1024exact signed samples,all256angles,128continuousII1,{faults}sensorfaults,randomgaps/stalls')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
