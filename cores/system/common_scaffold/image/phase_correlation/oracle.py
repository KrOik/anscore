"""Recursive integer FFT model, separate from the RTL address/stage controller."""
import math
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parent
def rounding(v,bits):return (-1 if v<0 else 1)*((abs(int(v))+(1<<(bits-1)))>>bits)
def signed(v,bits):return v-(1<<bits) if v&(1<<(bits-1)) else v
TWIDDLE=[(signed(int(s,16)>>17,17),signed(int(s,16)&0x1ffff,17)) for s in (ROOT/'twiddle.mem').read_text().split()]
def fft1(values,inverse=False):
 if len(values)==1:return values[:]
 e,o=fft1(values[::2],inverse),fft1(values[1::2],inverse);n=len(values);out=[None]*n
 for j,(a,b) in enumerate(zip(e,o)):
  wr,wi=TWIDDLE[j*32//n]
  if inverse:wi=-wi
  tr=rounding(b[0]*wr-b[1]*wi,15);ti=rounding(b[0]*wi+b[1]*wr,15)
  out[j]=(rounding(a[0]+tr,1),rounding(a[1]+ti,1))
  out[j+n//2]=(rounding(a[0]-tr,1),rounding(a[1]-ti,1))
 return out
def fft2(frame,inverse=False):
 rows=[fft1(list(row),inverse) for row in frame];n=len(rows)
 cols=[fft1([rows[y][x] for y in range(n)],inverse) for x in range(n)]
 return [[cols[x][y] for x in range(n)] for y in range(n)]
def oracle(a,b,remove_dc=True,full=False):
 n=len(a);fa=fft2([[(int(x)<<12,0) for x in row] for row in a]);fb=fft2([[(int(x)<<12,0) for x in row] for row in b]);power=[];valid=0
 for y in range(n):
  row=[]
  for x in range(n):
   ar,ai=fa[y][x];br,bi=fb[y][x]
   r=rounding(ar*br+ai*bi,12);i=rounding(ai*br-ar*bi,12);m=math.isqrt(r*r+i*i)
   if (remove_dc and x==0 and y==0) or m==0:row.append((0,0));continue
   valid+=1
   divide=lambda v:(-1 if v<0 else 1)*(((abs(v)<<20)+m//2)//m)
   row.append((divide(r),divide(i)))
  power.append(row)
 corr=fft2(power,True);real=np.array([[v[0] for v in row] for row in corr],dtype=np.int64)
 index=int(real.argmax());y,x=divmod(index,n);peak=int(real.max());ties=int((real==peak).sum())
 result={'dx':x if x<n//2 else x-n,'dy':y if y<n//2 else y-n,'peak':peak,'valid_bins':valid,'invalid':valid<3 or ties!=1 or peak<=0,'ties':ties}
 if full:result.update(fft_a=fa,fft_b=fb,crosspower=power,correlation=corr)
 return result
def numpy_oracle(a,b,remove_dc=True):
 f=np.fft.fft2(a)*np.conj(np.fft.fft2(b));m=np.abs(f);p=np.divide(f,m,out=np.zeros_like(f),where=m>1e-12)
 if remove_dc:p[0,0]=0
 corr=np.fft.ifft2(p).real;y,x=np.unravel_index(corr.argmax(),corr.shape);n=len(a)
 return {'dx':int(x if x<n//2 else x-n),'dy':int(y if y<n//2 else y-n),'peak':float(corr.max())}
