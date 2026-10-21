"""Specification-driven bit writer: fixed overlap/window edge and dynamic repeat boundaries."""
import zlib,struct,numpy as np,json,hashlib
from run_tests import H,RTL,chunk,run_case

def canonical(lengths):
 counts=[lengths.count(i) for i in range(16)];counts[0]=0;code=0;nextcode={}
 for n in range(1,16):code=(code+counts[n-1])*2;nextcode[n]=code
 out={}
 for sym,n in enumerate(lengths):
  if n:out[sym]=(nextcode[n],n);nextcode[n]+=1
 return out
class Writer:
 def __init__(self):self.bits=[]
 def field(self,v,n):self.bits.extend((v>>i)&1 for i in range(n))
 def symbol(self,v,codes):
  code,n=codes[v];self.bits.extend((code>>i)&1 for i in range(n-1,-1,-1))
 def bytes(self):
  self.bits.extend([0]*((-len(self.bits))%8));return bytes(sum(self.bits[j+i]<<i for i in range(8)) for j in range(0,len(self.bits),8))
def png(raw,deflate,w,h):
 z=b'\x78\x9c'+deflate+struct.pack('>I',zlib.adler32(raw));assert zlib.decompress(z)==raw
 return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,0,0,0,0))+chunk(b'IDAT',z)+chunk(b'IEND',b'')
def fixed_window():
 wr=Writer();wr.field(3,3);lit=canonical([8]*144+[9]*112+[7]*24+[8]*8);dist=canonical([5]*32)
 wr.symbol(0,lit)
 for _ in range(127):wr.symbol(285,lit);wr.symbol(0,dist)
 wr.symbol(0,lit) # raw prefix exactly 32768 bytes
 wr.symbol(284,lit);wr.field(29,5) # length 227+29=256
 wr.symbol(29,dist);wr.field(8191,13) # distance24577+8191=32768
 wr.symbol(256,lit)
 raw=bytes(33024);return png(raw,wr.bytes(),255,129),np.zeros((129,255,3),dtype=np.uint8)
def dynamic_repeats():
 wr=Writer();wr.field(5,3);wr.field(29,5);wr.field(29,5);wr.field(14,4) # HLIT286/HDIST30/HCLEN18
 cl=[0]*19
 for s,n in [(0,2),(2,2),(3,3),(16,3),(17,3),(18,3)]:cl[s]=n
 order=[16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]
 for s in order[:18]:wr.field(cl[s],3)
 cc=canonical(cl)
 wr.symbol(3,cc);wr.symbol(16,cc);wr.field(3,2) # seven len3 literals0..6
 wr.symbol(18,cc);wr.field(127,7);wr.symbol(18,cc);wr.field(100,7) # 249 zeros
 wr.symbol(3,cc) # EOB256
 wr.symbol(17,cc);wr.field(0,3);wr.symbol(18,cc);wr.field(15,7) # 29 zeros to HLIT286
 wr.symbol(2,cc);wr.symbol(16,cc);wr.field(0,2) # four len2 distances0..3
 wr.symbol(18,cc);wr.field(15,7) # 26 zero distance entries
 lit=canonical([3]*7+[0]*249+[3]+[0]*29)
 wr.symbol(0,lit);wr.symbol(0,lit);wr.symbol(256,lit)
 return png(bytes(2),wr.bytes(),1,1),np.zeros((1,1,3),dtype=np.uint8)
def main():
 rows=[]
 d,e=dynamic_repeats();row=run_case('dynamic_repeat16_17_18',d,e);row.update(hlit=286,hdist=30,repeat_symbols=[16,17,18]);rows.append(row)
 d,e=fixed_window();row=run_case('lz77_distance32768_overlap1_wrap',d,e,mw=255,mh=129);row.update(max_distance=32768,overlap_distance=1,dictionary_wrap=True);rows.append(row)
 (H/'deflate_evidence.json').write_text(json.dumps({'result':'PASS','rtl_sha256':hashlib.sha256(RTL.read_bytes()).hexdigest(),'cases':rows,'independent_stream_check':'Python zlib.decompress accepted each handcrafted RFC1951 stream before RTL'},indent=2)+'\n')
if __name__=='__main__':main()
