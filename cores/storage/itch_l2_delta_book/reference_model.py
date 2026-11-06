"""SPDX-License-Identifier: Apache-2.0. Independent price dictionaries and extrema."""
import random
QMAX=(1<<32)-1;AMAX=(1<<38)-1;PMAX=(1<<32)-1
def pack(values,widths):
 result=0
 for value,width in zip(values,widths):
  assert 0<=value<(1<<width),(value,width)
  result=(result<<width)|value
 return result
class Book:
 def __init__(self,n,t):self.n=n;self.t=t;self.levels={};self.faulted=0
 def best(self,side):
  prices=[p for s,p in self.levels if s==side]
  if not prices:return (0,0,0)
  price=min(prices)if side else max(prices)
  return (1,price,self.levels[side,price])
 def apply(self,op,rv,rs,rp,rq,av,ass,ap,aq,seq,tag):
  old=dict(self.levels);before=[self.best(s)for s in [0,1]];status=0;found=quantity=0;leg=[0]*4
  if op==3:self.levels.clear();self.faulted=0
  elif op==4:self.faulted=1
  elif op>4:status=7
  elif self.faulted:status=6
  elif op==1:
   if(rs,rp)in self.levels:found=1;quantity=self.levels[rs,rp]
   else:status=1
  elif op==0:
   target=dict(self.levels)
   if(not rv and not av)or(rv and rq==0)or(av and aq==0):status=2
   elif rv and(rs,rp)not in target:status=1
   elif rv and target[rs,rp]<rq:status=3
   else:
    if rv:
     target[rs,rp]-=rq
     if target[rs,rp]==0:del target[rs,rp]
    if av:
     target[ass,ap]=target.get((ass,ap),0)+aq
     if target[ass,ap]>AMAX:status=5
    if not status and len(target)>self.n:status=4
    if not status:
     self.levels=target
     leg=[old.get((rs,rp),0),target.get((rs,rp),0),old.get((ass,ap),0),target.get((ass,ap),0)]
     if not rv:leg[:2]=[0,0]
     if not av:leg[2:]=[0,0]
   if status:self.faulted=1
  after=[self.best(s)for s in [0,1]]
  changed=[int(before[s]!=after[s])if status==0 and op in [0,3]else 0 for s in [0,1]]
  counts=[sum(s==side for s,p in self.levels)for side in [0,1]]
  crossed=int(after[0][0]and after[1][0]and after[0][1]>=after[1][1])
  values=[op,status,seq,tag,found,quantity]+leg+list(after[0])+list(after[1])+changed+counts+[crossed,self.faulted]
  widths=[3,4,64,self.t,1,38]+[38]*4+[1,32,38]*2+[1,1,32,32,1,1]
  return pack(values,widths),status
def vectors(n,t):
 model=Book(n,t);lines=[];serial=0;rng=random.Random(370000+n);counts=dict(commands=0,statuses={},live_resets=0)
 def emit(op=0,rv=0,rs=0,rp=0,rq=0,av=0,ass=0,ap=0,aq=0):
  nonlocal serial
  seq=(1<<63)+serial;tag=((1<<(t-1))|serial)%(1<<t);serial+=1
  expected,status=model.apply(op,rv,rs,rp,rq,av,ass,ap,aq,seq,tag)
  lines.append(f'0 {op} {rv} {rs} {rp} {rq} {av} {ass} {ap} {aq} {seq} {tag}\n')
  lines.append(f'{expected} {len(model.levels)}\n')
  lines.extend(f'{s} {p} {q}\n'for(s,p),q in sorted(model.levels.items()))
  counts['commands']+=1;counts['statuses'][str(status)]=counts['statuses'].get(str(status),0)+1
 def add(p=0,q=1,s=0):emit(av=1,ass=s,ap=p,aq=q)
 def cut(p=0,q=1,s=0):emit(rv=1,rs=s,rp=p,rq=q)
 def pair(rp,rq,ap,aq,rs=0,ass=0):emit(rv=1,rs=rs,rp=rp,rq=rq,av=1,ass=ass,ap=ap,aq=aq)
 def clear():emit(3)
 def get(p=0,s=0):emit(1,rs=s,rp=p)
 emit(2);get();emit(5);emit(7);clear()
 add(123,10);pair(123,3,123,9);get(123);cut(123,16);emit(2)
 # Removal must be legal before a same-key add, regardless of net amount.
 add(0,2);pair(0,3,0,QMAX);get();add();clear()
 pair(0,1,0,QMAX);clear();emit();clear();add(q=0);clear();cut(q=0);clear()
 # Full total capacity can be entirely bid or entirely ask, including endpoints.
 for side in [0,1]:
  for price in range(n):add(price,1,side)
  pair(0,1,PMAX,QMAX,side,side);get(PMAX,side);emit(2)
  pair(PMAX,1,1<<31,1,side,side);get(PMAX,side);clear()
 # All unsigned32 constituent shares fit the 64-order bound; the 65th overflows.
 for _ in range(64):add(PMAX,QMAX)
 get(PMAX);add(PMAX,QMAX);emit(2);clear()
 for price in [0,1<<31,PMAX]:
  add(price,QMAX);get(price);pair(price,QMAX,price,1);cut(price);emit(2)
 # Delete/reduce the best and retain crossed/locked sides without matching.
 if n>=2:
  add(100,5);add(90,7);cut(100,2);cut(100,3);get(90)
  pair(90,7,80,9,0,1);add(80,3,0);emit(2);cut(80,3,0);clear()
  add(1,9);add(2,8,1);pair(1,2,2,3,0,1);emit(2);clear()
 add(0,1);emit(4);add();get();emit(2);clear()
 for _ in range(80):
  if model.faulted:emit(2);clear();continue
  if not model.levels or(rng.randrange(4)==0 and len(model.levels)<n):add(rng.getrandbits(32),rng.choice([1,3,QMAX]),rng.randrange(2))
  else:
   s,p=rng.choice(list(model.levels));q=model.levels[s,p];kind=rng.randrange(4)
   if kind==0:get(p,s)
   elif kind==1:cut(p,rng.choice([1,min(q,QMAX)]),s)
   else:pair(p,min(q,QMAX),rng.choice([p,rng.getrandbits(32)]),rng.choice([1,QMAX]),s,rng.randrange(2))
 clear()
 for phase in range(4):
  clear()
  if phase==1:
   add(10,5)
   args=(0,1,0,10,2,1,0,20 if n>=2 else 10,3)
  elif phase==3:args=(0,0,0,0,0,1,0,0,0)
  else:args=(0,0,0,0,0,1,0,0,3)
  lines.append('1 '+str(phase)+' '+' '.join(map(str,args))+f' {(1<<64)-1} {(1<<t)-1}\n')
  counts['live_resets']+=1;model=Book(n,t)
  get();emit(2);add(PMAX,9,1);get(PMAX,1);cut(PMAX,9,1)
 return ''.join(lines),counts
