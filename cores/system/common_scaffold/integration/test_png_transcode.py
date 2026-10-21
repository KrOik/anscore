"""External compressed PNG -> RTL decoder -> RTL encoder -> Pillow round trip."""
import hashlib
import struct
import tempfile
import zlib
from pathlib import Path
import numpy as np
from PIL import Image
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

TB=r'''module tb;
localparam W=32,H=24,N=W*H,F=4;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start=0,sv=0,sl=0,ack=0,mr=0;
reg[7:0]data_;reg[1:0]mode;
wire er,psr,ev,es,el,ed,ee,eb,dsr,pv,ps,pe,pl,dd,de,byte_ready;
wire[7:0]byte_,ec,dc,ctype;wire[23:0]rgb;
wire[31:0]obytes;wire[15:0]iw,ih;
png_encoder #(.WIDTH(W),.HEIGHT(H)) enc(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(er),.cfg_mode(mode),.abort(1'b0),
.s_pixel(rgb),.s_valid(pv),.s_sof(ps),.s_eol(pe),.s_last(pl),.s_ready(psr),
.m_data(byte_),.m_valid(ev),.m_sof(es),.m_last(el),.m_ready(mr),
.done_valid(ed),.done_ready(ack),.done_error(ee),.error_code(ec),.busy(eb),.output_bytes(obytes));
png_decoder #(.MAX_WIDTH(W),.MAX_HEIGHT(H),.MAX_COMPRESSED_BYTES(4096)) dec(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(dsr),.abort(1'b0),
.s_data(data_),.s_valid(sv),.s_ready(byte_ready),.s_last(sl),
.m_rgb(rgb),.m_valid(pv),.m_ready(psr),.m_sof(ps),.m_eol(pe),.m_last(pl),
.done_valid(dd),.done_ready(ack),.frame_error(de),.error_code(dc),
.image_width(iw),.image_height(ih),.image_color_type(ctype));
reg[7:0]input_bytes[0:@TOTAL@-1];reg[31:0]lengths[0:F-1];reg[23:0]expected[0:F*N-1];
integer i,f,base=0,got=0,bytes=0,tails=0,cycle=0,fd;reg take,he=0,hp=0;reg[9:0]et;reg[26:0]pt;reg[31:0]rng=471373;
always @(posedge clk)begin
cycle=cycle+1;if(cycle>30000000)$fatal(1,"timeout");
if(rst_n)begin
if(ed&&ee)$fatal(1,"encoder error %h",ec);if(dd&&de)$fatal(1,"decoder error %h",dc);
if(he&&(!ev||{byte_,es,el}!==et))$fatal(1,"encoded hold");he=ev&&!(ce&&mr);et={byte_,es,el};
if(hp&&(!pv||{rgb,ps,pe,pl}!==pt))$fatal(1,"decoded hold");hp=pv&&!(ce&&psr);pt={rgb,ps,pe,pl};
if(ce&&ev&&mr)begin
if(es!==(bytes==0)||tails!=0)$fatal(1,"byte boundary");if(el)tails=tails+1;$fwrite(fd,"%02x\n",byte_);bytes=bytes+1;end
if(ce&&pv&&psr)begin
if(got>=F*N||rgb!==expected[got]||ps!==(got%N==0)||pe!==(got%W==W-1)||pl!==(got%N==N-1))$fatal(1,"pixel %d",got);got=got+1;end
end end
task tick;begin @(negedge clk);#1;rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[3];mr=rng[2]|rng[5];end endtask
initial begin
$readmemh("input.mem",input_bytes);$readmemh("lengths.mem",lengths);$readmemh("expected.mem",expected);
repeat(3)@(negedge clk);#1;rst_n=1;
for(f=0;f<F;f=f+1)begin
fd=$fopen($sformatf("encoded_%0d.hex",f),"w");if(!fd)$fatal(1,"file");bytes=0;tails=0;
ce=1;mode=f%2;#1;if(!er||!dsr)$fatal(1,"start ready");start=1;@(negedge clk);#1;start=0;mode=3;
i=0;while(i<lengths[f])begin sv=1;data_=input_bytes[base+i];sl=i==lengths[f]-1;@(posedge clk);take=ce&&byte_ready;if(take)i=i+1;tick;end sv=0;base=base+lengths[f];
while(!ed||!dd)tick;
if(ee||de||ec||dc||got!=(f+1)*N||iw!=W||ih!=H||ctype!=((f%2)?2:0)||obytes!=bytes||tails!=1)$fatal(1,"completion f%0d enc%0d dec%0d pixels%0d",f,ec,dc,got);
$fclose(fd);ce=0;ack=1;repeat(3)@(negedge clk);#1;if(!ed||!dd)$fatal(1,"done hold");ce=1;@(negedge clk);#1;ack=0;
end
$display("PASS PNG_TRANSCODE frames=%d RGBpixels=%d",F,got);$finish;
end endmodule'''

def chunk(kind,data):
    return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)

def paeth(a,b,c):
    p=a+b-c;dist=(abs(p-a),abs(p-b),abs(p-c))
    return (a,b,c)[dist.index(min(dist))]

def encode_fixture(frame,color,strategy):
    h,w,_=frame.shape;bpp=3 if color else 1
    rows=frame.reshape(h,w*3) if color else frame[:,:,0]
    filtered=bytearray();previous=[0]*(w*bpp)
    for y,row in enumerate(rows):
        values=[int(v) for v in row];kind=y%5;filtered.append(kind)
        for x,value in enumerate(values):
            a=values[x-bpp] if x>=bpp else 0;b=previous[x];c=previous[x-bpp] if x>=bpp else 0
            predictor=(0,a,b,(a+b)//2,paeth(a,b,c))[kind]
            filtered.append((value-predictor)&255)
        previous=values
    obj=zlib.compressobj(0 if strategy=='stored' else 6,zlib.DEFLATED,15,8,
                          zlib.Z_FIXED if strategy=='fixed' else zlib.Z_HUFFMAN_ONLY)
    compressed=obj.compress(bytes(filtered))+obj.flush()
    btype=(compressed[2]>>1)&3
    assert btype=={'stored':0,'fixed':1,'dynamic':2}[strategy],(strategy,btype)
    header=struct.pack('>IIBBBBB',w,h,8,2 if color else 0,0,0,0)
    # Split inside zlib/DEFLATE headers and payload, including an empty IDAT.
    parts=[compressed[:1],b'',compressed[1:3],compressed[3:13],compressed[13:]]
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',header)+b''.join(chunk(b'IDAT',part) for part in parts)+chunk(b'IEND',b''),btype

def main():
    folder=evidence_dir('png_transcode');inputs=[];lengths=[];expected=[];frames=[];types=[]
    yy,xx=np.indices((24,32))
    for f,strategy in enumerate(('stored','fixed','dynamic','dynamic')):
        frame=np.stack(((xx*3+yy*5+f)%256,(xx*7+yy*2+f*13)%256,(xx+yy*11+f*31)%256),axis=2).astype(np.uint8)
        if not f%2:frame=np.repeat(frame[:,:,0:1],3,axis=2)
        encoded,btype=encode_fixture(frame,f%2,strategy);types.append(btype);inputs.extend(encoded);lengths.append(len(encoded));frames.append(frame)
        expected.extend((int(r)<<16)|(int(g)<<8)|int(b) for r,g,b in frame.reshape(-1,3))
    sources=[PACKAGE/'image/png_encoder/png_encoder.sv',PACKAGE/'image/png_decoder/png_decoder.sv']
    with tempfile.TemporaryDirectory(prefix='png_transcode_') as tmp:
        p=Path(tmp)
        for name,values in [('input',inputs),('lengths',lengths),('expected',expected)]:
            (p/(name+'.mem')).write_text('\n'.join(f'{v:x}' for v in values))
        (p/'tb.sv').write_text(TB.replace('@TOTAL@',str(len(inputs))))
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*sources,p/'tb.sv'],ROOT,folder/'compile.log')
        execute(['vvp',p/'sim'],p,folder/'simulation.log',timeout=300)
        for f,frame in enumerate(frames):
            file=p/f'{f}.png';file.write_bytes(bytes(int(v,16) for v in (p/f'encoded_{f}.hex').read_text().split()))
            with Image.open(file) as decoded:actual=np.asarray(decoded.convert('RGB'))
            assert np.array_equal(actual,frame),f
    write_json(folder/'results.json',dict(status='PASS',frames=4,pixels=3072,input_deflate_types=types,filters=[0,1,2,3,4],idat_chunks_per_frame=5,
        external_encoder='Python zlib stored/fixed/Huffman-only dynamic',external_decoder='Pillow',board_tested=False,
        sources={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}))
    print(folder,flush=True)

if __name__=='__main__':main()
