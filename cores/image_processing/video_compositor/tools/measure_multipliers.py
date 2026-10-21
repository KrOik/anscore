"""Measure and numerically verify exact GW5A unsigned multiplier lowering."""
from collections import Counter
from datetime import datetime,timezone
import json,random,subprocess
from pathlib import Path
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
def main():
    out=ROOT/'artifacts/video_compositor_25k'/datetime.now(timezone.utc).strftime('multipliers_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    report=dict(status='FAIL',physical_measurement=False)
    print('Evidence='+str(out),flush=True)
    def run(label,cmd):
        if cmd[0]=='yosys':cmd[-1]=cmd[-1].replace(';','; ')
        r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,timeout=120);(out/(label+'.log')).write_text(r.stdout+r.stderr)
        if r.returncode:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout
    try:
        src=out/'multiply.v';src.write_text('module multiply(input [15:0] a,b,input [7:0] x,input [8:0] w,output [31:0] p,output [16:0] q);assign p=a*b;assign q=x*w;endmodule\n')
        for mode in ('original','booth'):
            net=out/(mode+'.json');extra='hierarchy -top multiply;proc;opt;wreduce;booth;' if mode=='booth' else ''
            run(mode,['yosys','-Q','-T','-p',f'read_verilog {src.as_posix()};{extra}synth_gowin -family gw5a -nolutram -nowidelut -noiopads -top multiply -json {net.as_posix()};stat'])
            report[mode]=dict(Counter(c['type'] for c in json.loads(net.read_text())['modules']['multiply']['cells'].values()))
        lowered=out/'lowered.v'
        run('lower',['yosys','-Q','-T','-p',f'read_verilog {src.as_posix()};hierarchy -top multiply;proc;opt;wreduce;booth;techmap;opt;write_verilog -noattr {lowered.as_posix()}'])
        rng=random.Random(0x2508b007)
        vectors=[(a,b,x,w) for a in (0,1,32767,32768,65535) for b in (0,1,32767,32768,65535) for x,w in ((0,0),(255,256),(255,511),(1,1))]
        vectors += [(rng.randrange(65536),rng.randrange(65536),rng.randrange(256),rng.randrange(512)) for _ in range(5000)]
        mem=out/'vectors.mem';mem.write_text(''.join(f'{(a<<82)|(b<<66)|(x<<58)|(w<<49)|((a*b)<<17)|(x*w):025x}\n' for a,b,x,w in vectors))
        tb=out/'tb.v';tb.write_text('module tb;reg[15:0]a,b;reg[7:0]x;reg[8:0]w;wire[31:0]p;wire[16:0]q;reg[97:0]v[0:'+str(len(vectors)-1)+'];integer i;multiply dut(a,b,x,w,p,q);initial begin $readmemh("'+mem.as_posix()+'",v);for(i=0;i<'+str(len(vectors))+';i=i+1)begin {a,b,x,w}=v[i][97:49];#1;if({p,q}!==v[i][48:0])$fatal(1,"unsigned Booth mismatch");end $display("PASS unsigned Booth products");$finish;end endmodule\n')
        exe=out/'test.vvp';run('compile',['iverilog','-g2012','-s','tb','-o',str(exe),str(lowered),str(tb)])
        if 'PASS unsigned Booth products' not in run('simulate',['vvp',str(exe)]):raise ValueError('missing completion')
        report.update(status='PASS',vectors=len(vectors),scope='isolated16x16 and8x9unsigned;not full top equivalence/resources')
        print(json.dumps(report))
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
