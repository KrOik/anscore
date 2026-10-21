"""Independent AXI4 byte-address oracle, derived from transfer-address equations.

No owner RTL/validation imports. Policy rejects exclusive transactions and requires
one uniform target window for all actually transferred byte addresses.
"""
from dataclasses import dataclass, asdict

@dataclass(frozen=True)
class Beat:
 address:int
 byte_addresses:tuple
 lanes:tuple
 last:bool

@dataclass(frozen=True)
class Verdict:
 accepted:bool
 response:str
 reason:str
 target:int|None
 beats:tuple
 beat_count:int
 captured_id:int

def transaction(address,length,size,burst,*,data_bits=32,addr_bits=32,
                targets=2,region_bits=12,lock=0,ident=0):
 """LEN is beats minus one; SIZE is log2(bytes); burst 0/1/2=FIXED/INCR/WRAP."""
 def reject(reason):return Verdict(False,'DECERR',reason,None,(),max(0,length+1),ident)
 if data_bits not in (32,64):return reject('unsupported data width')
 if not 0<=length<=255:return reject('LEN outside 8-bit range')
 if not 0<=size<=(data_bits//8).bit_length()-1:return reject('SIZE exceeds data bus')
 if burst not in (0,1,2):return reject('reserved BURST')
 if lock:return reject('exclusive unsupported by crossbar policy')
 if not 0<=address<1<<addr_bits:return reject('address outside bus')
 n=length+1;step=1<<size;bus=data_bits//8
 if burst==0 and n>16:return reject('FIXED exceeds AXI4 16-beat limit')
 if burst==2 and (n not in (2,4,8,16) or address%step):return reject('WRAP length/alignment')
 aligned=address-address%step;wrap_bytes=step*n;wrap_base=address-address%wrap_bytes
 beats=[]
 for index in range(n):
  if burst==0:a=address
  elif burst==1:a=address if index==0 else aligned+index*step
  else:a=wrap_base+(address-wrap_base+index*step)%wrap_bytes
  # For an unaligned first transfer only bytes above start up to its aligned
  # transfer boundary are valid. Subsequent INCR beats use aligned addresses.
  end=(a//step)*step+step
  byte_addresses=tuple(range(a,end))
  if not byte_addresses or byte_addresses[-1]>=1<<addr_bits:return reject('address overflow')
  beats.append(Beat(a,byte_addresses,tuple(x%bus for x in byte_addresses),index==n-1))
 byte_set=[x for b in beats for x in b.byte_addresses]
 if any(x//4096!=address//4096 for x in byte_set):return reject('4KiB boundary')
 decoded={x//(1<<region_bits) for x in byte_set}
 if len(decoded)!=1:return reject('window crossing')
 target=decoded.pop()
 if target>=targets:return reject('unmapped target window')
 return Verdict(True,'OKAY','',target,tuple(beats),n,ident)

def write_completion(verdict,received_last,downstream_id=None,downstream_response='OKAY'):
 """One upstream response after LEN+1 W transfers; LAST reconstructed by LEN."""
 expected=[False]*(verdict.beat_count-1)+[True]
 malformed=list(received_last)!=expected
 mismatch=downstream_id is not None and downstream_id!=verdict.captured_id
 response='DECERR' if not verdict.accepted else ('SLVERR' if malformed and downstream_response in ('OKAY','EXOKAY') else downstream_response)
 return dict(response=response,
             returned_id=verdict.captured_id,last_error=malformed,id_error=mismatch)

def read_beat(verdict,index,downstream_id,downstream_last):
 expected_last=index==verdict.beat_count-1
 return dict(returned_id=verdict.captured_id,last=expected_last,
             id_error=downstream_id!=verdict.captured_id,last_error=bool(downstream_last)!=expected_last)

import random,json,hashlib
from pathlib import Path
HERE=Path(__file__).resolve().parent

def self_test():
 rows=[]
 def check(label,args,accept,addresses=None,reason=None,**kw):
  v=transaction(*args,**kw);assert v.accepted==accept,(label,v)
  if addresses is not None:assert [b.address for b in v.beats]==addresses,(label,v)
  if reason:assert reason in v.reason,(label,v)
  rows.append(dict(label=label,args=args,options=kw,accepted=v.accepted,reason=v.reason))
 check('unaligned_single_at_page_end',(4095,0,2,1),True,[4095])
 check('unaligned_next_page',(4095,1,2,1),False,reason='4KiB')
 check('fixed_unaligned_page_end_16',(4095,15,2,0),True,[4095]*16)
 check('fixed_17_illegal',(0,16,0,0),False,reason='FIXED')
 check('unaligned_first_increment',(3,2,2,1),True,[3,4,8])
 check('wrap_from_middle',(0x18,3,2,2),True,[0x18,0x1c,0x10,0x14])
 check('wrap_16_64bit',(0x78,15,3,2),True,[0x78]+list(range(0,0x78,8)),data_bits=64)
 check('wrap_len1_illegal',(0,0,2,2),False,reason='WRAP')
 check('wrap_non_power_length',(0,2,2,2),False,reason='WRAP')
 check('wrap_unaligned',(3,3,2,2),False,reason='WRAP')
 check('window_cross_narrow',(255,1,0,1),False,reason='window',region_bits=8)
 check('target1_decode',(256,0,0,1),True,[256],region_bits=8)
 check('unmapped',(512,0,0,1),False,reason='unmapped',region_bits=8)
 check('size_bus_overflow',(0,0,3,1),False,reason='SIZE')
 check('lock_rejected',(0,0,2,1),False,reason='exclusive',lock=1)
 check('reserved_burst',(0,0,2,3),False,reason='reserved')
 check('address_overflow',(0xffffffff,1,2,1),False,reason='overflow',region_bits=28,targets=16)
 check('max256_incr',(0,255,2,1),True,list(range(0,1024,4)))
 v=transaction(3,2,2,1,ident=7);assert v.beats[0].byte_addresses==(3,) and v.beats[0].lanes==(3,)
 assert v.beats[1].byte_addresses==(4,5,6,7) and v.beats[1].lanes==(0,1,2,3)
 assert write_completion(v,[False,True,False],downstream_id=0)['response']=='SLVERR'
 assert write_completion(v,[False,True,False],downstream_response='DECERR')['response']=='DECERR'
 assert write_completion(v,[False,False,True],downstream_id=0)['id_error']
 assert read_beat(v,2,0,False)==dict(returned_id=7,last=True,id_error=True,last_error=True)
 invalid=transaction(0,3,2,3,ident=5);assert invalid.beat_count==4
 assert write_completion(invalid,[False,False,False,True])['response']=='DECERR'
 rng=random.Random(0xa41c);accepted=0
 for i in range(12000):
  dw=rng.choice([32,64]);size=rng.randrange((dw//8).bit_length());burst=rng.randrange(3)
  n=rng.choice([1,2,4,8,16,17,256]);a=rng.randrange(0,8192);region=rng.choice([8,12,16])
  v=transaction(a,n-1,size,burst,data_bits=dw,region_bits=region,targets=4)
  if not v.accepted:continue
  accepted+=1;assert len(v.beats)==n and sum(b.last for b in v.beats)==1 and v.beats[-1].last
  assert all(0<=lane<dw//8 for b in v.beats for lane in b.lanes)
  assert all(x//4096==a//4096 and x//(1<<region)==v.target for b in v.beats for x in b.byte_addresses)
  if burst==0:assert all(b==v.beats[0] or b.address==a for b in v.beats)
  if burst==2:assert len({b.address for b in v.beats})==n
 (HERE/'oracle_selftest.json').write_text(json.dumps(dict(status='PASS',oracle_sha256=hashlib.sha256((HERE/'address_oracle.py').read_bytes()).hexdigest(),directed=rows,random_cases=12000,random_accepted=accepted,scope='Software transaction-address oracle self-test only; RTL peer and board tests pending.'),indent=2)+'\n', encoding="utf-8")
 print('PASS independent oracle',len(rows),'directed, 12000 random, accepted',accepted)
if __name__=='__main__':
 import argparse
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--self-test',action='store_true');args=parser.parse_args()
 if args.self_test:self_test()
 else:parser.print_help()
