"""Entropy-category stress streams; independent real-IDCT oracle, no universal Pillow equivalence."""
import json
from run_tests import HERE,run_case,hashes

def segment(mark,payload):return bytes([255,mark])+(len(payload)+2).to_bytes(2,'big')+payload

def stream(H,V,negative=False):
 b=bytes.fromhex('ffd8')+segment(0xdb,bytes([0])+bytes([255])*64)
 b+=segment(0xc0,bytes([8,0,8,0,8,3,1,H*16+V,0,2,0x11,0,3,0x11,0]))
 counts=bytes([0,2]+[0]*14)
 b+=segment(0xc4,bytes([0])+counts+bytes([0,11])+bytes([0x10])+counts+bytes([0,10]))
 b+=segment(0xda,bytes.fromhex('03010002000300003f00'))
 bits=''
 for ci in range(3):
  for block in range(H*V if ci==0 else 1):
   sign=-1 if (ci+negative)%2 else 1
   dc=2047*sign if block==0 else 0
   bits+='00' if dc==0 else '01'+f'{dc if dc>0 else dc+2047:011b}'
   for k in range(63):
    ac=1023*sign*((-1)**k)
    bits+='01'+f'{ac if ac>0 else ac+1023:010b}'
 bits+='1'*((-len(bits))%8)
 entropy=bytes(int(bits[j:j+8],2) for j in range(0,len(bits),8))
 return b+entropy.replace(b'\xff',b'\xff\x00')+bytes.fromhex('ffd9')
def main():
 rows=[]
 for H,V in [(1,1),(2,1),(2,2)]:
  for neg in [False,True]:
   row=run_case(f'wide_{H}{V}_{int(neg)}',stream(H,V,neg),8,8,pillow_limit=None);rows.append(row);print(row,flush=True)
 (HERE/'numeric_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),cases=rows,pillow_equivalence=False,max_dequant_abs=521985),indent=2)+'\n')
if __name__=='__main__':main()
