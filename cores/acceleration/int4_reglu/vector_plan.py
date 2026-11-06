"""SPDX-License-Identifier: Apache-2.0. Deterministic finite vectors only."""
import random
from reference_model import reglu,prefix
PROFILES=[(1,1,1,0),(3,9,8,0),(32,256,32,0),(4,16,8,1)]
def vectors(h,c,t,ex):
 rng=random.Random(0x38d0+h+c+ex);words=(c+7)//8;weights={};meta={};outmeta={};lines=[]
 counts=dict(configs=0,queries=0,ordinary_outputs=0,error_markers=0,live_resets=0,priority_flows=0)
 def cfg(op,row=0,branch=0,word=0,data=0,bias=0,scale=1,shift=0,zero=0):
  error=0
  if op>=4:error=2
  elif op==2:weights.clear();meta.clear();outmeta.clear()
  elif row>=h:error=1
  elif op==0:
   if word>=words:error=1
   else:weights[row,branch,word]=[(data>>(4*i)&15)-16 if data>>(4*i)&8 else data>>(4*i)&15 for i in range(8)]
  elif op==1:meta[row,branch]=(bias,scale,shift,zero)
  else:outmeta[row]=(scale,shift,zero)
  lines.append(f'0 {op} {row} {branch} {word} {data} {bias} {scale} {shift} {zero} {error}\n');counts['configs']+=1
 def query(n,cols,x=None,xzero=128,pre=0,bad=None):
  tag=(counts['queries']*23+9)%(1<<t);error=0
  if not (1<=n<=h and 1<=cols<=c):error=1
  elif any(j not in outmeta for j in range(n)):error=4
  elif any((j,b) not in meta or any((j,b,w) not in weights for w in range((cols+7)//8)) for j in range(n)for b in [0,1]):error=2
  x=[] if error else (x if x is not None else [rng.randrange(-1024,1024)if ex else rng.randrange(256)for _ in range(cols)])
  marks=[int(i==cols-1)for i in range(len(x))]
  if bad is not None and not error:
   marks[bad]^=1;x=x[:bad+1];marks=marks[:bad+1];error=3
  ic=ii=0;qs=x
  if ex and x:qs,ic,ii=prefix(x,pre)
  outputs=[]
  if error:
   outputs=[(0,0,1,error,0,0,0,0,0,tag,ic,ii)];counts['error_markers']+=1
  else:
   for j in range(n):
    ws=[[v for w in range((cols+7)//8)for v in weights[j,b,w]][:cols]for b in [0,1]]
    y,clip,ine,pc,pi,closed=reglu(qs,128 if ex else xzero,*ws,meta[j,0],meta[j,1],outmeta[j])
    outputs.append((y,j,int(j==n-1),0,clip,ine,pc,pi,closed,tag,ic,ii))
   counts['ordinary_outputs']+=len(outputs)
  lines.append(f'1 {n} {cols} {xzero} {tag} {pre} {len(x)} {len(outputs)}\n')
  lines.extend(f'{v} {last}\n'for v,last in zip(x,marks));lines.extend(' '.join(map(str,o))+'\n'for o in outputs);counts['queries']+=1
 def setup(rows=None,randomized=True):
  for j in range(h if rows is None else rows):
   for b in [0,1]:
    cfg(1,j,b,bias=([2,3][b] if not randomized else [-2**31,2**31-1,-7,7,0,128,-128,255][(2*j+b)%8]),
        scale=1 if not randomized else [0,1,3,65535][(j+b)%4],shift=0 if not randomized else [0,1,8,31][(2*j+b)%4],zero=0 if not randomized else [-1,1,-128,127][(j+2*b)%4])
    for w in range(words):
     data=sum((rng.randrange(16) if randomized else 0)<<(i*4)for i in range(8));cfg(0,j,b,w,data)
   cfg(3,j,scale=1 if not randomized else [0,1,65535,3][j%4],shift=0 if not randomized else [0,1,31,8][j%4],zero=0 if not randomized else [-1,1,127,-128][j%4])
 query(0,1);query(h+1,1);query(1,0);query(1,c+1);query(65535,65535);query(1,1)
 cfg(3,h);cfg(0,h);cfg(0,0,word=words);cfg(1,h);cfg(4);cfg(7);cfg(2)
 cfg(3,0);query(1,1);cfg(1,0);query(1,1);cfg(0,0);query(1,1)
 setup()
 for n,cols in sorted({(1,1),(h,c),(min(h,3),min(c,9))}):
  for k in range(3):query(n,cols,xzero=[0,128,255][k],pre=[0,4,31][k])
 # Exact positive/negative half ties with odd zero addition, before saturation.
 setup(1,False)
 for gate,value,scale,shift,zero in [(1,1,1,1,1),(3,1,1,1,1),(1,-1,1,1,1),(3,-1,1,1,1),(-128,127,65535,0,-128),(127,-128,65535,0,127),(127,127,65535,31,-1),(0,-128,0,0,127)]:
  cfg(1,0,0,bias=gate);cfg(1,0,1,bias=value);cfg(3,0,scale=scale,shift=shift,zero=zero);query(1,1,[0])
 setup()
 for k in range(5 if h<32 else 2):query(h,c,pre=k%4)
 query(min(2,h),min(c,3),bad=0);query(h,c,bad=c-1)
 if ex:
  for pre in [0,1,8,31]:query(h,c,[[-2**31,2**31-1,-257,257,-3,3,-1,1][i%8]for i in range(c)],pre=pre)
 cfg(2);query(1,1)
 for phase in list(range(7))+([7]if ex else[]):
  setup(1,False);lines.append(f'2 {phase}\n');counts['live_resets']+=1;weights.clear();meta.clear();outmeta.clear();query(1,1)
 setup(1,False);lines.append('3\n');counts['priority_flows']+=1;outmeta[0]=(1,0,7);query(1,1,[0])
 return ''.join(lines),counts
