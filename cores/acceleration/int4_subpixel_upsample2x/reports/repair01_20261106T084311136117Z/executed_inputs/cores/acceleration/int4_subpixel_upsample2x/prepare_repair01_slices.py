"""Literal record slicing, not an oracle; never recompute any expected value."""
from pathlib import Path
import hashlib,json,sys
def sha(b):return hashlib.sha256(b).hexdigest()
def split(source,destination):
 raw=Path(source).read_bytes()
 assert sha(raw)=='609ebdca8ee028b4f0d0bcd395bd17f1eb500721cdad9ba9afe34f6fbb530e82'
 lines=raw.splitlines(keepends=True);assert lines[0]==b'26\n'
 records=[];i=1;offset=len(lines[0])
 for number in range(26):
  fields=list(map(int,lines[i].split()));assert len(fields)==11
  w,h,ci,co,zero,tag,error,nin,nout,ncfg,reset=fields
  end=i+1+ncfg+nin+nout;assert end<=len(lines)
  expected=[list(map(int,row.split())) for row in lines[i+1+ncfg+nin:end]]
  assert all(len(row)==9 for row in expected)
  payload=b''.join(lines[i:end])
  counts=dict(frames=1,inputs=nin,outputs=nout,configs=ncfg,
              clips=sum(row[1] for row in expected),inexact=sum(row[2] for row in expected))
  records.append(dict(index=number,offset=offset,bytes=len(payload),sha256=sha(payload),fields=fields,counts=counts,payload=payload))
  offset+=len(payload);i=end
 assert i==len(lines) and offset==len(raw)
 assert b''.join(x['payload'] for x in records)==raw[len(lines[0]):]
 # Both cuts start with a full CLEAR; the successor of removed17 also clears.
 for n in [0,17,18]:
  block=records[n]['payload'].splitlines();assert records[n]['fields'][9]>0 and int(block[1].split()[0])==2
  if n in [17,18]:
   ci,co=records[n]['fields'][2:4];ncfg=records[n]['fields'][9]
   successful=[row.split() for row in block[1:1+ncfg] if int(row.split()[-1])==0]
   words={(int(row[1]),int(row[2])) for row in successful if int(row[0])==0}
   metadata={int(row[1]) for row in successful if int(row[0])==1}
   assert words=={(r,w) for r in range(4*co) for w in range((ci+7)//8)}
   assert metadata==set(range(4*co))
 assert records[17]['fields'][:4]==[1024,1,1,16]
 assert records[16]['fields'][:4]==[1,1,64,16]
 out=Path(destination);parts=[]
 for label,indices in [('remaining25',[n for n in range(26) if n!=17]),('fullrow',[17])]:
  payload=b''.join(records[n]['payload'] for n in indices)
  data=(str(len(indices))+'\n').encode()+payload;path=out/(label+'.txt');path.write_bytes(data)
  counts={k:sum(records[n]['counts'][k] for n in indices) for k in records[0]['counts']}
  parts.append(dict(label=label,indices=indices,vector=path.name,vector_sha256=sha(data),vector_bytes=len(data),counts=counts))
 combined={k:sum(p['counts'][k] for p in parts) for k in parts[0]['counts']}
 assert (combined['frames'],combined['inputs'],combined['outputs'],combined['configs'])==(26,3693,67678,3173)
 summary=dict(source=Path(source).as_posix(),source_sha256=sha(raw),oracle_calls=0,
  records=[{k:v for k,v in record.items() if k!='payload'} for record in records],parts=parts,combined=combined,
  proof='Each raw complete frame payload is byte identical; per-index reassembly exactly equals original payload. Only file-leading frame counts differ.',
  reset_boundary_proof='Frame0 starts CLEAR; fullrow17 starts CLEAR and writes every used word/row; frame18 starts CLEAR and writes every used word/row. Frame5->6 resident reuse stays together.')
 (out/'slice_summary.json').write_bytes((json.dumps(summary,indent=2)+'\n').encode())
 print('PASS literal_subpixel_slices '+json.dumps(combined,sort_keys=True))
if __name__=='__main__':
 assert len(sys.argv)==3;split(sys.argv[1],sys.argv[2])
