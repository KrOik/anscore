from pathlib import Path
import sys,tempfile,json,hashlib,struct,io,random
from PIL import Image
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
RTL=H/'tiff_decoder.sv'
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_last=0,m_ready=1,done_ready=0;
reg[7:0]s_data=0;wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,frame_error;wire[7:0]error_code;wire[15:0]image_width,image_height;wire[1:0]image_mode;wire[23:0]m_pixel;
tiff_decoder #(.MAX_WIDTH(MW),.MAX_HEIGHT(MH),.MAX_FILE_BYTES(MB))dut(.*);
reg[7:0]source[0:NB-1];reg[23:0]expectation[0:NP-1];integer cycles=0,got=0,i;reg stalled=0;reg[26:0]held;wire[26:0]token={m_pixel,m_sof,m_eol,m_last};
always @(negedge clk)begin cycles=cycles+1;ce=cycles%13>1;m_ready=cycles%7>1;if(cycles>2000000)$fatal(1,"timeout");end
always @(posedge clk)if(rst_n)begin
 if(!abort&&stalled&&(!m_valid||token!==held))$fatal(1,"hold");stalled=!abort&&m_valid&&!(ce&&m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin
 if(got>=NP||m_pixel!==expectation[got])$fatal(1,"pixel %d %h expected %h",got,m_pixel,expectation[got]);
 if(m_sof!==(got==0)||m_eol!==(got%WW==WW-1)||m_last!==(got==NP-1))$fatal(1,"markers");got=got+1;end end
 task tick;begin @(negedge clk);#1;end endtask
 task send;reg ok;begin ok=0;while(!ok&&!done_valid)begin @(posedge clk);ok=ce&&s_ready;end tick;end endtask
 initial begin
 $readmemh("SRC",source);$readmemh("EXP",expectation);repeat(3)tick;rst_n=1;tick;
 start_valid=1;while(!start_ready||!ce)tick;@(posedge clk);tick;start_valid=0;
 for(i=0;i<NB&&!done_valid;i=i+1)begin s_data=source[i];s_last=i==NB-1;s_valid=1;send;end s_valid=0;s_last=0;
 while(!done_valid)tick;if(error_code!=ERR||(!ERR&&(got!=NP||image_width!=WW||image_height!=HH||image_mode!=MODE)))$fatal(1,"outcome err %h got %d",error_code,got);
 repeat(7)tick;if(!done_valid)$fatal(1,"done hold");$display("PASS TIFF %d pixels %d cycles",got,cycles);$finish;end
endmodule'''
def run_case(name,data,pixels,w,h,mode=0,error=0,mw=16,mh=12,mb=4096):
 import re
 with tempfile.TemporaryDirectory(prefix='tiff_decode_') as td:
  d=Path(td);tb=TB
  for token,values in [('SRC',data),('EXP',pixels or [0])]:
   p=d/(token+'.hex');p.write_text('\n'.join(f'{v:x}' for v in values)+'\n');tb=tb.replace('"'+token+'"','"'+p.as_posix()+'"')
  for a,b in [('MW',mw),('MH',mh),('MB',mb),('MODE',mode),('WW',w),('HH',h),('NB',len(data)),('NP',max(1,len(pixels))),('ERR',error)]:tb=re.sub(r'\b'+a+r'\b',str(b),tb)
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,H/(name+'_compile.log'))
  out=execute(['vvp',d/'a.vvp'],ROOT,H/(name+'_simulation.log'));assert 'PASS TIFF' in out
 return dict(name=name,bytes=len(data),pixels=len(pixels),expected_error=error)

def fixture(w=7,h=5,mode=0,big=False,rps=2,short=False,white=False,shuffle=True,reverse=True):
 e='>' if big else '<';pack=lambda fmt,*v:struct.pack(e+fmt,*v)
 rng=random.Random(w*100+h+mode);pixels=[rng.randrange(1<<(8 if mode==0 else 16 if mode==1 else 24)) for _ in range(w*h)]
 bits=16 if mode==1 else 8;samples=3 if mode==2 else 1;photo=2 if mode==2 else 0 if white else 1
 tags=[(256,3 if short else 4,[w]),(257,3 if short else 4,[h]),(258,3,[bits]*samples),(259,3,[1]),(262,3,[photo]),(273,3 if short else 4,[]),(274,3,[1]),(277,3,[samples]),(278,3 if short else 4,[rps]),(279,3 if short else 4,[]),(284,3,[1])]
 n=(h+rps-1)//rps;counts=[min(rps,h-i*rps)*w*(bits//8)*samples for i in range(n)]
 buf=bytearray((b'MM' if big else b'II')+pack('HI',42,16)+b'gapBYTES')
 buf+=pack('H',len(tags))+bytes(len(tags)*12)+pack('I',0)
 data_chunks=[]
 for i in range(n):
  chunk=bytearray()
  for pix in pixels[i*rps*w:min((i+1)*rps*w,len(pixels))]:
   raw=((1<<bits)-1-pix) if white and mode!=2 else pix
   chunk+=pack('H',raw) if mode==1 else raw.to_bytes(3,'big') if mode==2 else bytes([raw])
  data_chunks.append(bytes(chunk))
 offsets=[0]*n
 for i in (reversed(range(n)) if reverse else range(n)):
  buf+=b'PAD';offsets[i]=len(buf);buf+=data_chunks[i]
 for j,(tag,typ,values) in enumerate(tags):
  if tag==273:values=offsets
  if tag==279:values=counts
  payload=pack(('H' if typ==3 else 'I')*len(values),*values)
  if len(payload)>4:
   if len(buf)%2:buf+=b'X'
   field=pack('I',len(buf));buf+=payload
  else:field=payload.ljust(4,b'\0')
  off=18+j*12;buf[off:off+12]=pack('HHI',tag,typ,len(values))+field
 data=bytes(buf)
 if mode==1 and white:
  import tifffile
  expected=[65535-int(v) for v in tifffile.imread(io.BytesIO(data)).reshape(-1)]
 else:
  im=Image.open(io.BytesIO(data));im.load();expected=list(im.getdata())
 if mode==2:expected=[(r<<16)|(g<<8)|b for r,g,b in expected]
 assert expected==pixels,(mode,big,white,expected[:4],pixels[:4])
 return data,pixels

def main():
 rows=[]
 for mode in [0,1,2]:
  for big in [False,True]:
   for rps in [1,2,5,0xffffffff]:
    for short in [False,True]:
     if short and rps>65535:continue
     d,p=fixture(mode=mode,big=big,rps=rps,short=short);rows.append(run_case(f'valid_{mode}_{big}_{rps}_{short}',d,p,7,5,mode))
 for mode in [0,1]:
  for big in [False,True]:
   d,p=fixture(mode=mode,big=big,white=True);rows.append(run_case(f'white_{mode}_{big}',d,p,7,5,mode))
 for mode in [0,1,2]:
  d,p=fixture(mode=mode);im=Image.open(io.BytesIO(d));o=io.BytesIO();im.save(o,format='TIFF',compression='raw');rows.append(run_case(f'pillow_{mode}',o.getvalue(),p,7,5,mode))
 import tifffile,numpy as np
 for mode in [0,1,2]:
  for big in [False,True]:
   d,p=fixture(mode=mode,big=big);arr=np.array(p,dtype=np.uint16 if mode==1 else np.uint32)
   if mode==2:arr=np.array([[(v>>16)&255,(v>>8)&255,v&255] for v in p],dtype=np.uint8).reshape(5,7,3)
   else:arr=arr.astype(np.uint16 if mode==1 else np.uint8).reshape(5,7)
   out=io.BytesIO();tifffile.imwrite(out,arr,byteorder='>' if big else '<',rowsperstrip=2,photometric='rgb' if mode==2 else 'minisblack',metadata=None)
   rows.append(run_case(f'tifffile_{mode}_{big}',out.getvalue(),p,7,5,mode))
 report=dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),cases=rows)
 (H/'evidence.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
if __name__=='__main__':main()

