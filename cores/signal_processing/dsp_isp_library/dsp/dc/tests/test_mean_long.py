"""Long mean-window regression on preserved original and frozen candidate."""
import os,sys,json,random,subprocess,hashlib,argparse
from pathlib import Path
from datetime import datetime
BASE=Path(__file__).resolve().parents[1];ROOT=BASE.parents[3]
sys.path.insert(0,str(BASE/'models'))
from dc_reference import Config,FixedReference
OUT=BASE/'evidence'/('mean_long_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));OUT.mkdir()
tool=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
parser=argparse.ArgumentParser();parser.add_argument('candidate',nargs='?',default=str(BASE/'rtl/dc_stream.sv'));parser.add_argument('--latency',type=int,choices=[1,2])
args=parser.parse_args()
if args.latency is None:
 args.latency=json.loads((BASE/'ip_manifest.json').read_text())['latency_cycles'] if Path(args.candidate).resolve()==(BASE/'rtl/dc_stream.sv').resolve() else 1
sources=([BASE/'evidence/board_repro_20260925_0300/original_dc_stream.sv'] if args.latency==1 else [])+[Path(args.candidate).resolve()]
rng=random.Random(0xDC256); rows=[]; cases=[]
valid=False;data=0;done=error=0;model=FixedReference()
front=False;front_data=0
def tick(rst=1,cv=0,lg=0,sv=0,x=0,ready=1):
 global valid,data,done,error,model,front,front_data
 out_ready=not valid or ready;space=out_ready if args.latency==1 else not front or out_ready
 sr=int(rst and not cv and space);cr=int(rst and not valid and (args.latency==1 or not front))
 rows.append(f'{rst} {cv} {lg} {sv} {x&65535:x} {ready} {sr} {cr} {int(valid)} {data:08x} {done} {error}')
 done=error=0
 if not rst:model=FixedReference();valid=False;front=False;data=0
 else:
  if args.latency==1:
   if ready:valid=False
  else:
   if out_ready:
    valid=front
    if front:data=front_data
   if space:front=False
  if cv and cr:model.configure(Config('mean',65024,lg));done=1
  if sv and sr:
   y,b=model.step(x);word=((b&65535)<<16)|(y&65535)
   if args.latency==1:data=word;valid=True
   else:front_data=word;front=True
 return sr
for lg in [0,1,4,8]:
 for random_stall in [False,True]:
  # Each reset leaves all ring RAM physically retained from preceding test.
  # First epoch fills/wraps; interrupt with a live output, then repeat fresh.
  for epoch in [0,1]:
   tick(rst=0);tick(rst=0)
   tick(cv=1,lg=lg)
   n=3*(1<<lg)+33;accepted=0;cycles=0;pending=None
   while accepted<n:
    if pending is None and (not random_stall or rng.random()<.78):
     pending=rng.choice([-32768,32767,0,10000,rng.randrange(-32768,32768)])
    ready=int(not random_stall or (cycles%251>=47 and rng.random()<.67))
    fire=tick(sv=int(pending is not None),x=pending or 0,ready=ready)
    if pending is not None and fire:accepted+=1;pending=None
    cycles+=1
   # Drain normal epochs, but deliberately reset a held output on epoch zero.
   if epoch==1:
    tick();tick()
   else:tick(ready=0)
   cases.append({'window':1<<lg,'random_stall':random_stall,'epoch':epoch,'accepted':accepted,'cycles':cycles})
(OUT/'vectors.txt').write_text('\n'.join(rows)+'\n')
tb='''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,sv=0,mr=0;reg[3:0]lg=0;reg signed[15:0]sd=0;
wire sr,cr,cd,ce,mv;wire[31:0]md;
dc_stream dut(clk,rst_n,sd,sv,sr,md,mv,mr,cv,cr,2'd1,16'd65024,lg,cd,ce);
integer f,n,row,rr,vv,ll,ss,rdy,esr,ecr,ev,ed,ee;reg[15:0]dd;reg[31:0]expected;
initial begin
 f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %d %d %h %d %d %d %d %h %d %d\\n",rr,vv,ll,ss,dd,rdy,esr,ecr,ev,expected,ed,ee);
  if(n!=12)$fatal(1,"fixture");rst_n=rr;cv=vv;lg=ll;sv=ss;sd=dd;mr=rdy;#1;
  if({sr,cr,mv,cd,ce}!=={esr[0],ecr[0],ev[0],ed[0],ee[0]})$fatal(1,"control row=%0d",row);
  if(mv && md!==expected)$fatal(1,"data row=%0d got=%h expected=%h",row,md,expected);
  @(posedge clk);#1;row=row+1;
 end
 $display("PASS long mean rows=%0d",row);$finish;
end
endmodule
'''
(OUT/'tb.sv').write_text(tb);reports=[]
for variant,source in enumerate(sources):
 for cmd,name in [([str(tool/'bin/iverilog.exe'),'-g2012','-s','tb','-o',f'{variant}.vvp',str(source),'tb.sv'],'compile'),([str(tool/'bin/vvp.exe'),f'{variant}.vvp'],'run')]:
  p=subprocess.run(cmd,cwd=OUT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  (OUT/f'{variant}_{name}.log').write_text(p.stdout)
  if p.returncode:raise RuntimeError(p.stdout)
 reports.append({'source':str(source),'sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'status':'PASS'})
summary={'status':'PASS','latency':args.latency,'cycles':len(rows),'cases':cases,'variants':reports,
 'scope':'RAM startup/fill/three-wrap/reset-retained-history simulation; no new physical evidence'}
(OUT/'summary.json').write_text(json.dumps(summary,indent=2));print(OUT);print('PASS',len(rows),'cycles',len(cases),'cases,',len(sources),'variants')
