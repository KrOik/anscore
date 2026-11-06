"""New independent dictionary oracle. Invoked only by archived preparation child."""
import random

MASK64=(1<<64)-1

class Model:
 def __init__(self,feeds):self.feeds=feeds;self.reset()
 def reset(self):self.heads={};self.previous={};self.watermarks={};self.closed=set();self.fault=False
 def apply(self,command):
  op,feed,time,sequence,data,tag=command
  r=dict(op=op,status=0,feed=0,blocked_feed=0,time=0,sequence=0,data=0,tag=tag,head=0,closed=0,has_previous=0,has_watermark=0,previous_time=0,previous_sequence=0,watermark=0)
  if op>6:r['status']=1
  elif op==5:self.reset()
  elif op==6:self.fault=True
  elif self.fault:r['status']=11
  elif op==3:
   if not self.heads:r['status']=9
   else:
    winner=min(self.heads,key=lambda f:(self.heads[f][0],f));t,s,payload=self.heads[winner]
    blockers=[f for f in range(self.feeds) if f not in self.heads and f not in self.closed and (f not in self.watermarks or self.watermarks[f]<=t)]
    if blockers:r.update(status=10,blocked_feed=min(blockers),time=t)
    else:
     del self.heads[winner];r.update(feed=winner,time=t,sequence=s,data=payload,closed=int(winner in self.closed))
  elif feed>=self.feeds:r['status']=2
  else:
   r.update(feed=feed,head=int(feed in self.heads),closed=int(feed in self.closed))
   if op==2:self.closed.add(feed);r['closed']=1
   elif op!=4 and feed in self.closed:r['status']=3
   elif op==0 and feed in self.heads:r['status']=4
   elif op==4:
    r['has_previous']=int(feed in self.previous);r['has_watermark']=int(feed in self.watermarks)
    if feed in self.previous:r['previous_time'],r['previous_sequence']=self.previous[feed]
    r['watermark']=self.watermarks.get(feed,0)
   elif op==0:
    if feed in self.previous and sequence<=self.previous[feed][1]:r['status']=5
    elif feed in self.previous and time<self.previous[feed][0]:r['status']=6
    elif feed in self.watermarks and time<self.watermarks[feed]:r['status']=7
    else:self.previous[feed]=(time,sequence);self.heads[feed]=(time,sequence,data);r['head']=1
   elif feed in self.watermarks and time<self.watermarks[feed]:r['status']=8
   else:self.watermarks[feed]=time
  r.update(heads=len(self.heads),end=int(len(self.closed)==self.feeds and not self.heads),fault=int(self.fault))
  return r
 def snapshot(self):
  rows=[]
  for f in range(self.feeds):
   p=self.previous.get(f,(0,0));h=self.heads.get(f,(0,0,0))
   rows.append([int(f in self.heads),int(f in self.closed),int(f in self.previous),int(f in self.watermarks),*p,self.watermarks.get(f,0),*h])
  return rows

def pack(result,data_w,tag_w):
 fields=[('op',4),('status',4),('feed',32),('blocked_feed',32),('time',64),('sequence',64),('data',data_w),('tag',tag_w),('head',1),('closed',1),('has_previous',1),('has_watermark',1),('previous_time',64),('previous_sequence',64),('watermark',64),('heads',32),('end',1),('fault',1)]
 v=0
 for key,width in fields:
  assert 0<=result[key]<(1<<width);v=(v<<width)|result[key]
 return v

def records(feeds,data_w,tag_w):
 """Fixed directed and seeded stimulus. No HDL sampling or source imports."""
 rng=random.Random(0xB4300+feeds*31+data_w);items=[];tag=0;mask=(1<<data_w)-1
 def add(op,feed=0,time=0,seq=0,data=0):
  nonlocal tag
  tag=(tag+1)&((1<<tag_w)-1);items.append((0,(op,feed,time,seq,data&mask,tag)))
 def query_all():
  for f in range(feeds):add(4,f)
 query_all();add(3)
 for f in range(feeds):add(0,f,0,0,mask^f)
 add(0,0,0,0,mask);add(3);query_all()
 for f in range(feeds):add(1,f,1)
 for f in range(feeds):add(3)
 add(3);add(0,0,0,0);add(0,0,8,1,mask)
 for f in range(1,feeds):add(0,f,8,1,f)
 for f in range(feeds):add(1,f,9)
 for f in range(feeds):add(3)
 add(0,0,7,2);add(0,0,8,2);add(1,0,8);add(0,0,9,2,mask);query_all()
 add(5)
 for f in range(feeds):add(0,f,MASK64,MASK64,mask^f)
 add(0,0,MASK64,MASK64,mask);add(3)
 for f in range(feeds):add(1,f,MASK64)
 for f in range(feeds):add(2,f)
 for f in range(feeds):add(3)
 add(3);query_all();add(0,0,MASK64,MASK64);add(1,0,MASK64);add(2,0)
 add(6);add(4,0);add(3);add(0,0xffffffff);add(15,0xffffffff);add(5)
 for round_number in range(16):
  add(5);t=round_number*17
  for f in range(feeds):add(0,f,t,0,rng.getrandbits(data_w));add(4,f)
  for f in range(feeds):add(1,f,t+1)
  for f in range(feeds):add(3);add(4,f)
  for f in range(feeds):add(0,f,t+1,1,rng.getrandbits(data_w))
  add(0,0,t+2,2);add(1,0,t);add(4,0);add(3)
  for f in range(feeds):add(2,f)
  for f in range(feeds):add(3)
  add(3);query_all()
 for j in range(160):
  if j%16==0:add(5)
  op=rng.choice([0,0,0,1,1,2,3,3,4,4,6,7])
  f=rng.choice(list(range(feeds))+[feeds,1<<31,0xffffffff]);t=rng.choice([0,1,MASK64,1<<63,rng.getrandbits(64)])
  seq=rng.choice([0,1,MASK64,1<<63,rng.getrandbits(64)])
  add(op,f,t,seq,rng.getrandbits(data_w));add(4,j%feeds)
 # Each canceled transaction has a separately specified reachable live phase.
 for phase in range(1,6):
  add(5)
  if phase==4:
   add(0,0,9,10,mask)
   for f in range(feeds):add(2,f)
   canceled=(3,0xffffffff,MASK64,MASK64,mask,0)
  elif phase==5:canceled=(4,0,0,0,0,0)
  else:canceled=(0,0,9,10,mask,0)
  items.append((phase,canceled));query_all();add(3)
 add(5);query_all()
 return items
