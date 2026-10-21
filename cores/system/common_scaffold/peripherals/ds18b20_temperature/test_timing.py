"""Independent realtime conversion deadline and legal presence endpoints."""
import json
from test_temperature import run,hashes,HERE

def main():
 frozen=hashes(); rows=[]
 for hz in [1000000,27000000,250000000]:
  for ready in [153.75,154.25]:
   rows.append(run('physical_ready_%d_%s'%(hz,str(ready).replace('.','p')),hz=hz,timeout=154,ready_us=ready,error=0 if ready<154 else 4))
  for deadline in [153,154,155,156]:
   rows.append(run('deadline_%d_%d'%(hz,deadline),hz=hz,timeout=deadline,error=4 if deadline<154 else 0))
 for delay in [15,60]:rows.append(run('presence_endpoint_'+str(delay),presence_delay=delay,presence_width=60))
 rows.append(run('second_no_presence',nopresence=2,error=3,match=True))
 rows.append(run('second_stuck',second_stuck=True,error=2))
 assert hashes()==frozen
 (HERE/'timing_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
