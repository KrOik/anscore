import os,sys,json,random,subprocess,hashlib
from pathlib import Path
from datetime import datetime
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'models'))
from reference import Config,design,integer_reference,rne
BASE=Path(__file__).resolve().parents[1];ROOT=BASE.parents[3]
OUT=BASE/'evidence'/('rtl_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));OUT.mkdir()
tool=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy();env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
RTL=BASE/'rtl/polyphase_resampler.sv';MAX_INPUTS=255

class Oracle:
 def __init__(self):self.rows=[];self.clock=0;self.reset()
 def reset(self):
  self.cfg=Config();self.xs=[];self.virtual=0;self.time=0;self.end=0;self.busy=0;self.draining=False;self.finished=False
  self.valid=False;self.data=self.flag=self.outcount=self.capacity=0;self.cd=self.ce=self.fd=0;self.result=None;self.outputs=[]
 def start(self):
  cfg=self.cfg;t=self.time
  acc=sum(x*cfg.coefficients[t-n*cfg.l] for n,x in enumerate(self.xs) if 0<=t-n*cfg.l<len(cfg.coefficients))
  wide=rne(acc);self.result=(min(32767,max(-32768,wide)),int(not -32768<=wide<=32767))
  # Per tap the RTL runs MULTIPLY then ACCUMULATE, and the last ACCUMULATE
  # raises m_tvalid itself, so the pipeline has no rounding or emit tail.
  self.busy=2*len(range(t%cfg.l,len(cfg.coefficients),cfg.l))
 def tick(self,rst=1,configuration=None,flush=0,sv=0,x=0,ready=1):
  cv=int(configuration is not None);l,m,taps,co=configuration or (1,1,1,(32768,))
  packed=sum((c&0x3ffff)<<(18*i) for i,c in enumerate(co)) if cv else 0
  advance=bool(rst and (not self.valid or ready));idle=not self.busy
  cr=int(rst and idle and not self.valid and not self.draining)
  fr=int(rst and idle and not self.finished and not self.valid and not self.draining and not cv)
  need=self.time//self.cfg.l>=self.virtual
  sr=int(advance and idle and not self.finished and need and not self.draining and not cv and not flush and len(self.xs)<MAX_INPUTS)
  self.rows.append(f'{rst} {cv} {l} {m} {taps} {packed:x} {flush} {sv} {x&65535:x} {ready} {sr} {cr} {fr} {int(self.valid)} {self.data&65535:x} {self.flag} {self.cd} {self.ce} {self.fd} {len(self.xs)} {self.outcount} {self.capacity}')
  self.clock+=1;self.cd=self.ce=self.fd=0
  if not rst:self.reset();return sr,cr,fr
  if self.valid and ready:self.outputs.append((self.data,self.flag));self.outcount+=1
  if ready:self.valid=False
  if idle and not self.finished and need and not self.draining and not cv and not flush and sv and len(self.xs)==MAX_INPUTS:self.capacity=1
  if cv and cr:
   self.cd=1
   try:
    if taps!=len(co):raise ValueError('encoded count')
    cfg=Config(l,m,tuple(co))
   except ValueError:self.ce=1
   else:
    self.cfg=cfg;self.xs=[];self.virtual=self.time=self.end=self.busy=0;self.draining=self.finished=False;self.capacity=self.outcount=0;self.outputs=[]
  elif flush and fr:
   if not self.xs:self.finished=True;self.fd=1
   else:self.draining=True;self.end=(len(self.xs)-1)*self.cfg.l+len(self.cfg.coefficients)-1
  elif advance:
   if self.busy:
    self.busy-=1
    if self.busy==0:self.data,self.flag=self.result;self.valid=True;self.time+=self.cfg.m
   elif not self.finished:
    if self.draining and self.time>self.end:self.finished=True;self.draining=False;self.fd=1
    elif self.draining or (not cv and not flush):
     if not need:self.start()
     elif self.draining or (sv and sr):
      if not self.draining:self.xs.append(x)
      self.virtual+=1
      if self.time//self.cfg.l<self.virtual:self.start()
  return sr,cr,fr

rng=random.Random(0x5012);o=Oracle();cases=[]
def ready(randomize):return int(not randomize or (o.clock%397>=51 and rng.random()<.72))
def configure(cfg,randomize=False):
 request=(cfg.l,cfg.m,len(cfg.coefficients),cfg.coefficients)
 for _ in range(100000):
  _,cr,_=o.tick(configuration=request,ready=ready(randomize))
  if cr:return
 raise AssertionError('config timeout')
def feed(xs,randomize=False):
 for x in xs:
  if randomize:
   for _ in range(rng.randrange(3)):o.tick(ready=ready(True))
  for _ in range(100000):
   sr,_,_=o.tick(sv=1,x=x,ready=ready(randomize))
   if sr:break
  else:raise AssertionError('input timeout')
def flush(randomize=False):
 for _ in range(100000):
  _,_,fr=o.tick(flush=1,ready=ready(randomize))
  if fr:break
 else:raise AssertionError('flush request timeout')
 for _ in range(100000):
  if o.finished:break
  o.tick(ready=ready(randomize))
 else:raise AssertionError('flush completion timeout')
 o.tick();assert o.outputs==integer_reference(o.xs,o.cfg)
for l in range(1,9):
 for m in range(1,9):
  cfg,_=design(l,m,16);o.tick(rst=0);configure(cfg)
  xs=[-32768,32767,0,-1]+[rng.randrange(-20000,20001) for _ in range(9)]
  feed(xs,randomize=(l+m)%2==0);flush(randomize=(l+m)%2==0)
  cases.append({'l':l,'m':m,'taps':16,'inputs':len(xs),'outputs':o.outcount,'kind':'fullblock'})
for l,m in [(1,1),(1,8),(8,1),(3,2),(2,3),(8,7)]:
 cfg,_=design(l,m,128);configure(cfg)
 xs=[rng.randrange(-32768,32768) for _ in range(137 if (l,m)==(1,8) else 17)]
 feed(xs,True);flush(True);cases.append({'l':l,'m':m,'taps':128,'inputs':len(xs),'outputs':o.outcount,'kind':'max_taps'})
# Minimum taps, signed coefficient extremes and output saturation.
for l,m in [(1,1),(8,1),(1,8),(3,2)]:
 cfg=Config(l,m,tuple([131071,-131072]*4)[:l]);configure(cfg)
 feed([-32768,32767]*8,True);flush(True);cases.append({'l':l,'m':m,'taps':l,'kind':'minimum_extreme','outputs':o.outcount})
# Invalid update while computing must wait and preserve both state and coefficients.
configure(Config());feed([1234]);before=o.cfg
for req in [(0,1,1,(1,)),(1,9,1,(1,)),(8,1,2,(1,1)),(1,1,129,(1,)*128)]:
 for _ in range(100000):
  _,cr,_=o.tick(configuration=req,ready=1)
  if cr:break
 assert o.ce==1 and o.cfg==before
o.tick();feed([5,-7]);flush()
# Empty block flush and reset during active MAC, with history retained.
configure(Config());flush();assert o.outcount==0
cfg,_=design(1,1,128);configure(cfg);feed([32767]);o.tick(rst=0);o.tick(rst=0);configure(cfg);feed([1,-1,7]);flush(True)
# Capacity is explicit and does not consume the blocked input; flush still works.
configure(Config());feed([i-128 for i in range(MAX_INPUTS)])
for _ in range(20):o.tick(sv=1,x=123,ready=1)
assert o.capacity and len(o.xs)==MAX_INPUTS
flush();o.tick(rst=0);o.tick()
fixture='\n'.join(o.rows)+'\n';(OUT/'vectors.txt').write_text(fixture)
TB='''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,fv=0,sv=0,mr=0;reg[3:0]l=1,m=1;reg[7:0]t=1;reg[2303:0]co=0;reg signed[15:0]sd=0;
wire sr,cr,fr,cd,ce,fd,mv,mu,cap;wire signed[15:0]md;wire[15:0]inc;wire[19:0]outc;
polyphase_resampler #(.MAX_INPUTS(255)) dut(clk,rst_n,sd,sv,sr,md,mu,mv,mr,cv,cr,l,m,t,co,cd,ce,fv,fr,fd,inc,outc,cap);
integer f,n,row,rr,vv,ll,mm,tt,ff,ss,rdy,esr,ecr,efr,ev,eu,ed,ee,efd,ei,eo,ec;reg[2303:0]cc;reg[15:0]dd,expected;
initial begin
 f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %d %d %d %h %d %d %h %d %d %d %d %d %h %d %d %d %d %d %d %d\\n",rr,vv,ll,mm,tt,cc,ff,ss,dd,rdy,esr,ecr,efr,ev,expected,eu,ed,ee,efd,ei,eo,ec);
  if(n!=22)$fatal(1,"fixture row=%0d n=%0d",row,n);rst_n=rr;cv=vv;l=ll;m=mm;t=tt;co=cc;fv=ff;sv=ss;sd=dd;mr=rdy;#1;
  if({sr,cr,fr,mv,cd,ce,fd,cap}!=={esr[0],ecr[0],efr[0],ev[0],ed[0],ee[0],efd[0],ec[0]})$fatal(1,"control row=%0d got=%b expected=%b",row,{sr,cr,fr,mv,cd,ce,fd,cap},{esr[0],ecr[0],efr[0],ev[0],ed[0],ee[0],efd[0],ec[0]});
  if(inc!==ei[15:0] || outc!==eo[19:0])$fatal(1,"count row=%0d got=%0d/%0d expected=%0d/%0d",row,inc,outc,ei,eo);
  if(mv && {md,mu}!=={expected,eu[0]})$fatal(1,"data row=%0d got=%h/%b expected=%h/%b",row,md,mu,expected,eu[0]);
  @(posedge clk);#1;row=row+1;
 end
 $display("PASS rows=%0d",row);$finish;
end
endmodule
'''
(OUT/'tb.sv').write_text(TB)
def run(cmd,name,reject=False):
 p=subprocess.run(cmd,cwd=OUT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(OUT/name).write_text(p.stdout)
 if (not reject and p.returncode) or (reject and not p.returncode):raise RuntimeError(name+': '+p.stdout)
run([str(tool/'bin/iverilog.exe'),'-g2012','-Wall','-s','tb','-o','test.vvp',str(RTL),'tb.sv'],'compile.log')
run([str(tool/'bin/vvp.exe'),'test.vvp'],'run.log')
negatives=[]
for field,label in [(14,'data'),(13,'valid_count'),(10,'ready'),(15,'clip'),(18,'flush_done'),(20,'output_count')]:
 altered=o.rows.copy();idx=next(i for i,r in enumerate(o.rows) if i>20 and r.split()[13]=='1');cells=altered[idx].split()
 cells[field]=f'{int(cells[field],16)^1:x}' if field==14 else str(int(cells[field])^1)
 altered[idx]=' '.join(cells);(OUT/'vectors.txt').write_text('\n'.join(altered)+'\n')
 run([str(tool/'bin/vvp.exe'),'test.vvp'],'negative_'+label+'.log',reject=True);negatives.append(label)
(OUT/'vectors.txt').write_text(fixture)
altered=o.rows.copy()
indices=[i for i,r in enumerate(o.rows) if r.split()[13]=='1' and r.split()[9]=='1']
first=next(j for j in range(len(indices)-1) if o.rows[indices[j]].split()[14]!=o.rows[indices[j+1]].split()[14])
a,b=indices[first:first+2];ca,cb=altered[a].split(),altered[b].split();ca[14],cb[14]=cb[14],ca[14]
altered[a]=' '.join(ca);altered[b]=' '.join(cb);(OUT/'vectors.txt').write_text('\n'.join(altered)+'\n')
run([str(tool/'bin/vvp.exe'),'test.vvp'],'negative_output_order.log',reject=True);negatives.append('output_order')
(OUT/'vectors.txt').write_text(fixture)
for parameter,value in [('MAX_TAPS',0),('MAX_TAPS',129),('MAX_INPUTS',0),('MAX_INPUTS',65536)]:
 (OUT/'illegal.sv').write_text(f'module illegal; polyphase_resampler #(.{parameter}({value})) dut(); endmodule\n')
 run([str(tool/'bin/iverilog.exe'),'-g2012','-s','illegal','-o','illegal.vvp',str(RTL),'illegal.sv'],f'static_{parameter}_{value}_compile.log')
 run([str(tool/'bin/vvp.exe'),'illegal.vvp'],f'static_{parameter}_{value}_run.log',reject=True)
 negatives.append(f'{parameter}_{value}')
summary={'status':'PASS','cycles':len(o.rows),'cases':cases,'negative_tests':negatives,'rtl_sha256':hashlib.sha256(RTL.read_bytes()).hexdigest(),
 'scope':'serialized shared-multiplier RTL; no II1/P&R/board claim'}
(OUT/'summary.json').write_text(json.dumps(summary,indent=2));print(OUT);print('PASS cycles',len(o.rows),'cases',len(cases))
