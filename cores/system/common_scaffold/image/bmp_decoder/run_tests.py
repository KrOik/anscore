from pathlib import Path
import sys,tempfile,json,hashlib,struct,io,random
from PIL import Image
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
RTL=H/'bmp_decoder.sv'
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_last=0,m_ready=1,done_ready=0;
reg[7:0]s_data=0;wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,frame_error;wire[7:0]error_code;wire[15:0]image_width,image_height;wire[23:0]m_rgb;
bmp_decoder #(.MAX_WIDTH(MW),.MAX_HEIGHT(MH))dut(.*);
reg[7:0]source[0:NB-1];reg[23:0]expectation[0:NP-1];integer cycles=0,got=0,i;reg stalled=0;reg[26:0]held;wire[26:0]token={m_rgb,m_sof,m_eol,m_last};
always @(negedge clk)begin cycles=cycles+1;ce=cycles%13>1;m_ready=cycles%7>1;if(cycles>2000000)$fatal(1,"timeout");end
always @(posedge clk)if(rst_n)begin
 if(!abort&&stalled&&(!m_valid||token!==held))$fatal(1,"hold");stalled=!abort&&m_valid&&!(ce&&m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin
 if(got>=NP||m_rgb!==expectation[got])$fatal(1,"pixel %d %h expected %h",got,m_rgb,expectation[got]);
 if(m_sof!==(got==0)||m_eol!==(got%WW==WW-1)||m_last!==(got==NP-1))$fatal(1,"markers");got=got+1;end end
 task tick;begin @(negedge clk);#1;end endtask
 task send;reg ok;begin ok=0;while(!ok&&!done_valid)begin @(posedge clk);ok=ce&&s_ready;end tick;end endtask
 initial begin
 $readmemh("SRC",source);$readmemh("EXP",expectation);repeat(3)tick;rst_n=1;tick;
 start_valid=1;while(!start_ready||!ce)tick;@(posedge clk);tick;start_valid=0;
 for(i=0;i<NB&&!done_valid;i=i+1)begin s_data=source[i];s_last=i==NB-1;s_valid=1;send;end s_valid=0;s_last=0;
 while(!done_valid)tick;if(error_code!=ERR||(!ERR&&(got!=NP||image_width!=WW||image_height!=HH)))$fatal(1,"outcome err %h got %d",error_code,got);
 repeat(7)tick;if(!done_valid)$fatal(1,"done hold");$display("PASS BMP %d pixels %d cycles",got,cycles);$finish;end
endmodule'''
def run_case(name,data,pixels,w,h,error=0,mw=64,mh=64):
 import re
 with tempfile.TemporaryDirectory(prefix='bmp_decode_') as td:
  d=Path(td);tb=TB
  for token,values in [('SRC',data),('EXP',pixels or [0])]:
   p=d/(token+'.hex');p.write_text('\n'.join(f'{v:x}' for v in values)+'\n');tb=tb.replace('"'+token+'"','"'+p.as_posix()+'"')
  for a,b in [('MW',mw),('MH',mh),('WW',w),('HH',h),('NB',len(data)),('NP',max(1,len(pixels))),('ERR',error)]:tb=re.sub(r'\b'+a+r'\b',str(b),tb)
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,H/(name+'_compile.log'))
  out=execute(['vvp',d/'a.vvp'],ROOT,H/(name+'_simulation.log'));assert 'PASS BMP' in out
 return dict(name=name,bytes=len(data),pixels=len(pixels),expected_error=error)
def fixture(w,h,top=False,gap=0,trailer=0):
 rng=random.Random(w*100+h);rgb=bytes(rng.randrange(256) for _ in range(w*h*3));im=Image.frombytes('RGB',(w,h),rgb);s=io.BytesIO();im.save(s,format='BMP');data=s.getvalue()
 if top:
  stride=(w*3+3)&~3;rows=[data[54+y*stride:54+(y+1)*stride] for y in range(h)];data=data[:22]+struct.pack('<i',-h)+data[26:54]+b''.join(reversed(rows))
 if gap:data=data[:10]+struct.pack('<I',54+gap)+data[14:54]+b'X'*gap+data[54:]
 data+=b'T'*trailer;data=data[:2]+struct.pack('<I',len(data))+data[6:]
 assert Image.open(io.BytesIO(data)).convert('RGB').tobytes()==rgb
 return data,[int.from_bytes(rgb[i:i+3],'big') for i in range(0,len(rgb),3)]
def main():
 rows=[]
 for w,h in [(1,1),(2,3),(3,4),(4,5),(7,9),(64,64)]:
  for top in [False,True]:
   data,pix=fixture(w,h,top,7 if top else 0,3 if top else 0);rows.append(run_case(f'valid_{w}_{h}_{top}',data,pix,w,h))
 data,pix=fixture(3,4)
 for name,off,value,err in [('signature',0,b'ZZ',2),('reserved',6,b'\x01',2),('dib',14,struct.pack('<I',108),2),('planes',26,b'\x02',2),('bpp',28,b'\x20',2),('compression',30,b'\x01',2),('width0',18,b'\0\0\0\0',3),('widthmax',18,struct.pack('<I',65),3),('height0',22,b'\0\0\0\0',3),('heightmin',22,struct.pack('<I',0x80000000),3),('offset',10,struct.pack('<I',53),4),('size',2,struct.pack('<I',54),4),('image_size',34,struct.pack('<I',1),4)]:
  bad=data[:off]+value+data[off+len(value):];rows.append(run_case(name,bad,[],3,4,err))
 rows.append(run_case('header_truncated',data[:20],[],3,4,1));rows.append(run_case('data_truncated',data[:-1],[],3,4,5))
 rows.append(run_case('missing_last',data+b'X',[],3,4,6))
 report=dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),cases=rows)
 (H/'evidence.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
if __name__=='__main__':main()
