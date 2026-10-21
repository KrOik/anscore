"""Wire complete hardware BMP encoder to full hardware BMP decoder."""
import hashlib
import tempfile
from pathlib import Path
import numpy as np
from PIL import Image
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

TB=r'''module tb;
localparam W=@W@,H=@H@,N=W*H,F=4;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start=0,sv=0,sof=0,eol=0,last=0,ack=0,mr=0;
reg[23:0]pixel;reg mode;
wire er,sr,ev,es,el,dr,ed,ee,eb,dsr,mv,ms,me,ml,dd,de;
wire[7:0]byte_,ec,dc;wire[23:0]rgb;
wire[31:0]obytes;wire[15:0]iw,ih;
bmp_encoder #(.WIDTH(W),.HEIGHT(H)) enc(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(er),.cfg_top_down(mode),.abort(1'b0),
.s_pixel(pixel),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_last(last),.s_ready(sr),
.m_data(byte_),.m_valid(ev),.m_sof(es),.m_last(el),.m_ready(dr),
.done_valid(ed),.done_ready(ack),.done_error(ee),.error_code(ec),.busy(eb),.output_bytes(obytes));
bmp_decoder #(.MAX_WIDTH(W),.MAX_HEIGHT(H)) dec(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(dsr),.abort(1'b0),
.s_data(byte_),.s_valid(ev),.s_ready(dr),.s_last(el),
.m_rgb(rgb),.m_valid(mv),.m_ready(mr),.m_sof(ms),.m_eol(me),.m_last(ml),
.done_valid(dd),.done_ready(ack),.frame_error(de),.error_code(dc),
.image_width(iw),.image_height(ih));
reg[23:0]pixels[0:F*N-1],expected[0:F*N-1];
integer i,f,got=0,bytes=0,cycle=0,fd;reg take,he=0,hm=0;reg[9:0]et;reg[26:0]mt;reg[31:0]rng=191371;
always @(posedge clk)begin
cycle=cycle+1;if(cycle>20000000)$fatal(1,"timeout");
if(rst_n)begin
if(ed&&ee)$fatal(1,"encoder error %h",ec);if(dd&&de)$fatal(1,"decoder error %h",dc);
if(he&&(!ev||{byte_,es,el}!==et))$fatal(1,"BMP byte hold");he=ev&&!(ce&&dr);et={byte_,es,el};
if(hm&&(!mv||{rgb,ms,me,ml}!==mt))$fatal(1,"RGB hold");hm=mv&&!(ce&&mr);mt={rgb,ms,me,ml};
if(ce&&ev&&dr)begin
if(es!==(bytes==0))$fatal(1,"BMP first byte marker");$fwrite(fd,"%02x\n",byte_);bytes=bytes+1;end
if(ce&&mv&&mr)begin
if(got>=F*N||rgb!==expected[got]||ms!==(got%N==0)||me!==(got%W==W-1)||ml!==(got%N==N-1))$fatal(1,"RGB %d got%h expected%h",got,rgb,expected[got]);got=got+1;end
end end
task tick;begin @(negedge clk);#1;rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[3];mr=rng[2]|rng[5];end endtask
initial begin
$readmemh("pixels.mem",pixels);$readmemh("expected.mem",expected);
repeat(3)@(negedge clk);#1;rst_n=1;
for(f=0;f<F;f=f+1)begin
fd=$fopen($sformatf("encoded_%0d.hex",f),"w");if(!fd)$fatal(1,"file");bytes=0;
ce=1;mode=f%2;#1;if(!er||!dsr)$fatal(1,"start ready");start=1;@(negedge clk);#1;start=0;mode=~mode;
i=0;while(i<N)begin sv=1;pixel=pixels[f*N+i];sof=i==0;eol=i%W==W-1;last=i==N-1;@(posedge clk);take=ce&&sr;if(take)i=i+1;tick;end sv=0;
while(!ed||!dd)tick;
if(ee||de||ec||dc||got!=(f+1)*N||iw!=W||ih!=H||obytes!=bytes)$fatal(1,"completion f%0d e%0d d%0d got%0d bytes%0d/%0d",f,ec,dc,got,obytes,bytes);
$fclose(fd);ce=0;ack=1;repeat(3)@(negedge clk);#1;if(!ed||!dd)$fatal(1,"done hold");ce=1;@(negedge clk);#1;ack=0;
end
$display("PASS BMP_CODEC frames=%d RGBpixels=%d",F,got);$finish;
end endmodule'''

def run(width,height):
    folder=evidence_dir('bmp_codec');rng=np.random.default_rng(width*53+height)
    pixels=[];expected=[];frames=[]
    for f in range(4):
        frame=rng.integers(0,256,(height,width,3),dtype=np.uint8)
        if f==2:frame[:]=[71,139,241]
        rgb=frame
        pixels.extend((int(r)<<16)|(int(g)<<8)|int(b) for r,g,b in frame.reshape(-1,3))
        expected.extend((int(r)<<16)|(int(g)<<8)|int(b) for r,g,b in rgb.reshape(-1,3));frames.append(rgb)
    sources=[PACKAGE/'image/bmp_encoder/bmp_encoder.sv',PACKAGE/'image/bmp_decoder/bmp_decoder.sv']
    with tempfile.TemporaryDirectory(prefix='bmp_codec_') as tmp:
        p=Path(tmp)
        for name,values in [('pixels',pixels),('expected',expected)]:
            (p/(name+'.mem')).write_text('\n'.join(f'{v:x}' for v in values))
        (p/'tb.sv').write_text(TB.replace('@W@',str(width)).replace('@H@',str(height)))
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*sources,p/'tb.sv'],ROOT,folder/'compile.log')
        execute(['vvp',p/'sim'],p,folder/'simulation.log',timeout=300)
        byte_counts=[]
        for f,frame in enumerate(frames):
            payload=bytes(int(v,16) for v in (p/f'encoded_{f}.hex').read_text().split())
            file=p/f'{f}.bmp';file.write_bytes(payload)
            with Image.open(file) as decoded:actual=np.asarray(decoded.convert('RGB'))
            assert np.array_equal(actual,frame),(f,actual,frame)
            import struct
            stride=(3*width+3)&~3
            assert payload[:2]==b'BM' and len(payload)==54+stride*height
            assert struct.unpack_from('<i',payload,22)[0]==(-height if f%2 else height)
            rows=frame if f%2 else frame[::-1]
            oracle=b''.join(row[:,::-1].tobytes()+bytes(stride-3*width) for row in rows)
            assert payload[54:]==oracle,(f,'BMP raster/padding oracle')
            byte_counts.append(len(payload))
    write_json(folder/'results.json',dict(status='PASS',width=width,height=height,frames=4,pixels=4*width*height,
        encoded_bytes=byte_counts,external_decoder='Pillow BMP reader',board_tested=False,
        sources={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}))
    print(folder,flush=True)

if __name__=='__main__':
    for geometry in ((1,1),(2,3),(3,4),(4,5),(7,5),(16,12)):run(*geometry)
