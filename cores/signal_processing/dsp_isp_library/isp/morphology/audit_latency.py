"""Audit all no-stall per-frame latencies from a completed simulation run."""
import argparse,datetime,json,pathlib,re
p=argparse.ArgumentParser();p.add_argument('evidence',type=pathlib.Path);a=p.parse_args()
rows=[]
for log in sorted(a.evidence.glob('w*/run.log')):
 w,h,k,d,pad=map(int,re.fullmatch(r'w(\d+)_h(\d+)_k(\d+)_d(\d+)_pad(\d+)',log.parent.name).groups())
 one=w*(1+min(k//2,h-1))+(k-1)*(w+k-1)+k-1+5
 seen=0
 for f,cycle in re.findall(r'LATENCY epoch=0 frame=(\d+) cycles=(\d+)',log.read_text()):
  op=int(f)//8;expect=one*(1 if op<2 else 2)
  assert int(cycle)==expect,(log,int(f),int(cycle),expect)
  rows.append(dict(case=log.parent.name,frame=int(f),op=op,cycles=expect));seen+=1
 assert seen==32,(log,seen)
assert len(rows)==384,len(rows)
out=a.evidence.parent/('latency_audit_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'.json')
out.write_text(json.dumps(dict(status='PASS',simulation=str(a.evidence),checked_frames=len(rows),frames=rows),indent=2))
print('PASS exact latency',len(rows),'frames;',out)
