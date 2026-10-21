"""Check Yosys Booth-lowered signed multiplication against Python integers."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import random
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())


def main():
    out=ROOT/'artifacts/lockin_dsp_25k'/datetime.now(timezone.utc).strftime('booth_test_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    report=dict(status='FAIL',physical_measurement=False,tool_source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    print('Evidence='+str(out),flush=True)
    try:
        original=out/'multiply.v';lowered=out/'lowered.v'
        original.write_text('module multiply(input signed[16:0] a,b,output signed[33:0] p);assign p=a*b;endmodule\n')
        script=f'read_verilog {original.as_posix()}; hierarchy -top multiply; proc; opt; wreduce; booth; techmap; opt; write_verilog -noattr {lowered.as_posix()}'
        with (out/'lower.log').open('w') as log:
            subprocess.run(['yosys','-Q','-T','-p',script],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
        edges=[-65536,-65535,-32768,-1,0,1,32767,32768,65535]
        pairs=[(a,b) for a in edges for b in edges]
        rng=random.Random(0x25b007)
        pairs += [(rng.randrange(-65536,65536),rng.randrange(-65536,65536)) for _ in range(5000)]
        mem=out/'vectors.mem'
        mem.write_text(''.join(f'{((a&131071)<<51)|((b&131071)<<34)|((a*b)&((1<<34)-1)):017x}\n' for a,b in pairs))
        tb=out/'tb.v'
        tb.write_text('''module tb;
reg signed[16:0] a,b;wire signed[33:0] p;
reg[67:0] vectors[0:'''+str(len(pairs)-1)+'''];integer i;
multiply dut(a,b,p);
initial begin $readmemh("'''+mem.as_posix()+'''",vectors);
for(i=0;i<'''+str(len(pairs))+''';i=i+1)begin
{a,b}=vectors[i][67:34];#1;
if(p!==vectors[i][33:0])$fatal(1,"Booth mismatch vector%0d",i);
end
$display("PASS Booth signed multiplier");$finish;end
endmodule
''')
        exe=out/'test.vvp'
        for label,cmd in [('compile',['iverilog','-g2012','-s','tb','-o',str(exe),str(lowered),str(tb)]),('run',['vvp',str(exe)])]:
            r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=60)
            (out/(label+'.log')).write_text(r.stdout+r.stderr)
            if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        if 'PASS Booth signed multiplier' not in r.stdout:raise RuntimeError('missing completion')
        report.update(status='PASS',vectors=len(pairs),scope='exact17x17signed multiplication afteractualBooth lowering; notfulltop equivalence')
        print('PASS Booth lowering:'+str(len(pairs))+' independent Python products')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
