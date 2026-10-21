"""Execute real RTL; independently parse exact TIFF bytes with two mature readers."""
from pathlib import Path
import hashlib,io,json,struct,sys,tempfile
import numpy as np
import tifffile
from PIL import Image
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'tiff_encoder.sv'
def hashes():return {RTL.name:hashlib.sha256(RTL.read_bytes()).hexdigest()}
def oracle(w,h,r,mode,be,pixels):
 e='>' if be else '<';n=(h+r-1)//r;bpp=[1,2,3][mode];base=152+8*n
 entries=[(256,4,1,w),(257,4,1,h),(258,3,3 if mode==2 else 1,146 if mode==2 else 16 if mode==1 else 8),(259,3,1,1),(262,3,1,2 if mode==2 else 1),(273,4,n,base if n==1 else 152),(274,3,1,1),(277,3,1,3 if mode==2 else 1),(278,4,1,r),(279,4,n,w*h*bpp if n==1 else 152+4*n),(284,3,1,1)]
 data=(b'MM' if be else b'II')+struct.pack(e+'HIH',42,8,11)
 for tag,typ,count,value in entries:
  data+=struct.pack(e+'HHI',tag,typ,count)+(struct.pack(e+'H',value)+b'\0\0' if typ==3 and count==1 else struct.pack(e+'I',value))
 data+=struct.pack(e+'IHHH',0,8,8,8)
 data+=b''.join(struct.pack(e+'I',base+i*r*w*bpp) for i in range(n))
 data+=b''.join(struct.pack(e+'I',min(r,h-i*r)*w*bpp) for i in range(n))
 data+=b''.join(p.to_bytes(3,'big') if mode==2 else struct.pack(e+'H',p&65535) if mode==1 else bytes([p&255]) for p in pixels)
 return data
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,cfg_big_endian=BB,abort=0;
reg[1:0]cfg_mode=MM;reg[31:0]s_pixel;reg s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
wire start_ready,s_ready,m_valid,m_sof,m_last,done_valid,frame_error;wire[7:0]m_data,error_code;wire[31:0]output_bytes;
tiff_encoder #(.WIDTH(WW),.HEIGHT(HH),.ROWS_PER_STRIP(RR))dut(.*);
reg[31:0]pixels[0:NN-1];reg[7:0]expected[0:BYTES-1];integer cyc=0,i,got=0,fd;reg heldvalid=0;reg[9:0]held;
always @(negedge clk)begin cyc=cyc+1;ce=cyc%11>1;m_ready=cyc%7<4;if(cyc>5000000)$fatal(1,"timeout");end
always @(posedge clk)if(rst_n)begin
 if(heldvalid&&(!m_valid||{m_last,m_sof,m_data}!==held))$fatal(1,"stall");heldvalid=m_valid&&!(ce&&m_ready);held={m_last,m_sof,m_data};
 if(ce&&m_valid&&m_ready)begin if(m_data!==expected[got]||m_sof!==(got==0)||m_last!==(got==BYTES-1))$fatal(1,"bytes %d %h %h",got,m_data,expected[got]);$fwrite(fd,"%c",m_data);got=got+1;end
end
initial begin $readmemh("pixels.hex",pixels);$readmemh("expected.hex",expected);fd=$fopen("actual.tif","wb");repeat(3)@(negedge clk);rst_n=1;
@(negedge clk);start_valid=1;do @(posedge clk);while(!ce);@(negedge clk);start_valid=0;cfg_mode=3;cfg_big_endian=!BB;
for(i=0;i<NN;i=i+1)begin s_pixel=pixels[i];s_valid=1;s_sof=i==0;s_eol=i%WW==WW-1;s_last=i==NN-1;do @(posedge clk);while(!(ce&&s_ready));@(negedge clk);s_valid=0;end
wait(done_valid);#1;if(frame_error||error_code||got!=BYTES||output_bytes!=BYTES)$fatal(1,"done");repeat(4)@(negedge clk);if(!done_valid)$fatal(1,"done hold");$fclose(fd);$display("PASS");$finish;end
endmodule'''
def run_case(w,h,r,mode,be):
 pixels=[((i*65521)^(i<<17)^0xffffff)&0xffffff for i in range(w*h)]
 if mode==1:pixels[:min(6,len(pixels))]=[0,1,255,256,32768,65535][:min(6,len(pixels))]
 expected=oracle(w,h,r,mode,be,pixels)
 with tempfile.TemporaryDirectory(prefix='tiff_encode_') as tmp:
  d=Path(tmp);(d/'pixels.hex').write_text('\n'.join(f'{p:08x}' for p in pixels));(d/'expected.hex').write_text('\n'.join(f'{v:02x}' for v in expected))
  tb=TB
  for key,value in dict(WW=w,HH=h,RR=r,MM=mode,BB=be,NN=w*h,BYTES=len(expected)).items():tb=tb.replace(key,str(value))
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,d/'tb.sv'],d,d/'compile.log');execute(['vvp',d/'sim'],d,d/'run.log')
  actual=(d/'actual.tif').read_bytes();assert actual==expected
  arr=np.array(pixels,dtype=np.uint32).reshape(h,w)
  want=np.stack([(arr>>16)&255,(arr>>8)&255,arr&255],axis=-1).astype('uint8') if mode==2 else (arr&65535).astype('uint16') if mode==1 else (arr&255).astype('uint8')
  assert np.array_equal(tifffile.imread(io.BytesIO(actual)),want)
  im=Image.open(io.BytesIO(actual));im.load();assert np.array_equal(np.asarray(im),want)
 return dict(width=w,height=h,rows_per_strip=r,mode=mode,big_endian=be,pixels=w*h,file_bytes=len(expected),pillow=True,tifffile=True)
def main():
 frozen=hashes();cases=[]
 for w,h,r in [(1,1,1),(7,5,2),(16,12,4),(64,32,7),(4096,1,4096)]:
  for mode in range(3):
   for be in range(2):
    row=run_case(w,h,r,mode,be);cases.append(row);print(json.dumps(row),flush=True)
 assert hashes()==frozen
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=cases),indent=2)+'\n')
if __name__=='__main__':main()
