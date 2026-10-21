import os,sys,json,random,subprocess,hashlib
from pathlib import Path
from datetime import datetime
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'models'))
from reference import IntegerModel,IDENTITY,lowpass
BASE=Path(__file__).resolve().parents[1];ROOT=BASE.parents[3]
OUT=BASE/'evidence'/('rtl_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));OUT.mkdir()
tool=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
RTL=BASE/'rtl/biquad_sos_stream.sv'

def fixtures(max_sos):
 rng=random.Random(0x5020+max_sos);model=IntegerModel(max_sos)
 rows=[];busy=0;valid=False;data=user=done=error=0;result=None;source=pending=None
 stats={'accepts':0,'outputs':0,'config_accepts':0,'config_errors':0,'clear':0,'retain':0,'resets':0,'sections_seen':set()}
 for cycle in range(36000):
  rst=int(cycle%3109 not in (0,1));ready=int(cycle%503<180 or (cycle%503>=240 and rng.random()<.7))
  if cycle%887==7 and pending is None:
   k=cycle//887;ns=1+(k//4)%max_sos
   coeff=[IDENTITY,lowpass(),(8192,0,0,-32768,8192),(131071,0,0,-16384,0),(32,0,0,-32736,0),(-131072,131071,-32768,16384,8192),(32,0,0,0,32736)][k%7]
   sections=(coeff,)*ns;clear=int(k%3!=2)
   if k%11==5:sections=((0,0,0,-32768,0),)*ns
   if k%13==6:ns=0
   if k%17==9:ns=max_sos+1
   pending=(ns,clear,sections)
  cv=int(pending is not None);ns,clear,sections=pending or (1,1,(IDENTITY,))
  packed=sum((v&0x3ffff)<<(18*(s*5+i)) for s,section in enumerate(sections[:max_sos]) for i,v in enumerate(section))
  if source is None and (cycle%503<180 or rng.random()<.75):
   source=32767 if cycle%1700<700 else rng.choice([-32768,32767,0,1,-1,rng.randrange(-32768,32768)])
  sv=int(source is not None);x=source or 0
  sr=int(rst and not busy and not cv and (not valid or ready));cr=int(rst and not busy and not valid)
  rows.append(f'{rst} {cv} {ns} {clear} {packed:x} {sv} {x&65535:x} {ready} {sr} {cr} {int(valid)} {data&65535:x} {user} {done} {error}')
  done=error=0
  if not rst:
   model=IntegerModel(max_sos);busy=0;valid=False;data=user=0;stats['resets']+=1
  else:
   if valid and ready:stats['outputs']+=1
   if ready:valid=False
   if busy:
    busy-=1
    if busy==0:data,user=result;valid=True
   if cv and cr:
    done=1;stats['config_accepts']+=1
    try:
     if not 1<=ns<=max_sos:raise ValueError('count')
     model.configure(sections,clear=bool(clear))
    except ValueError:error=1;stats['config_errors']+=1
    else:
     stats['clear' if clear else 'retain']+=1;stats['sections_seen'].add(ns)
    pending=None
   if sv and sr:
    result=model.step(x);busy=7*len(model.sections);source=None;stats['accepts']+=1
 stats['sections_seen']=sorted(stats['sections_seen'])
 return rows,stats

def run(cmd,d,name,expect=0):
 p=subprocess.run(cmd,cwd=d,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (d/name).write_text(p.stdout)
 if expect==0 and p.returncode:raise RuntimeError(p.stdout)
 if expect!=0 and not p.returncode:raise AssertionError(name+' did not reject')

TB='''module tb;
localparam MAX=PARAM;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,cc=0,sv=0,mr=0;reg[2:0]ns=1;reg[90*MAX-1:0]coeff=0;reg signed[15:0]sd=0;
wire sr,cr,cd,ce,mv,mu;wire signed[15:0]md;
biquad_sos_stream #(.MAX_SOS(MAX)) dut(clk,rst_n,sd,sv,sr,md,mu,mv,mr,cv,cr,ns,cc,coeff,cd,ce);
integer f,n,row,rr,vv,nn,clear,ss,rdy,esr,ecr,ev,eu,ed,ee;reg[90*MAX-1:0]co;reg[15:0]dd,expected;
initial begin
 f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %d %d %h %d %h %d %d %d %d %h %d %d %d\\n",rr,vv,nn,clear,co,ss,dd,rdy,esr,ecr,ev,expected,eu,ed,ee);
  if(n!=15)$fatal(1,"fixture");rst_n=rr;cv=vv;ns=nn;cc=clear;coeff=co;sv=ss;sd=dd;mr=rdy;#1;
  if({sr,cr,mv,cd,ce}!=={esr[0],ecr[0],ev[0],ed[0],ee[0]})$fatal(1,"control row=%0d got=%b expected=%b",row,{sr,cr,mv,cd,ce},{esr[0],ecr[0],ev[0],ed[0],ee[0]});
  if(mv && {md,mu}!=={expected,eu[0]})$fatal(1,"data row=%0d got=%h/%b expected=%h/%b",row,md,mu,expected,eu[0]);
  @(posedge clk);#1;row=row+1;
 end
 $display("PASS rows=%0d MAX=%0d",row,MAX);$finish;
end
endmodule
'''
reports=[]
for max_sos in [1,2,3,4]:
 d=OUT/str(max_sos);d.mkdir();rows,stats=fixtures(max_sos);fixture='\n'.join(rows)+'\n'
 (d/'vectors.txt').write_text(fixture);(d/'tb.sv').write_text(TB.replace('PARAM',str(max_sos)))
 run([str(tool/'bin/iverilog.exe'),'-g2012','-Wall','-s','tb','-o','test.vvp',str(RTL),'tb.sv'],d,'compile.log')
 run([str(tool/'bin/vvp.exe'),'test.vvp'],d,'run.log')
 negatives=[]
 for field,label in [(11,'data'),(10,'valid_count'),(8,'ready'),(12,'clip_flag'),(14,'config_error'),(11,'order')]:
  altered=rows.copy();idx=next(i for i,r in enumerate(rows) if i>20 and r.split()[10]=='1');cells=altered[idx].split()
  if label=='data':cells[field]=f'{int(cells[field],16)^1:x}'
  elif label=='order':cells[field]=next(r.split()[11] for r in rows[idx+1:] if r.split()[10]=='1' and r.split()[11]!=cells[field])
  else:cells[field]=str(1-int(cells[field]))
  altered[idx]=' '.join(cells);(d/'vectors.txt').write_text('\n'.join(altered)+'\n')
  run([str(tool/'bin/vvp.exe'),'test.vvp'],d,'negative_'+label+'.log',expect=1);negatives.append(label)
 (d/'vectors.txt').write_text(fixture)
 assert stats['retain'] and stats['config_errors'] and stats['sections_seen']==list(range(1,max_sos+1)),stats
 reports.append({'max_sos':max_sos,'cycles':len(rows),'stats':stats,'negative_tests':negatives})
for invalid in [0,5]:
 d=OUT/f'illegal_{invalid}';d.mkdir()
 (d/'tb.sv').write_text(f'module tb; biquad_sos_stream #(.MAX_SOS({invalid})) dut(); initial #1 $finish; endmodule')
 run([str(tool/'bin/iverilog.exe'),'-g2012','-s','tb','-o','test.vvp',str(RTL),'tb.sv'],d,'compile.log')
 run([str(tool/'bin/vvp.exe'),'test.vvp'],d,'run.log',expect=1)
summary={'status':'PASS','rtl_sha256':hashlib.sha256(RTL.read_bytes()).hexdigest(),'configurations':reports,
 'cycle_contract':'latency and II=7*active_SOS+1; II1 remains unqualified','scope':'RTL simulation only'}
(OUT/'summary.json').write_text(json.dumps(summary,indent=2));print(OUT);print(json.dumps(summary,indent=2))
