"""Strict 8x8 external frame protocol with independent composed numerical oracle."""
import sys,struct,random
from pathlib import Path
HERE=Path(__file__).resolve().parent;LIB=HERE.parents[1]
sys.path.insert(0,str(LIB/'isp'));sys.path.insert(0,str(LIB/'isp/morphology'))
from csc_model import bit_exact
from model import morphology

def make_packet(tag,config,words,stall=0):
 if len(words)!=64 or not 0<=stall<=7:raise ValueError('64 pixels/stall required')
 return b'IMG1'+struct.pack('<IIBB',tag,config,64,stall)+struct.pack('<64I',*words)

def oracle(bits,config,words,padding=1):
 if len(words)!=64 or config>>14 or not ((config>>5)&511):raise ValueError('image/config')
 m=(1<<bits)-1;gray=[]
 for word in words:
  rgb=((word>>(2*bits))&m,(word>>bits)&m,word&m)
  gray.append(bit_exact(rgb,bits,'709' if config&1 else '601',bool(config&2),'gray')[0])
 result=morphology([gray[i:i+8] for i in range(0,64,8)],3,(config>>5)&511,(config>>2)&3,bool(config&16),padding)
 return [result[y][x]|((x==7)<<30)|((x==0 and y==0)<<31) for y in range(8) for x in range(8)]

def verify(report,tag,config,words,bits,stall,padding=1):
 if len(report)!=276 or report[:4]!=b'IMR1':raise AssertionError('framing/count')
 rt,rc,n,flags,inc,outc,cycles=struct.unpack('<IIBBBBI',report[4:20])
 if (rt,rc,n,flags,inc,outc)!=(tag,config,64,0,64,64):raise AssertionError('identity/flags/counters')
 if not 64<cycles<16384:raise AssertionError('replay cycle bounds')
 actual=list(struct.unpack('<64I',report[20:]));expected=oracle(bits,config,words,padding)
 if actual!=expected:raise AssertionError(('pixel/sideband',[(i,a,e) for i,(a,e) in enumerate(zip(actual,expected)) if a!=e]))
 return dict(status='PASS',tag=tag,pixels=64,replay_cycles=cycles,cycles_per_pixel=cycles/64,stall=stall)

def cases(bits):
 rng=random.Random(4321+bits);out=[]
 for i in range(16):
  mask=(511,16,186,129)[i%4];op=i%4;standard=(i>>2)&1;limited=(i>>3)&1;binary=int(i in (5,10,15))
  config=(mask<<5)|(binary<<4)|(op<<2)|(limited<<1)|standard
  words=[rng.randrange(1<<(3*bits)) for _ in range(64)]
  for j in range(0,64,7):words[j]=0
  out.append((0xC5000000+bits*256+i,config,words,(0,1,7)[i%3]))
 return out
