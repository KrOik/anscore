"""Translate independent software-reference fixture commands to board ROM ABI."""
from pathlib import Path
import tempfile

def fixture_vectors(generator,record_words=10,select=None):
 with tempfile.TemporaryDirectory(prefix='a48_reference_') as t:
  root=Path(t);generator(root)
  def read(name):
   f=root/(name+'.hex');return [int(v,16) for v in f.read_text().split()] if f.exists() else []
  raw=read('commands');si=read('inputs');so=read('outputs') or read('expected');sk=read('coeffs')
 records=[];ip=op=kp=0
 for index in range(len(raw)//record_words):
  row=raw[index*record_words:(index+1)*record_words];mode,w,h,dw,dh,p0,p1,error,ni,no=row[:10];nk=row[10] if record_words==11 else 0
  if select is None or select(index,row):records.append((row,si[ip:ip+ni],so[op:op+no],sk[kp:kp+nk]))
  ip+=ni;op+=no;kp+=nk
 commands=[];inputs=[];outputs=[];coeff=[]
 for index,(row,image,result,words) in enumerate(records):
  mode,w,h,dw,dh,p0,p1,error,ni,no=row[:10]
  fields=[(mode,0),((0x80+index)&255,4),(w,12),(h,28),(dw,44),(dh,60),(p0&0xffffffff,76),(p1,108),(ni,236),(no,252),(0,268),(len(words),284),(error,300),(len(inputs),302),(len(outputs),318),(0,334),(len(coeff),350)]
  commands.append(sum(v<<shift for v,shift in fields));inputs.extend(image);outputs.extend(result);coeff.extend(words)
 return commands,inputs,outputs,[],coeff
