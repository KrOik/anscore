from pathlib import Path
import sys,tempfile,random,struct,io,json,hashlib
from PIL import Image
H=Path(__file__).resolve().parent;PACKAGE=H.parents[1]
sys.path.insert(0,str(PACKAGE/'integration'))
from tooling import execute
TB=r"""`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg randomize=1;reg rst=0,ce=1,start=0,sv=0,mr=0,dr=0;reg[31:0]rnd=123456;
reg[7:0]data[0:LEN-1];integer sent=0,received=0,f;
wire sr,ready,mv,ms,me,ml,dv,busy;wire[23:0]rgb;wire[7:0]error;wire[15:0]w,h;
bmp_indexed_decoder dut(.clk(clk),.rst_n(rst),.ce(ce),.start(start),.abort(1'b0),.start_ready(sr),
.s_data(data[sent<LEN?sent:0]),.s_valid(sv),.s_last(sent==LEN-1),.s_ready(ready),
.m_rgb(rgb),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_last(ml),.m_ready(mr),
.done_valid(dv),.done_ready(dr),.error_code(error),.width(w),.height(h),.busy(busy));
reg held=0;reg[26:0]previous;
always @(posedge clk)if(rst)begin
if(held&&{rgb,ms,me,ml}!==previous)$fatal(1,"unstable output");
held=mv&&!(ce&&mr);previous={rgb,ms,me,ml};
if(ce&&sv&&ready)sent<=sent+1;
if(ce&&mv&&mr)begin
if(ms!=(received==0)||me!=(received%w==w-1)||ml!=(received==w*h-1))$fatal(1,"markers");
$fdisplay(f,"%06x",rgb);received=received+1;end
end
always @(negedge clk)if(randomize)begin rnd={rnd[30:0],rnd[31]^rnd[21]^rnd[1]^rnd[0]};ce=rnd[0]||rnd[1];mr=rnd[4]||rnd[5];sv=sent<LEN;end
initial begin #50000000;$fatal(1,"timeout state=%d pos=%d",dut.state,dut.pos);end
initial begin
f=$fopen("out.hex","w");$readmemh("input.hex",data);repeat(3)@(posedge clk);@(negedge clk);#1;rst=1;start=1;
@(posedge clk);while(!(ce&&sr))@(posedge clk);@(negedge clk);#1;start=0;
wait(dv);@(negedge clk);#1;
if(error!=ERR)$fatal(1,"wrong error expected %h actual %h",ERR,error);
if(ERR==0&&(received!=w*h||sent!=LEN))$fatal(1,"incomplete");
randomize=0;ce=0;dr=1;repeat(4)@(posedge clk);if(!dv)$fatal(1,"done CE");
@(negedge clk);#1;ce=1;@(posedge clk);@(negedge clk);#1;if(dv)$fatal(1,"done ack");
$fclose(f);$display("BMP_INDEX PASS");$finish;end
endmodule
"""
def palette(n):return [(i*71%256,i*47%256,i*131%256) for i in range(n)]
def bmp(w,h,bpp,rows=None,compression=0,payload=None,top=False,n=None,gap=0):
 n=n or (1<<bpp);pal=palette(n)
 if payload is None:
  payload=bytearray()
  for row in (rows if top else rows[::-1]):
   bits=''.join(format(i,f'0{bpp}b') for i in row);bits+='0'*((-len(bits))%8)
   raw=bytes(int(bits[i:i+8],2) for i in range(0,len(bits),8));payload+=raw+b'\x00'*((-len(raw))%4)
 offset=54+4*n+gap
 data=struct.pack('<2sIHHI',b'BM',offset+len(payload),0,0,offset)+struct.pack('<IiiHHIIiiII',40,w,-h if top else h,1,bpp,compression,len(payload),0,0,n,0)
 data+=b''.join(bytes((b,g,r,0)) for r,g,b in pal)+bytes(gap)+payload
 return data,pal

def run(label,data,expected=None,error=0):
 with tempfile.TemporaryDirectory(prefix='bmp_index_') as tmp:
  p=Path(tmp);(p/'input.hex').write_text(''.join(f'{x:02x}\n' for x in data));(p/'tb.sv').write_text(TB.replace('LEN',str(len(data))).replace('ERR',str(error)))
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'bmp_indexed_decoder.sv',p/'tb.sv'],p,H/f'{label}_compile.log')
  out=execute(['vvp',p/'sim'],p,H/f'{label}_simulation.log');assert 'BMP_INDEX PASS' in out
  rgb=[int(x,16) for x in (p/'out.hex').read_text().split()]
  if expected is not None:assert rgb==expected,(label,rgb[:10],expected[:10])
 return dict(profile=label,bytes=len(data),pixels=len(rgb),expected_error=error,status='PASS')
def packed(rows,pal):return [(pal[i][0]<<16)|(pal[i][1]<<8)|pal[i][2] for row in rows for i in row]

def main():
 results=[];rng=random.Random(967)
 for bpp in (1,4,8):
  for w,h in [(1,1),(3,2),(7,5),(16,3),(63,7)]:
   for top in (False,True):
    rows=[[rng.randrange(1<<bpp) for _ in range(w)] for _ in range(h)];data,pal=bmp(w,h,bpp,rows=rows,top=top,gap=3)
    im=Image.open(io.BytesIO(data)).convert('RGB');assert list(im.get_flattened_data())==[pal[i] for row in rows for i in row]
    results.append(run(f'rgb_{bpp}_{w}_{h}_{int(top)}',data,packed(rows,pal)))
 for bpp,comp,payload,rows in [
 (8,1,bytes([3,1,0,3,2,3,4,0,0,0,0,2,2,0,4,5,0,0,0,6,6,7,8,9,10,11,0,0,0,1]),[[6,7,8,9,10,11],[0,0,5,5,5,5],[1,1,1,2,3,4]]),
 (4,2,bytes([3,0x12,0,3,0x34,0x50,0,0,0,2,2,0,4,0x67,0,0,0,6,0x89,0xab,0xcd,0,0,0,0,1]),[[8,9,10,11,12,13],[0,0,6,7,6,7],[1,2,1,3,4,5]])]:
  data,pal=bmp(6,3,bpp,compression=comp,payload=payload);im=Image.open(io.BytesIO(data)).convert('RGB');assert list(im.get_flattened_data())==[pal[i] for row in rows for i in row],bpp
  results.append(run(f'rle_{bpp}_all_commands',data,packed(rows,pal)))
 (H/'transaction_result.json').write_text(json.dumps(dict(status='PASS',profiles=results),indent=2));print('PASS',len(results))
if __name__=='__main__':main()
