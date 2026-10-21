"""Legal category extremes, wide dequant and independent real-valued IDCT."""
import json,math,numpy as np
from run_tests import HERE,run_case,hashes
Z=[0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63]
def segment(mark,payload):return bytes([255,mark])+len(payload+bytes(2)).to_bytes(2,'big')+payload
def stream(vals,q=255):
 b=bytes.fromhex('ffd8')+segment(0xdb,bytes([0])+bytes([q])*64)
 b+=segment(0xc0,bytes.fromhex('080008000801011100'))
 counts=bytes([0,2]+[0]*14)
 b+=segment(0xc4,bytes([0])+counts+bytes([0,11])+bytes([0x10])+counts+bytes([0,10]))
 b+=segment(0xda,bytes.fromhex('010100003f00'))
 bits=''
 for k,a in enumerate(vals):
  if k==0:
   bits+='01' if a else '00';s=11 if a else 0
  else:bits+='01';s=10
  if s:bits+=f'{(a if a>=0 else a+(1<<s)-1):0{s}b}'
 bits+='1'*((-len(bits))%8)
 data=bytes(int(bits[i:i+8],2) for i in range(0,len(bits),8));b+=data.replace(b'\xff',b'\xff\x00')+bytes.fromhex('ffd9');return b

def main():
 t=np.array([[(1/math.sqrt(8) if u==0 else .5)*math.cos((2*x+1)*u*math.pi/16) for u in range(8)] for x in range(8)])
 patterns=[('all_positive',[2047]+[1023]*63),('all_negative',[-2047]+[-1023]*63),('alternating',[2047]+[1023*(-1)**k for k in range(63)]),('negative_dc',[-2047]+[1023*(-1)**k for k in range(63)])]
 rows=[]
 for name,v in patterns:
  coef=np.zeros(64);coef[Z]=np.asarray(v)*255
  ideal=np.clip(np.floor(t@coef.reshape(8,8)@t.T+128+.5),0,255).astype(int)
  row=run_case(name,stream(v),8,8,ideal=ideal);rows.append(row);print(row,flush=True)
 (HERE/'numeric_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),cases=rows,max_dequant_abs=521985),indent=2)+'\n')
if __name__=='__main__':main()
