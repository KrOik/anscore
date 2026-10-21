"""Independent JPEG entropy/float IDCT and rational centered reconstruction oracle."""
import math,numpy as np
Z=[0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63]
def decode(data):
 assert data[:2]==b'\xff\xd8';pos=2;qt={};ht={};frame=[];scan=[]
 while True:
  assert data[pos]==255;marker=data[pos+1];length=int.from_bytes(data[pos+2:pos+4],'big');payload=data[pos+4:pos+2+length];pos+=length+2
  if marker==0xdb:
   j=0
   while j<len(payload):
    q=payload[j];assert q<4;qt[q]=np.array(list(payload[j+1:j+65]),dtype=int);j+=65
  elif marker==0xc4:
   j=0
   while j<len(payload):
    tid=payload[j];counts=payload[j+1:j+17];j+=17;codes={};c=0
    for n,count in enumerate(counts,1):
     for _ in range(count):codes[(n,c)]=payload[j];c+=1;j+=1
     c*=2
    ht[tid]=codes
  elif marker==0xc0:
   h=int.from_bytes(payload[1:3],'big');w=int.from_bytes(payload[3:5],'big');assert payload[5]==3
   frame=[dict(cid=payload[i],hx=payload[i+1]>>4,vy=payload[i+1]&15,q=payload[i+2]) for i in (6,9,12)]
  elif marker==0xda:
   assert payload[0]==3;scan=[(payload[i],payload[i+1]>>4,payload[i+1]&15) for i in (1,3,5)];break
 H=frame[0]['hx'];V=frame[0]['vy'];planes=[np.zeros(((h*f['vy']+V-1)//V,(w*f['hx']+H-1)//H),dtype=int) for f in frame]
 entropy=bytearray()
 while data[pos:pos+2]!=b'\xff\xd9':
  b=data[pos];pos+=1
  if b==255:assert data[pos]==0;pos+=1
  entropy.append(b)
 bitpos=0
 def bit():
  nonlocal bitpos
  v=(entropy[bitpos//8]>>(7-bitpos%8))&1;bitpos+=1;return v
 def huff(table):
  code=0
  for n in range(1,17):
   code=code*2+bit()
   if (n,code) in ht[table]:return ht[table][n,code]
  raise ValueError('invalid Huffman')
 def amplitude(n):
  v=0
  for _ in range(n):v=v*2+bit()
  return v if not n or v>=1<<(n-1) else v-(1<<n)+1
 t=np.array([[(1/math.sqrt(8) if u==0 else .5)*math.cos((2*x+1)*u*math.pi/16) for u in range(8)] for x in range(8)])
 predictor=[0,0,0]
 for my in range(0,h,8*V):
  for mx in range(0,w,8*H):
   for ci,(cid,dc,ac) in enumerate(scan):
    f=frame[ci];assert cid==f['cid']
    for by in range(f['vy']):
     for bx in range(f['hx']):
      coeff=np.zeros(64,dtype=int);predictor[ci]+=amplitude(huff(dc));coeff[0]=predictor[ci];k=1
      while k<64:
       symbol=huff(16+ac)
       if symbol==0:break
       if symbol==0xf0:k+=16;continue
       k+=symbol>>4;coeff[k]=amplitude(symbol&15);k+=1
      natural=np.zeros(64);natural[Z]=coeff*qt[f['q']]
      block=np.clip(np.floor(t@natural.reshape(8,8)@t.T+128+.5),0,255).astype(int)
      y=my*f['vy']//V+by*8;x=mx*f['hx']//H+bx*8
      hh=min(8,planes[ci].shape[0]-y);ww=min(8,planes[ci].shape[1]-x)
      if hh>0 and ww>0:planes[ci][y:y+hh,x:x+ww]=block[:hh,:ww]
 rgb=np.empty((h,w,3),dtype=int)
 for y in range(h):
  for x in range(w):
   values=[]
   # Direct spatial-coordinate bilinear interpolation; independent from RTL 3/1 tap casework.
   for plane in planes[1:]:
    if H==2 and plane.shape[1]<=2:
     values.append(int(plane[y//V,x//H])-128);continue
    u=(x-(H-1)/2)/H;v=(y-(V-1)/2)/V;x0=math.floor(u);y0=math.floor(v);fx=u-x0;fy=v-y0
    total=0
    for dy in (0,1):
     for dx in (0,1):total+=plane[min(max(y0+dy,0),len(plane)-1),min(max(x0+dx,0),plane.shape[1]-1)]*(fx if dx else 1-fx)*(fy if dy else 1-fy)
    values.append(math.floor(total+.5)-128)
   cb,cr=values;Y=int(planes[0][y,x]);rgb[y,x]=np.clip(np.floor(np.array([Y+1.402*cr,Y-.344136*cb-.714136*cr,Y+1.772*cb])+.5),0,255)
 return rgb,dict(width=w,height=h,sampling=(H,V),planes=planes)
