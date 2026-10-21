"""Raster -> block -> real encoder -> RTL headers: independent JPEG decode."""
from pathlib import Path
import hashlib,io,random,tempfile
from PIL import Image
from tooling import ROOT,PACKAGE,execute,evidence_dir,write_json
from test_jpeg_scan import SOURCES as CORES,header_and_tables,oracle

SOURCES=CORES+[
 PACKAGE/'dsp/jpeg_scan_control/jpeg_entropy_scan_controller.v',
 PACKAGE/'dsp/jpeg_grayscale/jpeg_grayscale_scan.sv',
 PACKAGE/'dsp/jpeg_headers/jpeg_gray_headers.sv',
 PACKAGE/'image/raster_blocks/img_raster_blocks.v']

TB='''`timescale 1ns/1ps
module tb;
localparam integer WIDTH=WW,HEIGHT=HH,INTERVAL=RI,BLOCKS=((WIDTH+7)/8)*((HEIGHT+7)/8);
reg clk=0;always #5 clk=~clk;
reg rst=0,ce=1,run=0,sv=0,ready=0,tv=0,cv=0,start=0,cmdv=0;
reg[1:0]cmd=0;reg[5:0]ti=0;
reg[7:0]pixels[0:WIDTH*HEIGHT-1];integer sent=0,fileout,phase=0,bytecount=0;
reg accepted=0,qseen=0,hseen=0;reg[31:0]rnd=32'h672feba;
wire rbready,rv,rf,rl,rfirst,rlast,rframe,rerror,rready;wire[7:0]rd;
img_raster_blocks #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) raster(.clk(clk),.rst_n(rst),.clk_en(ce),
.s_data(pixels[sent<WIDTH*HEIGHT?sent:0]),.s_valid(sv),.s_ready(rbready),
.s_sof(sent==0),.s_eol(sent%WIDTH==WIDTH-1),.s_block_first(1'b0),.s_block_last(1'b0),
.m_data(rd),.m_valid(rv),.m_ready(rready),.m_sof(rf),.m_eol(rl),
.m_block_first(rfirst),.m_block_last(rlast),.m_frame_last(rframe),.protocol_error(rerror),.error_pulse());
wire qtr,qcr,qdone,qerr,sr,done;wire[7:0]error,scan_data;wire scan_valid;
jpeg_grayscale_scan encoder(.clk(clk),.rst_n(rst),.ce(ce),
.table_valid(tv),.table_ready(qtr),.table_index(ti),.table_value(8'd8),
.cfg_valid(cv),.cfg_ready(qcr),.cfg_done(qdone),.cfg_error(qerr),
.start_valid(start),.start_ready(sr),.cfg_total_blocks(BLOCKS),.cfg_restart_interval(INTERVAL),.abort(1'b0),
.s_data(rd),.s_valid(rv),.s_ready(rready),.s_block_first(rfirst),.s_block_last(rlast),.s_frame_last(rframe),
.m_data(scan_data),.m_valid(scan_valid),.m_ready(ready&&phase==1),.m_marker(),.m_scan_last(),
.done_valid(done),.done_ready(1'b1),.error_code(error),.busy());
wire htr,hcr,hdone,herr,cmdr,cmdd,cmde,hv;wire[7:0]hd;
jpeg_gray_headers headers(.clk(clk),.rst_n(rst),.ce(ce),
.table_valid(tv),.table_ready(htr),.table_index(ti),.table_value(8'd8),
.cfg_valid(cv),.cfg_ready(hcr),.cfg_width(16'dWW),.cfg_height(16'dHH),.cfg_restart_interval(16'dRI),
.cfg_done(hdone),.cfg_error(herr),.cmd_valid(cmdv),.cmd_ready(cmdr),.cmd(cmd),.rst_index(3'd0),
.m_data(hd),.m_valid(hv),.m_last(),.m_ready(ready&&phase!=1),.cmd_done(cmdd),.cmd_error(cmde),.busy());
always @(posedge clk)if(rst)begin
 if(ce&&qdone)qseen<=1;if(ce&&hdone)hseen<=1;
 accepted=ce&&sv&&rbready;if(accepted)sent<=sent+1;
 if(ce&&ready)begin
 if(phase==1&&scan_valid)begin $fdisplay(fileout,"%02x",scan_data);bytecount=bytecount+1;end
 if(phase!=1&&hv)begin $fdisplay(fileout,"%02x",hd);bytecount=bytecount+1;end
 end
end
always @(negedge clk)if(run)begin
 if(rerror||error||qerr||herr||cmde)$fatal(1,"frame errors raster=%b encoder=%h",rerror,error);
 rnd={rnd[30:0],rnd[31]^rnd[21]^rnd[1]^rnd[0]};ce=rnd[1]||rnd[3];ready=rnd[7];
 if(!sv||accepted)sv=phase==1&&sent<WIDTH*HEIGHT&&(rnd[2]||rnd[5]);
end
task command(input[1:0]operation);
begin
 @(negedge clk);#1;cmd=operation;cmdv=1;
 @(posedge clk);while(!(ce&&cmdr))@(posedge clk);
 @(negedge clk);#1;cmdv=0;
 wait(cmdd&&ce);@(posedge clk);@(negedge clk);#1;
end endtask
initial begin #20000000;$fatal(1,"timeout");end
initial begin
$readmemh("pixels.hex",pixels);fileout=$fopen("file.hex","w");
repeat(3)@(negedge clk);#1;rst=1;
for(integer i=0;i<64;i=i+1)begin
@(negedge clk);#1;ti=i;tv=1;
@(posedge clk);while(!(qtr&&htr))@(posedge clk);
end
@(negedge clk);#1;tv=0;cv=1;@(negedge clk);#1;cv=0;
wait(qseen&&hseen);repeat(2)@(negedge clk);
ready=1;command(0);
phase=1;start=1;@(posedge clk);while(!sr)@(posedge clk);
@(negedge clk);#1;start=0;run=1;
wait(done&&ce);@(posedge clk);@(negedge clk);#1;phase=2;
command(1);run=0;
if(sent!=WIDTH*HEIGHT||error||bytecount<300)$fatal(1,"frame incomplete");
$fclose(fileout);$display("JPEG_FRAME PASS %0dx%0d restart=%0d bytes=%0d",WIDTH,HEIGHT,INTERVAL,bytecount);$finish;
end
endmodule
'''

def expected_entropy(pixels,width,height,interval,tables):
    blocks=[]
    for by in range((height+7)//8):
        for bx in range((width+7)//8):
            blocks.append([pixels[min(height-1,by*8+y)*width+min(width-1,bx*8+x)]
                           for y in range(8) for x in range(8)])
    bits='';dc=0;output=bytearray();restart=0
    def flush():
        nonlocal bits
        bits+='1'*((-len(bits))%8)
        for i in range(0,len(bits),8):
            value=int(bits[i:i+8],2);output.append(value)
            if value==255:output.append(0)
        bits=''
    for i,block in enumerate(blocks):
        new,dc=oracle(block,tables,dc,True);bits+=new
        if interval and (i+1)%interval==0 and i+1<len(blocks):
            flush();output.extend((255,0xd0+(restart%8)));restart+=1;dc=0
    flush();return bytes(output)

def entropy_from_file(data):
    offset=2
    while offset<len(data):
        assert data[offset]==255
        marker=data[offset+1];length=int.from_bytes(data[offset+2:offset+4],'big');offset+=2+length
        if marker==0xda:
            assert data[-2:]==b'\xff\xd9'
            return data[offset:-2]
    raise RuntimeError('SOS missing')

def main():
    folder=evidence_dir('jpeg_frame');results=[];rng=random.Random(191)
    hashes={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in SOURCES}
    with tempfile.TemporaryDirectory(prefix='jpeg_frame_') as temp:
        p=Path(temp)
        for width,height,interval in ((8,8,0),(16,16,1),(13,9,2),(1,1,1)):
            pixels=[rng.randrange(256) for _ in range(width*height)]
            (p/'pixels.hex').write_text(''.join(f'{v:02x}\n' for v in pixels),encoding='utf-8')
            tb=TB.replace('WW',str(width)).replace('HH',str(height)).replace('RI',str(interval))
            (p/'tb.sv').write_text(tb,encoding='utf-8');label=f'{width}x{height}_r{interval}'
            execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,folder/f'{label}_compile.log')
            text=execute(['vvp',p/'sim'],p,folder/f'{label}_sim.log')
            assert 'JPEG_FRAME PASS' in text
            data=bytes(int(v,16) for v in (p/'file.hex').read_text().split())
            _,tables=header_and_tables([128]*64)
            expected=expected_entropy(pixels,width,height,interval,tables)
            if entropy_from_file(data)!=expected:raise AssertionError(f'{label}: independent entropy mismatch')
            decoded=Image.open(io.BytesIO(data));decoded.load()
            assert decoded.size==(width,height)
            error=max(abs(a-b) for a,b in zip(pixels,decoded.tobytes()))
            if error>16:raise AssertionError(f'{label}: max pixel error {error}')
            (folder/f'{label}.jpg').write_bytes(data)
            results.append({'width':width,'height':height,'restart_interval':interval,'bytes':len(data),
                            'max_pixel_error':error,'status':'PASS'})
    for s in SOURCES:
        assert hashlib.sha256(s.read_bytes()).hexdigest()==hashes[str(s.relative_to(ROOT))]
    write_json(folder/'result.json',{'status':'PASS','fixtures':results,'sources':hashes,'board_tested':False})
    print(results);print(folder)
if __name__=='__main__':main()
