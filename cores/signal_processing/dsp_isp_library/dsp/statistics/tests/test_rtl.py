import os,sys,random,subprocess,json,hashlib,itertools
from pathlib import Path
from datetime import datetime
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'models'))
from reference import Config,IntegerModel,pack
BASE=Path(__file__).resolve().parents[1]; ROOT=BASE.parents[3]
OUT=BASE/'evidence'/('rtl_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f')); OUT.mkdir()
env=os.environ.copy(); tool=ROOT/'tools/oss-cad-suite/oss-cad-suite'
env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
rng=random.Random(0x5041)
configs=list(itertools.product([0,1],range(7),[-8,-1,0,1,8,15]))+[(0,7,0),(1,0,-9)]
# Output is now an elastic 17-slot result pipe: leaf output register plus 16
# registered restoring-root stages. Latency 17, II=1; input stalls only when
# the pipe is full; config is accepted only when the pipe is empty.
LAT=17
rows=[]; seen=set(); cfgcount=outcount=resetcount=0
live_resets=cfg_wait=illegal=0
model=IntegerModel(); slots=[None]*LAT; done=error=0; pending=source=None
for cycle in range(39000):
 rst=int(cycle%2903 not in (0,1)); ready=int(cycle%401<150 or (cycle%401>=201 and rng.random()<.7))
 if cycle%431==7 and pending is None:
  b,l,s=configs[(cycle//431)%len(configs)]
  pending=(b,l,s,[0,49,0x10000000,0xffffffff][(cycle//431)%4])
 cv=int(pending is not None); cb,cl,cs,ct=pending or (0,0,0,0)
 if source is None and (cycle%401<150 or rng.random()<.7):
  source=rng.choice([-32768,32767,0,7,-7,10000,rng.randrange(-32768,32768)])
 sv=int(source is not None); sd=source or 0
 rdy=[False]*LAT
 for i in reversed(range(LAT)):rdy[i]=slots[i] is None or (ready if i==LAT-1 else rdy[i+1])
 sr=int(rst and not cv and rdy[0]); cr=int(rst and all(x is None for x in slots))
 valid=slots[-1] is not None; data,user=slots[-1] or (0,0)
 rows.append(f'{rst} {cv} {cb} {cl} {cs&31:x} {ct:x} {sv} {sd&65535:x} {ready} {sr} {cr} {int(valid)} {data:032x} {user:x} {done} {error}')
 done=error=0
 if not rst:
  live_resets+=int(any(x is not None for x in slots))
  model=IntegerModel();slots=[None]*LAT;resetcount+=1
 else:
  if valid and ready:outcount+=1
  if cv and not cr:cfg_wait+=1
  nxt=[None if i==0 else slots[i-1] for i in range(LAT)]
  slots=[nxt[i] if rdy[i] else slots[i] for i in range(LAT)]
  if cv and cr:
   done=1;cfgcount+=1
   if cl>6 or cs < -8:error=1;illegal+=1
   else:model.configure(Config(bool(cb),cl,cs,ct));seen.add((cb,cl,cs))
   pending=None
  if sv and sr:
   slots[0]=pack(model.step(sd));source=None
fixture='\n'.join(rows)+'\n'; (OUT/'vectors.txt').write_text(fixture)
tb=r'''module tb;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,sv=0,mr=0,cv=0,cb=0; reg signed [15:0] sd=0;
reg [3:0] cl=0; reg signed [4:0] cs=0; reg [31:0] ct=0;
wire sr,cr,mv,cd,ce; wire [127:0] md; wire [1:0] mu;
statistics_stream dut(clk,rst_n,sd,sv,sr,md,mu,mv,mr,cv,cr,cb,cl,cs,ct,cd,ce);
wire lsr,lcr,lmv,lcd,lce; wire [127:0] lmd; wire [1:0] lmu;
statistics_stream #(.LOGIC_SQUARE(1)) logic_dut(clk,rst_n,sd,sv,lsr,lmd,lmu,lmv,mr,cv,lcr,cb,cl,cs,ct,lcd,lce);
integer f,n,row,rr,vv,bb,ll,ss,rrdy,esr,ecr,ev,ed,ee;
reg [15:0] dd; reg [4:0] sc; reg [31:0] th; reg [127:0] expected; reg [1:0] eu;
initial begin
 f=$fopen("vectors.txt","r"); row=0;
 @(posedge clk); #1;
 while(!$feof(f)) begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %d %d %h %h %d %h %d %d %d %d %h %h %d %d\n",rr,vv,bb,ll,sc,th,ss,dd,rrdy,esr,ecr,ev,expected,eu,ed,ee);
  if(n!=16) $fatal(1,"bad fixture");
  rst_n=rr;cv=vv;cb=bb;cl=ll;cs=sc;ct=th;sv=ss;sd=dd;mr=rrdy;
  #1;
  if({lsr,lcr,lmv,lcd,lce} !== {sr,cr,mv,cd,ce}) $fatal(1,"logic-square control equivalence row %0d",row);
  if(lmv && {lmd,lmu} !== {md,mu}) $fatal(1,"logic-square data equivalence row %0d",row);
  if(sr !== esr[0] || cr !== ecr[0] || mv !== ev[0] || cd !== ed[0] || ce !== ee[0])
    $fatal(1,"control row %0d sr=%b/%b cr=%b/%b mv=%b/%b cd=%b/%b ce=%b/%b",row,sr,esr[0],cr,ecr[0],mv,ev[0],cd,ed[0],ce,ee[0]);
  if(mv && (md !== expected || mu !== eu)) $fatal(1,"data row %0d got=%h/%h expected=%h/%h",row,md,mu,expected,eu);
  @(posedge clk); #1; row=row+1;
 end
 $display("PASS rows=%0d",row); $finish;
end
endmodule
'''.replace(r'\"','"').replace(r'\\n',r'\n')
# raw TB literal uses ordinary quotes; no shell-generated interpolation.
tb=tb.replace('\\"','"')
(OUT/'tb.sv').write_text(tb)
def run(args,name):
 p=subprocess.run(args,cwd=OUT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (OUT/name).write_text(p.stdout)
 if p.returncode:raise RuntimeError(p.stdout)
run([str(tool/'bin/iverilog.exe'),'-g2012','-Wall','-s','tb','-o','test.vvp',str(BASE/'rtl/statistics_stream.sv'),'tb.sv'],'compile.log')
run([str(tool/'bin/vvp.exe'),'test.vvp'],'run.log')
negative=[]
for field,label in [(12,'data'),(12,'rms'),(11,'valid_count'),(9,'ready'),(13,'flags'),(14,'config_status'),(12,'order')]:
 altered=rows.copy();idx=next(i for i,r in enumerate(rows) if i>20 and r.split()[11]=='1')
 cells=altered[idx].split()
 if label=='data':cells[field]='deadbeef'
 elif label=='rms':cells[field]=f'{int(cells[field],16)^(1<<32):032x}'
 elif label=='order':
  other=next(r.split()[12] for r in rows[idx+1:] if r.split()[11]=='1' and r.split()[12]!=cells[12]);cells[field]=other
 else:cells[field]=str(1-int(cells[field]))
 altered[idx]=' '.join(cells);(OUT/'vectors.txt').write_text('\n'.join(altered)+'\n')
 p=subprocess.run([str(tool/'bin/vvp.exe'),'test.vvp'],cwd=OUT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (OUT/('negative_'+label+'.log')).write_text(p.stdout); assert p.returncode!=0,label
 negative.append(label)
(OUT/'vectors.txt').write_text(fixture)
assert len(seen)==84,len(seen)
assert live_resets>0 and cfg_wait>0 and illegal>0,(live_resets,cfg_wait,illegal)
summary={'status':'PASS','stats_latency':LAT,'cycles':len(rows),'output_transfers':outcount,'configs':cfgcount,'reset_edges':resetcount,
 'resets_with_inflight_results':live_resets,'config_wait_cycles_on_drain':cfg_wait,'illegal_configs':illegal,
 'logic_square_variants':[0,1],'comparison':'both variants cycle-identical and checked against independent oracle',
 'legal_config_count':len(seen),'negative_tests':negative,
 'rtl_sha256':hashlib.sha256((BASE/'rtl/statistics_stream.sv').read_bytes()).hexdigest(),
 'scope':'RTL only; no physical or P&R acceptance'}
(OUT/'summary.json').write_text(json.dumps(summary,indent=2)); print(OUT);print(json.dumps(summary,indent=2))
