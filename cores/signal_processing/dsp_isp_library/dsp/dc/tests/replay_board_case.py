"""Reproduce real board stimulus against source RTL, without changing golden."""
import sys,os,json,struct,subprocess,hashlib,argparse
from pathlib import Path
from datetime import datetime
BASE=Path(__file__).resolve().parents[1]; ROOT=BASE.parents[3]
parser=argparse.ArgumentParser()
parser.add_argument('source',nargs='?',default=str(BASE/'rtl/dc_stream.sv'))
parser.add_argument('libraries',nargs='*')
parser.add_argument('--case',type=Path,default=ROOT/'artifacts/dsp_isp_20260925/dc_board_02/case_01')
parser.add_argument('--latency',type=int,choices=[1,2])
args=parser.parse_args();CASE=args.case.resolve();rtl=Path(args.source).resolve()
if args.latency is None:
 args.latency=json.loads((BASE/'ip_manifest.json').read_text())['latency_cycles'] if rtl==(BASE/'rtl/dc_stream.sv').resolve() else 1
OUT=BASE/'evidence'/('board_replay_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));OUT.mkdir()
case=json.loads((CASE/'expected.json').read_text())
words=case['words']; expected=case['outputs'];cfg=case['config']; stall=case['stall']
slots=[False]*args.latency;sent=got=expected_cycles=0;phase=0
while got<len(words):
 ready=phase>=stall;advance=[False]*args.latency
 for k in range(args.latency-1,-1,-1):advance[k]=not slots[k] or (ready if k==args.latency-1 else advance[k+1])
 if slots[-1] and ready:got+=1
 old=slots.copy()
 for k in range(args.latency):
  if advance[k]:slots[k]=(sent<len(words)) if k==0 else old[k-1]
 if advance[0] and sent<len(words):sent+=1
 expected_cycles+=1;phase=(phase+1)%8
for filename,values in [('input.mem',words),('expected.mem',expected)]:
 (OUT/filename).write_text('\n'.join(f'{x:08x}' for x in values)+'\n')
actual=list(struct.unpack('<64I',(CASE/'decoded.bin').read_bytes()[20:]))
mismatches=[{'index':i,'input':words[i],'expected':e,'observed':a} for i,(e,a) in enumerate(zip(expected,actual)) if e!=a]
tb=f'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0; reg[1:0]cm={cfg&3};reg[15:0]cp={(cfg>>2)&65535};reg[3:0]lg={(cfg>>18)&15};
wire cr,cd,ce,sr,mv;wire[31:0]md;
reg[31:0]inputs[0:63],golden[0:63];integer sent=0,got=0,cycle=0;reg run=0;reg[2:0]phase=0;
wire sv=run&&sent<64;wire mr=run&&phase>={stall};
wire signed[15:0]sd=inputs[sent<64?sent:63][15:0];
dc_stream dut(clk,rst_n,sd,sv,sr,md,mv,mr,cv,cr,cm,cp,lg,cd,ce);
initial begin
 $readmemh("input.mem",inputs);$readmemh("expected.mem",golden);
 repeat(3) @(negedge clk);rst_n=1;cv=1;
 @(negedge clk);cv=0;run=1;
end
always @(posedge clk) if(run) begin
 if(sv&&sr)begin $display("INPUT %0d %h",sent,sd);sent=sent+1;end
 if(mv&&mr)begin
  $display("OUTPUT %0d %h expected=%h",got,md,golden[got]);
  if(md!==golden[got])$fatal(1,"first RTL divergence index=%0d",got);
  got=got+1;
 end
 cycle=cycle+1;phase<=phase+1;
 if(got==64)begin if(cycle!={expected_cycles})$fatal(1,"cycle contract got=%0d",cycle);$display("PASS exact board vectors cycles=%0d",cycle);$finish;end
 if(cycle>200)$fatal(1,"timeout");
end
endmodule
'''
# Avoid active-region source-counter race: nonblocking source update.
tb=tb.replace('sent=sent+1;','sent<=sent+1;')
(OUT/'tb.sv').write_text(tb)
tool=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
libraries=[str(Path(p).resolve()) for p in args.libraries]
for cmd,name in [([str(tool/'bin/iverilog.exe'),'-g2012','-s','tb','-o','test.vvp',str(rtl),*libraries,'tb.sv'],'compile.log'),([str(tool/'bin/vvp.exe'),'test.vvp'],'run.log')]:
 p=subprocess.run(cmd,cwd=OUT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (OUT/name).write_text(p.stdout)
 if p.returncode:raise RuntimeError(p.stdout)
summary={'rtl_status':'PASS','latency':args.latency,'expected_cycles':expected_cycles,'count':len(words),'rtl_sha256':hashlib.sha256(rtl.read_bytes()).hexdigest(),
 'source':str(rtl),'case':str(CASE),'libraries':libraries,'board_mismatches':mismatches,
 'la_equals_serial':((CASE/'decoded.bin').read_bytes()==(CASE/'serial_diagnostic.bin').read_bytes()) if (CASE/'serial_diagnostic.bin').exists() else None,
 'scope':'exact input/config/stall replay on source RTL; not gate timing or board acceptance'}
(OUT/'summary.json').write_text(json.dumps(summary,indent=2));print(OUT);print(json.dumps(summary,indent=2))
