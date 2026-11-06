"""Isolated archived numerical preparation entry point; no HDL or old imports."""
import argparse,hashlib,json
from pathlib import Path
from reference_model import Model,records,pack

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--profile',required=True);parser.add_argument('--output',required=True);a=parser.parse_args()
 feeds,data_w,tag_w=map(int,a.profile.split(','));model=Model(feeds);items=records(feeds,data_w,tag_w);lines=[];statuses={};commands=0;resets=0;preoffers=0;previous_normal=False;future_gets=0
 for phase,command in items:
  if phase:
   lines.append('1 '+str(phase)+' '+' '.join(map(str,command)));model.reset();resets+=1;previous_normal=False
  else:
   lines.append('0 '+' '.join(map(str,command)));result=model.apply(command);lines.append(str(pack(result,data_w,tag_w)))
   lines.extend(' '.join(map(str,row)) for row in model.snapshot());commands+=1;statuses[str(result['status'])]=statuses.get(str(result['status']),0)+1
   if previous_normal:preoffers+=1;future_gets+=int(command[0]==4)
   previous_normal=True
 raw=('\n'.join(lines)+'\n').encode();path=Path(a.output);path.write_bytes(raw)
 summary=dict(profile=[feeds,data_w,tag_w],counts=dict(commands=commands,live_resets=resets,expected_preoffers=preoffers,future_gets=future_gets,statuses=statuses),vector_sha256=hashlib.sha256(raw).hexdigest(),vector_bytes=len(raw))
 path.with_suffix('.summary.json').write_bytes((json.dumps(summary,indent=2)+'\n').encode());print('PASS watermark_event_vectors '+json.dumps(summary['counts'],sort_keys=True))
if __name__=='__main__':main()
