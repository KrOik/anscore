"""Independent cycle oracle for configurable-depth elastic statistics candidate."""
import argparse,datetime,hashlib,itertools,json,os,random,shutil,subprocess,sys
from pathlib import Path
H=Path(__file__).resolve().parent;BASE=H.parents[1];LIB=BASE.parents[1];ROOT=LIB.parents[1]
sys.path.insert(0,str(BASE/'models'))
from reference import Config,IntegerModel,pack
sys.path.insert(0,str(LIB/'dsp/dc/models'))
from dc_reference import Config as DCConfig,FixedReference

def main():
 p=argparse.ArgumentParser();p.add_argument('--source',type=Path,default=H/'statistics_stream.sv');p.add_argument('--latency',type=int,default=5);p.add_argument('--vector-json',type=Path);a=p.parse_args()
 out=H/'evidence'/datetime.datetime.now().strftime('sim_%Y%m%d_%H%M%S_%f');out.mkdir(parents=True)
 rng=random.Random(6502416);rows=[];slots=[None]*a.latency;model=IntegerModel();pending=source=None;done=error=0
 configs=list(itertools.product([0,1],range(7),[-8,-1,0,1,8,15]))+[(0,7,0),(1,0,-9)]
 seen=set();accepted=transfers=acks=illegal=resets=live_resets=cfg_wait=0;replay=[]
 if a.vector_json:
  obj=json.loads(a.vector_json.read_text());c=obj['config'];dc=FixedReference(DCConfig(('blocker','mean','baseline')[c&3],(c>>2)&65535,(c>>18)&15))
  replay=[dc.step(x)[0] for x in obj['words']];replay_cfg=(0,(c>>22)&15,0,0x10000000);shutil.copy2(a.vector_json,out/'original_host_input.json')
 for cycle in range(1500 if replay else 40000):
  rst=int(cycle not in (0,1) if replay else cycle%2903 not in (0,1))
  mr=1 if replay else int(cycle%401<150 or (cycle%401>=241 and rng.random()<.7))
  if replay:
   if cycle==7:pending=replay_cfg
   if cycle>=10 and source is None and accepted<len(replay):source=replay[accepted]
  else:
   if cycle%431==7 and pending is None:
    b,l,s=configs[(cycle//431)%len(configs)];pending=(b,l,s,[0,49,0x10000000,0xffffffff][cycle//431%4])
   if source is None and (cycle%401<150 or rng.random()<.7):source=rng.choice([-32768,32767,0,7,-7,10000,rng.randrange(-32768,32768)])
  cv=int(pending is not None);b,l,s,t=pending or (0,0,0,0);sv=int(source is not None);sd=source or 0
  ready=[False]*len(slots)
  for i in reversed(range(len(slots))):ready[i]=slots[i] is None or (mr if i==len(slots)-1 else ready[i+1])
  sr=int(rst and not cv and ready[0]);cr=int(rst and all(x is None for x in slots));v=int(slots[-1] is not None);data,user=slots[-1] or (0,0)
  rows.append(f'{rst} {cv} {b} {l} {s&31:x} {t:x} {sv} {sd&65535:x} {mr} {sr} {cr} {v} {data:032x} {user:x} {done} {error}')
  done=error=0
  if not rst:
   live_resets+=int(any(x is not None for x in slots));resets+=1;model=IntegerModel();slots=[None]*a.latency;continue
  transfers+=int(v and mr);cfg_wait+=int(cv and not cr)
  nxt=[None if i==0 else slots[i-1] for i in range(len(slots))]
  slots=[nxt[i] if ready[i] else slots[i] for i in range(len(slots))]
  if cv and cr:
   done=1;acks+=1;pending=None
   if l>6 or s < -8:error=1;illegal+=1
   else:model= IntegerModel(Config(bool(b),l,s,t));seen.add((b,l,s))
  if sv and sr:slots[0]=pack(model.step(sd));source=None;accepted+=1
 fixture='\n'.join(rows)+'\n';(out/'vectors.txt').write_text(fixture)
 # Reuse the existing strict per-cycle scoreboard, without changing golden data.
 old=(BASE/'tests/test_rtl.py').read_text();tb=old.split("tb=r'''",1)[1].split("'''",1)[0]
 (out/'tb.sv').write_text(tb)
 for source_path in (a.source,H/'test_candidate.py',BASE/'models/reference.py',LIB/'dsp/dc/models/dc_reference.py'):shutil.copy2(source_path,out/source_path.name)
 tool=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy();env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
 def run(cmd,name,negative=False):
  r=subprocess.run(cmd,cwd=out,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(out/name).write_text(r.stdout)
  if bool(r.returncode)==bool(not negative):raise AssertionError(name+' '+r.stdout)
 run([str(tool/'bin/iverilog.exe'),'-g2012','-Wall','-s','tb','-o','test.vvp',a.source.name,'tb.sv'],'compile.log')
 run([str(tool/'bin/vvp.exe'),'test.vvp'],'run.log')
 mutations=[]
 for field,label in [(12,'rms'),(12,'data'),(11,'valid'),(9,'ready'),(13,'flags'),(14,'configuration')]:
  altered=rows.copy();idx=next(i for i,r in enumerate(rows) if i>20 and r.split()[11]=='1');cells=altered[idx].split()
  if field==12:cells[field]=f'{int(cells[field],16)^(1<<32 if label=="rms" else 1):032x}'
  else:cells[field]=str(1-int(cells[field]))
  altered[idx]=' '.join(cells);(out/'vectors.txt').write_text('\n'.join(altered)+'\n')
  run([str(tool/'bin/vvp.exe'),'test.vvp'],'negative_'+label+'.log',True);mutations.append(label)
 (out/'vectors.txt').write_text(fixture)
 if replay:assert accepted==transfers==len(replay)
 else:assert len(seen)==84 and live_resets>0 and cfg_wait>0 and illegal>0
 (out/'summary.json').write_text(json.dumps(dict(status='PASS',source_sha256=hashlib.sha256(a.source.read_bytes()).hexdigest(),latency=a.latency,cycles=len(rows),accepted=accepted,outputs=transfers,legal_configs=len(seen),cfg_acks=acks,illegal=illegal,reset_edges=resets,live_resets=live_resets,cfg_wait=cfg_wait,mutations=mutations),indent=2))
 print('STATS PASS',out,flush=True)

if __name__=='__main__':main()
