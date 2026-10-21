"""Brute-force 2-D oracle and actual SciPy EDT squared numeric cross-checks."""
from pathlib import Path
import sys,tempfile,json,random,hashlib
sys.dont_write_bytecode=True
import numpy as np
import scipy
from scipy.ndimage import distance_transform_edt
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute

HEADER=r'''
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,pixel=1,sv=0,sof=0,eol=0,mr=0,dr=0;
wire sr,mv,invalid,ms,me,ml,dv,de;wire [31:0] sqdist;
wire [15:0] nx,ny,x,y;
euclidean_distance #(.WIDTH(W),.HEIGHT(H)) dut(.clk(clk),.rst_n(rst_n),.ce(ce),
.s_pixel(pixel),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
.m_valid(mv),.m_ready(mr),.m_distance_squared(sqdist),.m_nearest_x(nx),.m_nearest_y(ny),.m_invalid(invalid),
.m_x(x),.m_y(y),.m_sof(ms),.m_eol(me),.m_last(ml),.done_valid(dv),.done_ready(dr),.done_error(de));
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task send(input p,input fs,le);begin while(!sr)tick;pixel=p;sof=fs;eol=le;sv=1;tick;sv=0;end endtask
task check(input [31:0] ed,input [15:0] ex,ey,enx,eny,input ei);reg [99:0] held;integer t;begin
 t=0;sv=1;sof=0;eol=0;
 while(!mv)begin ce=t%7!=2;tick;t=t+1;if(sr)$fatal(1,"busy ready");end
 sv=0;ce=1;
 if({sqdist,x,y,nx,ny,invalid,ms,me,ml}!=={ed,ex,ey,enx,eny,ei,(ex==0&&ey==0),(ex==W-1),(ex==W-1&&ey==H-1)})begin
 $display("actual d=%d x=%d y=%d nx=%d ny=%d inv=%b expected d=%d x=%d y=%d nx=%d ny=%d inv=%b",sqdist,x,y,nx,ny,invalid,ed,ex,ey,enx,eny,ei);$fatal(1,"oracle");end
 held={sqdist,x,y,nx,ny,invalid,ms,me,ml};repeat(2)begin tick;if(!mv||{sqdist,x,y,nx,ny,invalid,ms,me,ml}!==held)$fatal(1,"backpressure");end
 ce=0;mr=1;repeat(2)begin tick;if(!mv||{sqdist,x,y,nx,ny,invalid,ms,me,ml}!==held||sr)$fatal(1,"CE freeze");end
 ce=1;tick;mr=0;
end endtask
task finish_frame(input expected_error);begin
 if(!dv||de!==expected_error)$fatal(1,"done error");repeat(3)begin tick;if(!dv||de!==expected_error||sr)$fatal(1,"done hold");end
 dr=1;tick;dr=0;if(!sr||mv||dv)$fatal(1,"done handshake");
end endtask
task reset_dut;begin ce=0;rst_n=0;tick;if(mv||dv||sr||de)$fatal(1,"reset");rst_n=1;ce=1;tick;end endtask
initial begin #50000000;$fatal(1,"timeout");end
integer t;
initial begin @(negedge clk);tick;rst_n=1;tick;
if(dut.square(16'd65534)!==32'd4294705156||dut.square(16'd65535)!==32'd4294836225)$fatal(1,"wide square arithmetic");
'''

def oracle(frame,w,h):
 features=[(i%w,i//w) for i,p in enumerate(frame) if p==0]
 output=[]
 for y in range(h):
  for x in range(w):
   if not features:output.append((0xffffffff,65535,65535,True));continue
   d,_,nx,ny=min(((x-fx)**2+(y-fy)**2,fy*w+fx,fx,fy) for fx,fy in features)
   output.append((d,nx,ny,False))
 return output

def frames(w,h,rng):
 n=w*h
 result=[[0]*n,[1]*n]
 for position in sorted({0,w-1,(h-1)*w,n-1,(h//2)*w+w//2}):
  f=[1]*n;f[position]=0;result.append(f)
 # Cross, opposite corners, checkerboard: abundant nearest-feature ties.
 result.extend([[int(not(x==w//2 or y==h//2)) for y in range(h) for x in range(w)],
                [int(i not in (0,n-1)) for i in range(n)],
                [(x+y)%2 for y in range(h) for x in range(w)]])
 for density in (.1,.3,.5,.8,.95):
  for _ in range(2):result.append([int(rng.random()>density) for _ in range(n)])
 return result

def main():
 results=[];rng=random.Random(20261020)
 for w,h in ((9,7),(8,9),(1,17),(17,1),(1,1),(3,3),(257,1)):
  fs=frames(w,h,rng) if w<257 else [[0]+[1]*(w-1),[1]*(w-1)+[0],[1]*w]
  tb=HEADER.replace('module tb;',f'module tb;localparam W={w},H={h};');scipy_frames=0
  # Fail-stop malformed frame, then explicit acknowledgement recovery.
  tb+='send(1,0,W==1);finish_frame(1);\n'
  tb+='send(1,1,W!=1);finish_frame(1);\n'
  for f in fs:
   expected=oracle(f,w,h)
   if 0 in f:
    scipy_d=distance_transform_edt(np.asarray(f,dtype=np.uint8).reshape(h,w))
    actual=np.rint(scipy_d**2).astype(np.uint64).ravel().tolist()
    assert actual==[entry[0] for entry in expected],(w,h,'SciPy squared mismatch')
    scipy_frames+=1
   for i,p in enumerate(f):tb+=f"send(1'b{p},1'b{int(i==0)},1'b{int(i%w==w-1)});\n"
   for i,(d,nx,ny,invalid) in enumerate(expected):tb+=f"check(32'd{d},16'd{i%w},16'd{i//w},16'd{nx},16'd{ny},1'b{int(invalid)});\n"
   tb+='finish_frame(0);\n'
  tb+='''
 // Reset cancels capture, horizontal RMW work, vertical work and held output.
 send(1,1,W==1);reset_dut;
 for(t=0;t<W*H;t=t+1)send(t!=0,t==0,t%W==W-1);
 repeat(3)tick;reset_dut;
 for(t=0;t<W*H;t=t+1)send(t!=0,t==0,t%W==W-1);
 while(dut.state!=5)tick;reset_dut;
 for(t=0;t<W*H;t=t+1)send(t!=0,t==0,t%W==W-1);
 while(!mv)tick;reset_dut;
 $display("PASS exact squared Euclidean EDT");$finish;end endmodule
'''
  tag=f'{w}x{h}'
  with tempfile.TemporaryDirectory(prefix='euclidean_edt_') as td:
   p=Path(td);(p/'tb.sv').write_text(tb)
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim.vvp',HERE/'euclidean_distance.sv',p/'tb.sv'],p,HERE/f'compile_{tag}.log')
   out=execute(['vvp',p/'sim.vvp'],p,HERE/f'test_{tag}.log',timeout=120);assert 'PASS exact squared Euclidean EDT' in out
  results.append({'configuration':tag,'frames':len(fs),'output_pixels':w*h*len(fs),'scipy_numeric_frames':scipy_frames,'status':'PASS'})
 # Invalid geometry must fail before it can process a frame.
 for w,h in ((0,1),(1,0),(65536,1),(257,256)):
  with tempfile.TemporaryDirectory(prefix='euclidean_edt_guard_') as td:
   p=Path(td);(p/'tb.sv').write_text(f'module tb;euclidean_distance #(.WIDTH({w}),.HEIGHT({h})) dut();endmodule')
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim.vvp',HERE/'euclidean_distance.sv',p/'tb.sv'],p,HERE/f'guard_compile_{w}x{h}.log')
   try:execute(['vvp',p/'sim.vvp'],p,HERE/f'guard_{w}x{h}.log')
   except RuntimeError:pass
   else:raise AssertionError('invalid geometry accepted')
 accepted=[]
 for w,h in ((65535,1),(256,256)):
  with tempfile.TemporaryDirectory(prefix='euclidean_edt_limit_') as td:
   p=Path(td);(p/'tb.sv').write_text(f'module tb;euclidean_distance #(.WIDTH({w}),.HEIGHT({h})) dut();initial begin #1;$display("PASS accepted geometry");$finish;end endmodule')
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim.vvp',HERE/'euclidean_distance.sv',p/'tb.sv'],p,HERE/f'limit_compile_{w}x{h}.log')
   out=execute(['vvp',p/'sim.vvp'],p,HERE/f'limit_{w}x{h}.log');assert 'PASS accepted geometry' in out
   accepted.append(f'{w}x{h}')
 evidence={'status':'PASS','tests':results,'accepted_geometry_elaboration_only':accepted,'scipy_version':scipy.__version__,'no_feature_policy':'invalid distanceFFFFFFFF nearestFFFF, skip SciPy outside-feature behavior','tie':'lowest feature raster index, independently brute-force checked','rtl_sha256':hashlib.sha256((HERE/'euclidean_distance.sv').read_bytes()).hexdigest(),'board_validated':False}
 (HERE/'evidence.json').write_text(json.dumps(evidence,indent=2)+'\n');print(evidence)
if __name__=='__main__':main()
