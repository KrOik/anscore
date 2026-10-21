"""Actual complete-file TIFF encoder -> decoder, with independent external readers."""
from pathlib import Path
import hashlib,io,tempfile
import numpy as np
import tifffile
from PIL import Image
from tooling import PACKAGE,ROOT,evidence_dir,execute,write_json
TB=r'''module tb;
localparam W=@W@,H=@H@,R=@R@,N=W*H,F=6;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start=0,sv=0,sof=0,eol=0,last=0,ack=0,mr=0,be=0;
reg[31:0]pixel;reg[1:0]mode;
wire er,sr,ev,es,el,dr,ed,ee,dsr,mv,ms,me,ml,dd,de;
wire[7:0]byte_,ec,dc;wire[23:0]outpixel;wire[1:0]outmode;
wire[31:0]obytes;wire[15:0]iw,ih;
tiff_encoder #(.WIDTH(W),.HEIGHT(H),.ROWS_PER_STRIP(R)) enc(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(er),.cfg_mode(mode),.cfg_big_endian(be),.abort(1'b0),
.s_pixel(pixel),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_last(last),.s_ready(sr),
.m_data(byte_),.m_valid(ev),.m_sof(es),.m_last(el),.m_ready(dr),
.done_valid(ed),.done_ready(ack),.frame_error(ee),.error_code(ec),.output_bytes(obytes));
tiff_decoder #(.MAX_WIDTH(W),.MAX_HEIGHT(H),.MAX_FILE_BYTES(8192)) dec(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(dsr),.abort(1'b0),
.s_data(byte_),.s_valid(ev),.s_ready(dr),.s_last(el),
.m_pixel(outpixel),.m_valid(mv),.m_ready(mr),.m_sof(ms),.m_eol(me),.m_last(ml),
.done_valid(dd),.done_ready(ack),.frame_error(de),.error_code(dc),
.image_width(iw),.image_height(ih),.image_mode(outmode));
reg[31:0]pixels[0:F*N-1];reg[23:0]expected[0:F*N-1];
integer i,f,got=0,bytes=0,eofcount=0,cycle=0,fd;reg take,he=0,hm=0;reg[9:0]et;reg[26:0]mt;reg[31:0]rng=192341;
always @(posedge clk)begin
cycle=cycle+1;if(cycle>5000000)$fatal(1,"timeout");
if(rst_n)begin
if(ed&&ee)$fatal(1,"encoder error %h",ec);if(dd&&de)$fatal(1,"decoder error %h",dc);
if(he&&(!ev||{byte_,es,el}!==et))$fatal(1,"byte hold");he=ev&&!(ce&&dr);et={byte_,es,el};
if(hm&&(!mv||{outpixel,ms,me,ml}!==mt))$fatal(1,"pixel hold");hm=mv&&!(ce&&mr);mt={outpixel,ms,me,ml};
if(ce&&ev&&dr)begin
if(es!==(bytes==0))$fatal(1,"first byte marker");$fwrite(fd,"%02x\n",byte_);bytes=bytes+1;if(el)eofcount=eofcount+1;end
if(ce&&mv&&mr)begin
if(got>=F*N||outpixel!==expected[got]||ms!==(got%N==0)||me!==(got%W==W-1)||ml!==(got%N==N-1))$fatal(1,"pixel %d got%h expected%h",got,outpixel,expected[got]);got=got+1;end
end end
task tick;begin @(negedge clk);#1;rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[3];mr=rng[2]|rng[5];end endtask
initial begin
$readmemh("pixels.mem",pixels);$readmemh("expected.mem",expected);
repeat(3)@(negedge clk);#1;rst_n=1;
for(f=0;f<F;f=f+1)begin
fd=$fopen($sformatf("encoded_%0d.hex",f),"w");if(!fd)$fatal(1,"file");bytes=0;eofcount=0;
ce=1;mode=f/2;be=f%2;#1;if(!er||!dsr)$fatal(1,"start ready");start=1;@(negedge clk);#1;start=0;mode=3;be=!(f%2);
i=0;while(i<N)begin sv=1;pixel=pixels[f*N+i];sof=i==0;eol=i%W==W-1;last=i==N-1;@(posedge clk);take=ce&&sr;if(take)i=i+1;tick;end sv=0;
while(!ed||!dd)tick;
if(ee||de||ec||dc||got!=(f+1)*N||iw!=W||ih!=H||outmode!=f/2||obytes!=bytes||eofcount!=1)$fatal(1,"completion");
$fclose(fd);ce=0;ack=1;repeat(3)@(negedge clk);#1;if(!ed||!dd)$fatal(1,"done hold");ce=1;@(negedge clk);#1;ack=0;
end
$display("PASS TIFF_CODEC frames=%d pixels=%d",F,got);$finish;
end endmodule'''
def run(w,h,r):
 folder=evidence_dir('tiff_codec_chain');rng=np.random.default_rng(w*431+h*7+r)
 pixels=[];expected=[];frames=[]
 for f in range(6):
  values=rng.integers(0,1<<32,w*h,dtype=np.uint32);mode=f//2
  if mode==1:
   for i,v in enumerate([0,1,255,256,32768,65535][:w*h]):values[i]=v
  pixels.extend(int(v) for v in values)
  masked=values&[255,65535,0xffffff][mode];expected.extend(int(v) for v in masked)
  arr=masked.reshape(h,w)
  frame=np.stack([(arr>>16)&255,(arr>>8)&255,arr&255],axis=-1).astype('uint8') if mode==2 else arr.astype('uint16' if mode==1 else 'uint8')
  frames.append(frame)
 sources=[PACKAGE/'image/tiff_encoder/tiff_encoder.sv',PACKAGE/'image/tiff_decoder/tiff_decoder.sv'];frozen={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
 with tempfile.TemporaryDirectory(prefix='tiff_codec_chain_') as tmp:
  p=Path(tmp)
  for name,values in [('pixels',pixels),('expected',expected)]: (p/(name+'.mem')).write_text('\n'.join(f'{v:x}' for v in values))
  (p/'tb.sv').write_text(TB.replace('@W@',str(w)).replace('@H@',str(h)).replace('@R@',str(r)))
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*sources,p/'tb.sv'],ROOT,folder/'compile.log')
  execute(['vvp',p/'sim'],p,folder/'simulation.log',timeout=300)
  sizes=[]
  for f,want in enumerate(frames):
   payload=bytes(int(v,16) for v in (p/f'encoded_{f}.hex').read_text().split());sizes.append(len(payload))
   assert payload[:2]==(b'II' if f%2==0 else b'MM')
   assert np.array_equal(tifffile.imread(io.BytesIO(payload)),want)
   image=Image.open(io.BytesIO(payload));image.load();assert np.array_equal(np.asarray(image),want)
 assert frozen=={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
 write_json(folder/'results.json',dict(status='PASS',width=w,height=h,rows_per_strip=r,frames=6,pixels=6*w*h,encoded_bytes=sizes,external_readers=['Pillow','tifffile'],sources=frozen,board_tested=False))
 print(folder,flush=True)
if __name__=='__main__':
 for profile in [(1,1,1),(7,5,2),(16,12,4),(64,32,7)]:run(*profile)
