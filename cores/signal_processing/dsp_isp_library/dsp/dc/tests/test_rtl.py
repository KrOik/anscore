import os, sys, random, subprocess, json, hashlib, argparse
from pathlib import Path
from datetime import datetime
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'models'))
from dc_reference import Config, FixedReference
BASE=Path(__file__).resolve().parents[1]
ROOT=BASE.parents[3]
parser=argparse.ArgumentParser();parser.add_argument('rtl',nargs='?',default=str(BASE/'rtl/dc_stream.sv'));parser.add_argument('--latency',type=int,choices=[1,2])
args=parser.parse_args();RTL=Path(args.rtl).resolve()
if args.latency is None:
    args.latency=json.loads((BASE/'ip_manifest.json').read_text())['latency_cycles'] if RTL==(BASE/'rtl/dc_stream.sv').resolve() else 1
OUT=BASE/'evidence'/('rtl_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
rng=random.Random(0xDC091)
model=FixedReference()
valid=False; data=0; done=error=0; pending=None; source=None
front=False;front_data=0
rows=[]; transfers=[]; cfgs=0; reset_count=0; seen=set()
for cycle in range(24000):
    rst=int(cycle%1901 not in (0,1))
    ready=int(cycle%500<180 or (cycle%500>=230 and rng.random()<.65))
    if cycle%233==7 and pending is None:
        idx=cycle//233
        pending=(idx%4,[0,32768,65024,65535][(idx//4)%4],[0,1,4,8,9][(idx//16)%5])
    cv=int(pending is not None)
    cm,cp,cl=pending or (0,0,0)
    if source is None and (cycle%500<180 or rng.random()<.7):
        source=rng.choice([-32768,32767,0,10000,rng.randrange(-32768,32768)])
    sv=int(source is not None); sd=source or 0
    out_ready=not valid or ready
    space=out_ready if args.latency==1 else not front or out_ready
    sr=int(rst and not cv and space); cr=int(rst and not valid and (args.latency==1 or not front))
    rows.append(f'{rst} {cv} {cm} {cp} {cl} {sv} {sd & 65535:x} {ready} {sr} {cr} {int(valid)} {data:08x} {done} {error}')
    done=error=0
    if not rst:
        model=FixedReference(); valid=False; front=False; data=0; reset_count+=1
    else:
        if valid and ready: transfers.append(data)
        if args.latency==1:
            if ready:valid=False
        else:
            if out_ready:
                valid=front
                if front:data=front_data
            if space:front=False
        if cv and cr:
            done=1; cfgs+=1
            if cm==3 or cl>8: error=1
            else:
                model.configure(Config(['blocker','mean','baseline'][cm],cp,cl))
                seen.add((cm,cp,cl))
            pending=None
        if sv and sr:
            y,b=model.step(sd)
            word=((b&65535)<<16)|(y&65535)
            if args.latency==1:data=word;valid=True
            else:front_data=word;front=True
            source=None
(OUT/'vectors.txt').write_text('\n'.join(rows)+'\n')
tb='''module tb;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,sv=0,mr=0,cv=0; reg signed [15:0] sd=0;
reg [1:0] cm=0; reg [15:0] cp=0; reg [3:0] cl=0;
wire sr,cr,mv,cd,ce; wire [31:0] md;
dc_stream dut(clk,rst_n,sd,sv,sr,md,mv,mr,cv,cr,cm,cp,cl,cd,ce);
integer f,n,row,rr,vv,mm,pp,ll,ss,rrdy,esr,ecr,ev,ed,ee;
reg [15:0] dd; reg [31:0] expected;
initial begin
 f=$fopen("vectors.txt","r"); row=0;
 // Establish synchronous reset before observing first expected state.
 @(posedge clk); #1;
 while(!$feof(f)) begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %d %d %d %d %h %d %d %d %d %h %d %d\\n",rr,vv,mm,pp,ll,ss,dd,rrdy,esr,ecr,ev,expected,ed,ee);
  if(n!=14) $fatal(1,"bad fixture");
  rst_n=rr;cv=vv;cm=mm;cp=pp;cl=ll;sv=ss;sd=dd;mr=rrdy;
  #1;
  if(sr !== esr[0] || cr !== ecr[0] || mv !== ev[0] || cd !== ed[0] || ce !== ee[0])
    $fatal(1,"control row %0d sr=%b/%b cr=%b/%b mv=%b/%b cd=%b/%b ce=%b/%b",row,sr,esr[0],cr,ecr[0],mv,ev[0],cd,ed[0],ce,ee[0]);
  if(mv && md !== expected) $fatal(1,"data row %0d got=%h expected=%h",row,md,expected);
  @(posedge clk); #1; row=row+1;
 end
 $display("PASS rows=%0d",row); $finish;
end
endmodule
'''
(OUT/'tb.sv').write_text(tb)
env=os.environ.copy()
tool=ROOT/'tools/oss-cad-suite/oss-cad-suite'
env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
def run(args,name):
    p=subprocess.run(args,cwd=OUT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (OUT/name).write_text(p.stdout)
    if p.returncode: raise RuntimeError(p.stdout)
run([str(tool/'bin/iverilog.exe'),'-g2012','-Wall','-s','tb','-o','test.vvp',str(RTL),'tb.sv'],'compile.log')
run([str(tool/'bin/vvp.exe'),'test.vvp'],'run.log')
# Prove executable scoreboard rejects corrupted numeric/control expectations.
original=(OUT/'vectors.txt').read_text()
negative=[]
for field,label in [(11,'data'),(10,'valid_count'),(8,'ready'),(12,'config_status')]:
    altered=rows.copy(); idx=next(i for i,r in enumerate(rows) if i>20 and r.split()[10]=='1')
    cells=altered[idx].split(); cells[field]=('deadbeef' if field==11 else str(1-int(cells[field])))
    altered[idx]=' '.join(cells); (OUT/'vectors.txt').write_text('\n'.join(altered)+'\n')
    p=subprocess.run([str(tool/'bin/vvp.exe'),'test.vvp'],cwd=OUT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (OUT/('negative_'+label+'.log')).write_text(p.stdout)
    assert p.returncode!=0,label
    negative.append(label)
(OUT/'vectors.txt').write_text(original)
summary={'status':'PASS','latency':args.latency,'cycles':len(rows),'output_transfers':len(transfers),'config_transactions':cfgs,
 'reset_edges':reset_count,'configurations':sorted(seen),'negative_tests':negative,
 'rtl_source':str(RTL),'rtl_sha256':hashlib.sha256(RTL.read_bytes()).hexdigest(),
 'scope':'RTL simulation only; synthesis/P&R/physical acceptance pending'}
(OUT/'summary.json').write_text(json.dumps(summary,indent=2))
print(OUT); print(json.dumps(summary,indent=2))
