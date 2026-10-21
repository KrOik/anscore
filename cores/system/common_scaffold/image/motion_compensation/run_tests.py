from pathlib import Path
import sys,random,tempfile,json,hashlib
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
HEADER=r'''
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,sv=0,sof=0,eol=0,vv=0,vi=0,start=0,release_v=0,mr=0;
reg [B-1:0] sp=0,fill=0;
reg [15:0] vx=0,vy=0,vw=0,vh=0;reg signed [15:0] dx=0,dy=0;
wire sr,vr,str,rr,mv,inv,ms,me,ml,dv,err;wire [B-1:0] mp;
wire [15:0] mx,my;wire [1:0] reason;wire [3:0] ec;wire [16:0] rc,vc;
motion_compensation #(.WIDTH(W),.HEIGHT(H),.BITS(B),.BLOCK_W(BW),.BLOCK_H(BH)) dut(
.clk(clk),.rst_n(rst_n),.ce(ce),.s_pixel(sp),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
.vector_valid(vv),.vector_ready(vr),.vector_x(vx),.vector_y(vy),.vector_width(vw),.vector_height(vh),.vector_dx(dx),.vector_dy(dy),.vector_invalid(vi),
.start_valid(start),.start_ready(str),.fill_pixel(fill),.release_valid(release_v),.release_ready(rr),
.m_valid(mv),.m_ready(mr),.m_pixel(mp),.m_x(mx),.m_y(my),.m_sof(ms),.m_eol(me),.m_last(ml),.m_invalid(inv),.m_reason(reason),
.done_valid(dv),.error(err),.error_code(ec),.reference_count(rc),.vector_count(vc));
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task pixel(input [B-1:0] p,input fs,le);begin
 while(!sr)tick;sp=p;sof=fs;eol=le;sv=1;tick;sv=0;
end endtask
task vector(input [15:0] px,py,pw,ph,input signed [15:0] ddx,ddy,input invalid);begin
 while(!vr)tick;vx=px;vy=py;vw=pw;vh=ph;dx=ddx;dy=ddy;vi=invalid;vv=1;tick;vv=0;
end endtask
task launch(input [B-1:0] f);begin fill=f;start=1;tick;start=0;fill=~f;end endtask
task expect_pixel(input [B-1:0] p,input [15:0] px,py,input [1:0] r);reg [B+37:0] held;integer k;reg [33:0] counts;begin
 counts={rc,vc};k=0;sv=1;vv=1;start=1;release_v=1;
 while(!mv)begin ce=k%4!=1;tick;k=k+1;if(sr||vr||str||rr||{rc,vc}!==counts)$fatal(1,"busy isolation");end
 sv=0;vv=0;start=0;release_v=0;ce=1;
 if({mp,mx,my,reason,inv,ms,me,ml}!=={p,px,py,r,(|r),(px==0&&py==0),(px==W-1),(px==W-1&&py==H-1)})begin
 $display("actual pixel=%d x=%d y=%d reason=%d expected=%d x=%d y=%d reason=%d",mp,mx,my,reason,p,px,py,r);$fatal(1,"oracle");end
 held={mp,mx,my,reason,inv,ms,me,ml};repeat(2)begin tick;if(!mv||{mp,mx,my,reason,inv,ms,me,ml}!==held)$fatal(1,"stall");end
 ce=0;mr=1;repeat(2)begin tick;if(!mv||{mp,mx,my,reason,inv,ms,me,ml}!==held||sr||vr||str||rr)$fatal(1,"CE");end
 ce=1;tick;mr=0;
end endtask
task release_frame;begin
 if(!dv||!rr)$fatal(1,"done missing");repeat(2)begin tick;if(!dv)$fatal(1,"done hold");end
 release_v=1;tick;release_v=0;if(rc||vc||ec||!str)$fatal(1,"release");
end endtask
initial begin #20000000;$fatal(1,"timeout");end
integer t,tx,ty;
initial begin @(negedge clk);tick;if(sr||vr||str||rr||mv||dv)$fatal(1,"reset");rst_n=1;tick;
sv=1;vv=1;launch(0);sv=0;vv=0;if(!err||ec!=1||rc||vc)$fatal(1,"start priority");
'''

def main():
 rng=random.Random(8192);results=[]
 for w,h,b,bw,bh in ((9,7,8,4,3),(1,9,10,3,4),(9,1,12,4,3),(1,1,8,1,1),(7,5,12,16,16)):
  blocks=[(x,y,min(bw,w-x),min(bh,h-y)) for y in range(0,h,bh) for x in range(0,w,bw)]
  tb=HEADER.replace('module tb;',f'module tb;localparam W={w},H={h},B={b},BW={bw},BH={bh};')
  for frame in range(24):
   pixels=[rng.randrange(1<<b) for _ in range(w*h)];fill=rng.randrange(1<<b)
   # Missing reference rejected without locking transaction.
   tb+="launch(0);if(!err||ec!=1||!str)$fatal(1,\"no reference\");\n"
   # Marker error rejected without increment; caller retries same expected pixel.
   tb+=f"pixel(0,0,1);if(!err||ec!=5||rc!=0)$fatal(1,\"marker reject\");\n"
   for i,p in enumerate(pixels):tb+=f"pixel({b}'d{p},1'b{int(i==0)},1'b{int(i%w==w-1)});\n"
   tb+="launch(0);if(!err||ec!=2||!str)$fatal(1,\"no vectors\");\n"
   tb+="vector(1,0,1,1,0,0,0);if(!err||ec!=3||vc!=0)$fatal(1,\"vector geometry\");\n"
   vectors=[]
   for j,(x,y,ww,hh) in enumerate(blocks):
    moves=((0,0),(1,0),(-1,0),(0,1),(0,-1),(1,1),(-1,-1),(32767,-32768),(-32768,32767))
    dx,dy=moves[frame] if frame<len(moves) else (rng.randrange(-w-1,w+2),rng.randrange(-h-1,h+2))
    invalid=frame==9 or (frame>9 and rng.random()<.2);vectors.append((dx,dy,invalid))
    tb+=f"vector({x},{y},{ww},{hh},16'h{dx&65535:x},16'h{dy&65535:x},1'b{int(invalid)});\n"
    if j==0 and len(blocks)>1:tb+=f"vector({x},{y},{ww},{hh},0,0,0);if(!err||ec!=3||vc!=1)$fatal(1,\"duplicate\");\n"
   tb+=f"pixel(0,0,0);if(!err||ec!=4||rc!={w*h})$fatal(1,\"reference overflow\");\n"
   tb+=f"vector(0,0,1,1,0,0,0);if(!err||ec!=4||vc!={len(blocks)})$fatal(1,\"vector overflow\");\n"
   tb+=f"launch({fill});\n"
   for y in range(h):
    for x in range(w):
     dx,dy,invalid=vectors[(y//bh)*((w+bw-1)//bw)+x//bw];xx,yy=x+dx,y+dy
     outside=not(0<=xx<w and 0<=yy<h);reason=int(invalid)|(int(outside)<<1)
     p=fill if reason else pixels[yy*w+xx]
     tb+=f"expect_pixel({p},{x},{y},2'd{reason});\n"
   tb+='release_frame;\n'
  tb+='''
 // Synchronous reset ignores CE, aborts pending load and resets protocol.
 pixel(0,1,W==1);ce=0;rst_n=0;tick;if(rc||vc||mv||sr||vr||str)$fatal(1,"reset CE0");
 rst_n=1;ce=1;tick;if(!str)$fatal(1,"reset recovery");
 // Reload then reset in compute and in output HOLD, checking stale RAM isolation.
 for(t=0;t<2;t=t+1)begin
  for(ty=0;ty<H;ty=ty+1)for(tx=0;tx<W;tx=tx+1)pixel(tx+ty,tx==0&&ty==0,tx==W-1);
  for(ty=0;ty<H;ty=ty+BH)for(tx=0;tx<W;tx=tx+BW)vector(tx,ty,W-tx<BW?W-tx:BW,H-ty<BH?H-ty:BH,0,0,0);
  launch(19);if(t==0)tick;else while(!mv)tick;
  ce=0;rst_n=0;tick;if(mv||dv||rc||vc||sr||vr||str)$fatal(1,"abort");rst_n=1;ce=1;tick;
 end
 $display("PASS motion compensation");$finish;end endmodule
'''
  tag=f'{w}x{h}_{b}_{bw}x{bh}'
  with tempfile.TemporaryDirectory(prefix='motion_comp_') as td:
   t=Path(td);(t/'tb.sv').write_text(tb)
   execute(['iverilog','-g2012','-s','tb','-o',t/'sim.vvp',HERE/'motion_compensation.sv',t/'tb.sv'],t,HERE/f'compile_{tag}.log')
   output=execute(['vvp',t/'sim.vvp'],t,HERE/f'test_{tag}.log');assert 'PASS motion compensation' in output
  results.append({'configuration':tag,'frames':24,'pixels':24*w*h,'status':'PASS'})
 (HERE/'evidence.json').write_text(json.dumps({'tests':results,'rtl_sha256':hashlib.sha256((HERE/'motion_compensation.sv').read_bytes()).hexdigest(),'board_validated':False},indent=2)+'\n');print(results)
 import test_block_motion_chain
 test_block_motion_chain.main()
 import test_geometry
 test_geometry.main()
if __name__=='__main__':main()
