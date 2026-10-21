from pathlib import Path
import sys,tempfile,random,io,json
from PIL import Image
HERE=Path(__file__).resolve().parent
PACKAGE=HERE.parents[1]
sys.path.insert(0,str(PACKAGE/'integration'))
from tooling import execute
from test_jpeg_frame import SOURCES,expected_entropy,entropy_from_file
from test_jpeg_scan import header_and_tables
TB=r"""`timescale 1ns/1ps
module tb;
localparam W=WW,H=HH;
reg clk=0;always #5 clk=~clk;
reg rst=0,ce=1,tv=0,cv=0,start=0,sv=0,mr=1,dr=0,run=0;
reg[5:0]ti=0;reg[31:0]rnd=32'h156754;
reg[7:0]pixels[0:W*H*2-1];integer sent=0,frame=0,f,bytes=0;
wire tr,cr,cd,cerr,sr,pr,mv,ml,dv,busy;wire[7:0]md,err;
jpeg_gray_encoder #(.WIDTH(W),.HEIGHT(H)) dut(.clk(clk),.rst_n(rst),.ce(ce),
.table_valid(tv),.table_ready(tr),.table_index(ti),.table_value(8'd8),
.cfg_valid(cv),.cfg_ready(cr),.cfg_restart_interval(16'dRI),.cfg_done(cd),.cfg_error(cerr),
.start_valid(start),.start_ready(sr),.abort(1'b0),.s_data(pixels[frame*W*H+(sent<W*H?sent:0)]),
.s_valid(sv),.s_sof(sent==0),.s_eol(sent%W==W-1),.s_ready(pr),
.m_data(md),.m_valid(mv),.m_last(ml),.m_ready(mr),.done_valid(dv),.done_ready(dr),.error_code(err),.busy(busy));
always @(posedge clk)if(rst&&ce)begin
if(sv&&pr)sent<=sent+1;
if(mv&&mr)begin $fdisplay(f,"%02x",md);bytes=bytes+1;end
if(err||cerr)$fatal(1,"error %h",err);
end
always @(negedge clk)if(run)begin
rnd={rnd[30:0],rnd[31]^rnd[21]^rnd[1]^rnd[0]};ce=rnd[1]||rnd[2];mr=rnd[3]||rnd[4];sv=sent<W*H;
end
initial begin #100000000;$fatal(1,"timeout state=%d",dut.state);end
initial begin
$readmemh("pixels.hex",pixels);repeat(3)@(negedge clk);rst=1;
for(integer i=0;i<64;i=i+1)begin @(negedge clk);ti=i;tv=1;@(posedge clk);while(!tr)@(posedge clk);end
@(negedge clk);tv=0;cv=1;@(posedge clk);while(!cr)@(posedge clk);
@(negedge clk);cv=0;wait(cd);@(negedge clk);
for(integer k=0;k<2;k=k+1)begin
frame=k;sent=0;bytes=0;f=$fopen(k==0?"frame0.hex":"frame1.hex","w");start=1;
@(posedge clk);while(!sr)@(posedge clk);@(negedge clk);start=0;run=1;
wait(dv);@(negedge clk);run=0;ce=1;sv=0;mr=1;
if(sent!=W*H||bytes<300)$fatal(1,"incomplete");
$fclose(f);dr=1;@(posedge clk);@(negedge clk);dr=0;
end
$display("GRAY_FRAME PASS");$finish;end
endmodule
"""
def main():
 results=[]
 with tempfile.TemporaryDirectory(prefix='jpeg_gray_',dir='C:/Users/29668/AppData/Local/Temp') as tmp:
  p=Path(tmp)
  for w,h,ri in [(1,1,0),(8,8,0),(13,9,2),(16,16,1),(33,17,3)]:
   rng=random.Random(w*100+h);pixels=[rng.randrange(256) for _ in range(w*h*2)]
   (p/'pixels.hex').write_text(''.join(f'{x:02x}\n' for x in pixels))
   (p/'tb.sv').write_text(TB.replace('WW',str(w)).replace('HH',str(h)).replace('RI',str(ri)))
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,HERE/'jpeg_gray_encoder.sv',p/'tb.sv'],p,HERE/f'frame_{w}_{h}_{ri}_compile.log')
   execute(['vvp',p/'sim'],p,HERE/f'frame_{w}_{h}_{ri}_simulation.log')
   for f in range(2):
    data=bytes(int(x,16) for x in (p/f'frame{f}.hex').read_text().split())
    assert data[:20]==bytes.fromhex('ffd8ffe000104a46494600010100000100010000')
    image=Image.open(io.BytesIO(data));image.load();assert image.size==(w,h) and image.mode=='L'
    block=pixels[f*w*h:(f+1)*w*h]
    _,tables=header_and_tables([128]*64)
    assert entropy_from_file(data)==expected_entropy(block,w,h,ri,tables)
    error=max(abs(x-y) for x,y in zip(block,image.tobytes()));assert error<=16,error
    results.append(dict(width=w,height=h,frame=f,max_error=error,bytes=len(data)))
 (HERE/'frame_result.json').write_text(json.dumps(dict(status='PASS',board_tested=False,profiles=results),indent=2))
 print('PASS',len(results),'independently decoded frames')
if __name__=='__main__':main()
