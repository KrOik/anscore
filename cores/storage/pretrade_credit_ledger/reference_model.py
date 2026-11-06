"""SPDX-License-Identifier: Apache-2.0. Independent unbounded-integer ledger."""
import random
MAX=(1<<64)-1

def pack(values,widths):
 result=0
 for value,width in zip(values,widths):
  assert 0<=value<(1<<width),(value,width)
  result=(result<<width)|value
 return result

class Ledger:
 def __init__(self,a,k,t):self.a=a;self.k=k;self.t=t;self.accounts={};self.tickets={};self.faulted=0
 def apply(self,op,account,ticket,amount,limit,tag):
  status=0;ra=rt=rm=rl=ru=rf=0
  if op==5:self.accounts.clear();self.tickets.clear();self.faulted=0
  elif op==6:self.faulted=1
  elif op>6:status=10
  elif self.faulted:status=9
  elif op in [2,4]:
   if ticket not in self.tickets:status=7
   else:
    ra,rm=self.tickets[ticket];rt=ticket;rl,ru=self.accounts[ra]
    if op==2:
     ru-=rm;self.accounts[ra]=(rl,ru);del self.tickets[ticket]
    rf=rl-ru
  elif account>=self.a:status=1
  elif op==1 and amount==0:status=3
  elif op!=0 and account not in self.accounts:status=2
  elif op==0:
   used=self.accounts.get(account,(0,0))[1]
   if limit<used:status=8
   else:self.accounts[account]=(limit,used);ra=account;rl=limit;ru=used;rf=limit-used
  elif op==3:ra=account;rl,ru=self.accounts[account];rf=rl-ru
  elif op==1:
   cap,used=self.accounts[account]
   if ticket in self.tickets:status=4
   elif used+amount>cap:status=5
   elif len(self.tickets)>=self.k:status=6
   else:
    self.tickets[ticket]=(account,amount);self.accounts[account]=(cap,used+amount)
    ra=account;rt=ticket;rm=amount;rl=cap;ru=used+amount;rf=cap-ru
  assert all(0<=used<=cap<=MAX for cap,used in self.accounts.values())
  for a,(cap,used) in self.accounts.items():assert used==sum(v for aa,v in self.tickets.values() if aa==a)
  payload=pack([op,status,ra,rt,rm,rl,ru,rf,len(self.tickets),tag,self.faulted],
               [3,4,16,64,64,64,64,64,32,self.t,1])
  return payload,status

def vectors(a,k,t):
 model=Ledger(a,k,t);lines=[];serial=0;rng=random.Random(380000+a*100+k)
 counts=dict(commands=0,statuses={},live_resets=0)
 def emit(op=3,account=0,ticket=0,amount=0,limit=0):
  nonlocal serial
  tag=((1<<(t-1))|serial)% (1<<t);serial+=1
  expected,status=model.apply(op,account,ticket,amount,limit,tag)
  lines.append(f'0 {op} {account} {ticket} {amount} {limit} {tag}\n')
  lines.append(f'{expected} {len(model.accounts)} {len(model.tickets)}\n')
  lines.extend(f'{aa} {cap} {used}\n' for aa,(cap,used) in sorted(model.accounts.items()))
  lines.extend(f'{tk} {aa} {am}\n' for tk,(aa,am) in sorted(model.tickets.items()))
  counts['commands']+=1;counts['statuses'][str(status)]=counts['statuses'].get(str(status),0)+1
 def cfg(aa=0,cap=MAX):emit(0,aa,limit=cap)
 def res(tk=0,am=1,aa=0):emit(1,aa,tk,am)
 def rel(tk=0):emit(2,65535,tk,MAX,MAX)
 def get(tk=0):emit(4,65535,tk,MAX,MAX)
 def clear():emit(5,65535,MAX,MAX,MAX)
 emit();get();rel();emit(7,65535);emit(0,32768,limit=MAX);emit(3,65535)
 res(am=0);res(aa=65535,am=0);cfg();res(am=0)
 res(0,MAX);get();emit();res(MAX,1);res(0,1);cfg(cap=MAX-1);cfg();get();rel();rel();emit()
 res(MAX,1<<63);res(1,(1<<63)-1);get(MAX);emit();res(2,1);rel(MAX);rel(1);clear()
 # Full bounded capacity, exact ticket endpoints, duplicate priority and reuse.
 for aa in range(a):cfg(aa)
 keys=[0]+[(1<<63)+i for i in range(1,k)]
 for i,tk in enumerate(keys):res(tk,1,i%a)
 res(keys[-1],1,(a-1));res(MAX,1);res(MAX,MAX);get(keys[k//2])
 rel(keys[k//2]);res(MAX,2);get(MAX);cfg(cap=0);emit();rel(MAX);rel(MAX)
 for tk in keys:get(tk)
 clear();cfg(cap=0);res();cfg(cap=5);res(0,3);cfg(cap=2);cfg(cap=3);cfg(cap=MAX);get();rel();emit()
 # A second account cannot reuse a globally live ticket; public release fields ignored.
 if a>1:
  cfg(1,9);res(MAX,7,1);res(MAX,1,0);get(MAX);rel(MAX);emit(3,1)
 res(123,1);emit(6);get(123);rel(123);cfg();emit(7);emit(6);clear();get(123);emit()
 for aa in range(a):cfg(aa,rng.choice([3,15,MAX]))
 for _ in range(140):
  kind=rng.randrange(9);aa=rng.randrange(a+1)
  tk=rng.choice(list(model.tickets)) if model.tickets and rng.randrange(2)==0 else rng.choice([0,MAX,rng.getrandbits(64)])
  if kind<=2:res(tk,rng.choice([0,1,2,1<<63,MAX]),aa)
  elif kind==3:rel(tk)
  elif kind==4:get(tk)
  elif kind==5:emit(3,aa)
  elif kind==6:cfg(aa,rng.choice([0,1,7,MAX]))
  elif kind==7:emit(7,aa,tk,MAX,MAX)
  else:res(tk,1,0)
 clear()
 # Reset cancels reads, private ticket writes, account writes and held output.
 for phase in range(5):
  cfg(cap=100)
  if phase==0:args=(0,0,0,0,90)
  elif phase==4:res(0,7);args=(2,65535,0,MAX,MAX)
  else:args=(1,0,MAX,7,0)
  lines.append('1 '+str(phase)+' '+' '.join(map(str,args))+f' {(1<<t)-1}\n')
  counts['live_resets']+=1;model=Ledger(a,k,t)
  emit();get(MAX);get(0);cfg(cap=MAX);res(MAX,MAX);get(MAX);rel(MAX);clear()
 counts['expected_preoffers']=counts['commands']-counts['live_resets']-1
 return ''.join(lines),counts
