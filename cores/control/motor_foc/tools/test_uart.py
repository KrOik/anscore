"""Bit-serial UART through actual25K digital board binding."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,shutil,subprocess
from test_current_pi import step
from test_modulator import golden
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/control/motor_foc';C=ROOT/'cores/acceleration/operator_library'
def main():
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('uart_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    sources=list((P/'rtl').glob('*.v'))+[P/'tb/tb_motor_uart.v']+[C/'rtl'/n for n in ['acc_clarke_s12.v','acc_park_s12.v','acc_inv_park_s12.v','acc_ipi_pid_s12.v']]+[C/'sim/mult12x12_model.v',ROOT/'cores/signal_processing/dsp/src/pid_core.v']+[ROOT/'cores/system/extended_library/src'/n for n in ['qei_dec.v','wdt_win.v']]
    sources += [P/'examples/25k/motor_top.v',ROOT/'cores/system/stream_bus_library/board/sys_uart.v',ROOT/'cores/system/ip_test_shell/rtl/uart_csr_transport.v']
    tables=[C/'tables'/n for n in ['park_s12_sincos.mem','inv_park_s12_sincos.mem']]
    report=dict(status='FAIL',physical_measurement=False,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+tables+[Path(__file__).resolve(),P/'tools/test_current_pi.py',P/'tools/test_modulator.py']})
    print('Evidence='+str(out),flush=True)
    try:
        (out/'tables').mkdir()
        for table in tables:shutil.copyfile(table,out/'tables'/table.name)
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012',"-DMOTOR_BUILD_ID=64'h123456789abcdef0",'-s','tb_motor_uart','-o',str(exe)]+list(map(str,sources))),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=out,capture_output=True,text=True,timeout=60);(out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        rows=[tuple(map(int,line.split()[1:])) for line in r.stdout.splitlines() if line.startswith('UART_MOTOR ')]
        expected=[]
        for n,(rd,rq) in enumerate([(0,0),(80,-60),(-40,60)]):
            vd,*_=step(rd,0,0,0,True,False);vq,*_=step(rq,0,0,0,True,False)
            du,dv,dw,*_=golden(vd,vq,0,256)
            values=[n,0,0,0,0,0,vd,vq,du,dv,dw,0]
            expected.extend((n,k,v) for k,v in enumerate(values))
        if rows!=expected:raise AssertionError(f'CSR numerical snapshot mismatch {rows} expected {expected}')
        if 'PASS motor physical-top UART framing/three numerical commands/ACK/errors' not in r.stdout:raise AssertionError('missing completion')
        report.update(status='PASS',commands=3,snapshot_words=36,scope='actual bit-serial UART/top/CSR numerical results in simulation; no physical transport measurement')
        print('PASS motor UART:3 exact numerical snapshots,bit-serial framing,loaded identity,owned-command rejection and ACK')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
