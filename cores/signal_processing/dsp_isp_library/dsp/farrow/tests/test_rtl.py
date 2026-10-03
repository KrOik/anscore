import os,sys,json,random,subprocess,hashlib
from pathlib import Path
from datetime import datetime
BASE=Path(__file__).resolve().parents[1];ROOT=BASE.parents[3]
sys.path.insert(0,str(BASE/'models'));from reference import StreamModel
OUT=BASE/'evidence'/('rtl_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));OUT.mkdir(parents=True)
tool=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy();env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
RTL=BASE/'rtl/farrow_cubic_stream.sv';rng=random.Random(0xFA110)
model=StreamModel();pipe=[None]*5;cd=ce=0;rows=[];accepted=emitted=configs=resets=aborted=0
def tick(rst=1,sv=0,x=0,mr=1,cfg=None):
 global model,pipe,cd,ce,accepted,emitted,configs,resets,aborted
 cv=int(cfg is not None);d,u,clear=cfg or (0,0,0)
 advance=pipe[-1] is None or mr;cr=int(rst and all(p is None for p in pipe));sr=int(rst and advance and not cv)
 mv=int(pipe[-1] is not None);data,clip=pipe[-1] or (0,0)
 rows.append(f'{rst} {sv} {x&65535:x} {mr} {cv} {d} {u} {clear} {sr} {cr} {mv} {data&65535:x} {clip} {cd} {ce}')
 cd=ce=0
 if not rst:
  aborted+=sum(p is not None for p in pipe);model=StreamModel();pipe=[None]*5;resets+=1;return sr,cr
 if mv and mr:emitted+=1
 if cv and cr:cd=1;ce=int(not model.config(d,u,clear));configs+=1
 if advance:
  value=model.sample(x) if sv and sr else None
  if value is not None:accepted+=1
  pipe=[value]+pipe[:-1]
 return sr,cr
def configure(d,u,clear=0):
 for _ in range(1000):
  _,cr=tick(mr=int(rng.random()<.7),cfg=(d,u,clear))
  if cr:return
 raise AssertionError('cfg timeout')
def feed(n,randomize=True):
 for i in range(n):
  x=[-32768,32767,0,-1,1][i%5] if i%7==0 else rng.randrange(-32768,32768)
  if randomize:
   for _ in range(rng.randrange(3)):tick(mr=int(rng.random()<.7))
  for _ in range(1000):
   sr,_=tick(sv=1,x=x,mr=int(not randomize or rng.random()<.7))
   if sr:break
  else:raise AssertionError('input timeout')
tick(rst=0)
for d in range(32):
 for u in (0,1,1024,2048,3072,4095,4096):
  configure(d,u,clear=(u%2));feed(80,randomize=(d%2==0))
  # Long output stalls and stable pending source.
  for _ in range(11):tick(sv=1,x=12345,mr=0)
  tick(sv=1,x=12345,mr=1)
for cfg in [(32,0,1),(63,4096,0),(0,4097,1),(0,8191,0)]:
 configure(*cfg);assert ce;feed(73)
for _ in range(128):configure(rng.randrange(32),rng.randrange(4097),rng.randrange(2));feed(40)
# Smooth updates retain history; reset deliberately aborts filled/stalled pipeline.
for u in range(0,4097,64):configure(2,u);feed(5)
for _ in range(12):
 feed(9);tick(mr=0);tick(rst=0,mr=0);configure(31,2048);feed(38)
for _ in range(20):tick()
assert accepted==emitted+aborted
fixture='\n'.join(rows)+'\n';(OUT/'vectors.txt').write_text(fixture)
TB='''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,sv=0,mr=0,cv=0,clear=0;reg signed[15:0]sd=0;reg[5:0]d=0;reg[12:0]u=0;
wire sr,cr,mv,clip,cd,ce;wire signed[15:0]md;
farrow_cubic_stream dut(clk,rst_n,sd,sv,sr,md,mv,mr,clip,cv,cr,d,u,clear,cd,ce);
integer f,n,row,rr,vv,ready,cc,dd,uu,cl,esr,ecr,ev,ec,ed,ee;reg[15:0]x,y;
initial begin f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
while(!$feof(f))begin @(negedge clk);
n=$fscanf(f,"%d %d %h %d %d %d %d %d %d %d %d %h %d %d %d\\n",rr,vv,x,ready,cc,dd,uu,cl,esr,ecr,ev,y,ec,ed,ee);
if(n!=15)$fatal(1,"fixture");rst_n=rr;sv=vv;sd=x;mr=ready;cv=cc;d=dd;u=uu;clear=cl;#1;
if({sr,cr,mv,cd,ce}!=={esr[0],ecr[0],ev[0],ed[0],ee[0]})$fatal(1,"control row=%0d",row);
if(mv && {md,clip}!=={y,ec[0]})$fatal(1,"data row=%0d got=%h/%b expected=%h/%b",row,md,clip,y,ec[0]);
@(posedge clk);#1;row=row+1;end
$display("PASS rows=%0d",row);$finish;end endmodule
'''
(OUT/'tb.sv').write_text(TB)
def run(cmd,name,reject=False):
 p=subprocess.run(cmd,cwd=OUT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(OUT/name).write_text(p.stdout)
 if (not reject and p.returncode) or (reject and not p.returncode):raise RuntimeError(name+': '+p.stdout)
run([str(tool/'bin/iverilog.exe'),'-g2012','-Wall','-s','tb','-o','test.vvp',str(RTL),'tb.sv'],'compile.log')
run([str(tool/'bin/vvp.exe'),'test.vvp'],'run.log')
negatives=[]
for field,label in [(11,'data'),(10,'valid'),(8,'ready'),(12,'clip'),(13,'cfg_done'),(14,'cfg_error')]:
 altered=rows.copy();idx=next(i for i,r in enumerate(rows) if i>20 and r.split()[10]=='1');cells=altered[idx].split()
 cells[field]=f'{int(cells[field],16)^1:x}' if field==11 else str(int(cells[field])^1);altered[idx]=' '.join(cells)
 (OUT/'vectors.txt').write_text('\n'.join(altered)+'\n');run([str(tool/'bin/vvp.exe'),'test.vvp'],'negative_'+label+'.log',True);negatives.append(label)
(OUT/'vectors.txt').write_text(fixture)
altered=rows.copy();indices=[i for i,r in enumerate(rows) if r.split()[10]=='1' and r.split()[3]=='1']
j=next(j for j in range(len(indices)-1) if rows[indices[j]].split()[11]!=rows[indices[j+1]].split()[11])
a,b=indices[j:j+2];ca,cb=altered[a].split(),altered[b].split();ca[11],cb[11]=cb[11],ca[11]
altered[a]=' '.join(ca);altered[b]=' '.join(cb);(OUT/'vectors.txt').write_text('\n'.join(altered)+'\n')
run([str(tool/'bin/vvp.exe'),'test.vvp'],'negative_order.log',True);negatives.append('order')
(OUT/'vectors.txt').write_text(fixture)
summary={'status':'PASS','cycles':len(rows),'accepted':accepted,'emitted':emitted,'reset_aborted':aborted,'configs':configs,'resets':resets,
 'negative_tests':negatives,'latency':5,'ii':1,'source_sha256':hashlib.sha256(RTL.read_bytes()).hexdigest(),
 'scope':'cycle-level RTL simulation only; no routed timing or board acceptance'}
(OUT/'summary.json').write_text(json.dumps(summary,indent=2));print(OUT);print(json.dumps(summary,indent=2))
