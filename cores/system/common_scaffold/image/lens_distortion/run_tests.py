"""Independent saturating fixed-point Brown-Conrady coordinate regression."""
from pathlib import Path
import sys, tempfile, random, json
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute

def oracle(x,y,c):
    fx,fy,cx,cy,ix,iy,k1,k2,k3,p1,p2=c
    overflow=False
    def sat(n):
        nonlocal overflow
        if n < -2147483648 or n > 2147483647: overflow=True
        return max(-2147483648,min(2147483647,n))
    def add(a,b): return sat(a+b)
    def mul(a,b,s=16):
        n=a*b
        return sat((-1 if n<0 else 1)*((abs(n)+(1<<(s-1)))>>s))
    xn=mul(add(x<<16,-cx),ix,30);yn=mul(add(y<<16,-cy),iy,30)
    xx=mul(xn,xn);yy=mul(yn,yn);xy=mul(xn,yn);r2=add(xx,yy)
    radial=add(mul(add(mul(add(mul(k3,r2),k2),r2),k1),r2),65536)
    xd=add(add(mul(xn,radial),add(mul(p1,xy),mul(p1,xy))),mul(p2,add(r2,add(xx,xx))))
    yd=add(add(mul(yn,radial),add(mul(p2,xy),mul(p2,xy))),mul(p1,add(r2,add(yy,yy))))
    sx=add(mul(fx,xd),cx);sy=add(mul(fy,yd),cy)
    return sx,sy,int(sx<0 or sy<0 or sx>6*65536 or sy>4*65536),int(overflow)

HEADER=r"""
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cv=0,sv=0,mr=0,dr=0;
reg signed [31:0] fx,fy,cx,cy,ix,iy,k1,k2,k3,p1,p2;
wire cr,sr,cd,err,mv,dv,busy,oob,ov,sof,eol,last;wire [3:0] ec;
wire signed [31:0] sx,sy;wire [15:0] x,y;
lens_distortion_map #(.WIDTH(7),.HEIGHT(5)) dut(.clk(clk),.rst_n(rst_n),.ce(ce),.cfg_valid(cv),.cfg_ready(cr),.cfg_fx(fx),.cfg_fy(fy),.cfg_cx(cx),.cfg_cy(cy),.cfg_invfx(ix),.cfg_invfy(iy),.cfg_k1(k1),.cfg_k2(k2),.cfg_k3(k3),.cfg_p1(p1),.cfg_p2(p2),.cfg_done(cd),.cfg_error(err),.error_code(ec),.start_valid(sv),.start_ready(sr),.m_src_x(sx),.m_src_y(sy),.m_x(x),.m_y(y),.m_oob(oob),.m_overflow(ov),.m_valid(mv),.m_ready(mr),.m_sof(sof),.m_eol(eol),.m_last(last),.done_valid(dv),.done_ready(dr),.busy(busy));
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
integer n;
reg [100:0] held;
task check(input signed [31:0] ex,ey,input eo,ev,input [15:0] px,py);begin
n=0;while(!mv)begin ce=n%11!=3;tick;n=n+1;if(n>2000)$fatal(1,"timeout");end
ce=1;
if({sx,sy,oob,ov,x,y,sof,eol,last}!=={ex,ey,eo,ev,px,py,(px==0&&py==0),(px==6),(px==6&&py==4)})begin $display("xy=%d,%d src=%d,%d expected=%d,%d flags=%b%b expected=%b%b",x,y,sx,sy,ex,ey,oob,ov,eo,ev);$fatal(1,"oracle");end
held={sx,sy,oob,ov,x,y,sof,eol,last};repeat(2)begin tick;if({sx,sy,oob,ov,x,y,sof,eol,last}!==held||!mv)$fatal(1,"stall");end
ce=0;mr=1;tick;if({sx,sy,oob,ov,x,y,sof,eol,last}!==held||!mv)$fatal(1,"CE");ce=1;tick;mr=0;
end endtask
initial begin #100000000;$fatal(1,"global timeout");end
initial begin @(negedge clk);tick;rst_n=1;tick;sv=1;tick;sv=0;if(ec!=1)$fatal(1,"unconfigured");
"""

def main():
    rng=random.Random(891)
    cases=[[8<<16,8<<16,3<<16,2<<16,1<<27,1<<27,0,0,0,0,0]]
    for i in range(45):
        cases.append([8<<16,16<<16,3<<16,2<<16,1<<27,1<<26,*[rng.randint(-25000,25000) for _ in range(5)]])
    cases += [[65536,65536,0,0,1<<30,1<<30,*([2147483647]*5)], [536870912,536870912,-536870912,536870912,1,1,*([-2147483648]*5)]]
    code=HEADER
    for c in cases:
        for name,value in zip('fx fy cx cy ix iy k1 k2 k3 p1 p2'.split(),c):code+=f"{name}=32'h{value&0xffffffff:08x};"
        code+='cv=1;sv=1;#1;if(sr)$fatal(1,"config priority");tick;cv=0;sv=0;if(!cd||err)$fatal(1,"configure");sv=1;tick;sv=0;\n'
        for y in range(5):
            for x in range(7):
                a,b,o,v=oracle(x,y,c)
                code+=f"check(32'h{a&0xffffffff:08x},32'h{b&0xffffffff:08x},1'b{o},1'b{v},16'd{x},16'd{y});\n"
        code+='if(!dv)$fatal(1,"done");repeat(2)begin tick;if(!dv||cr)$fatal(1,"done hold");end dr=1;tick;dr=0;\n'
    code+='fx=0;cv=1;tick;cv=0;if(!cd||!err||ec!=2)$fatal(1,"invalid config");sv=1;tick;sv=0;\n'
    for y in range(5):
        for x in range(7):
            a,b,o,v=oracle(x,y,cases[-1]);code+=f"check(32'h{a&0xffffffff:08x},32'h{b&0xffffffff:08x},1'b{o},1'b{v},16'd{x},16'd{y});\n"
    code+='dr=1;tick;dr=0;sv=1;tick;sv=0;repeat(9)tick;ce=0;rst_n=0;tick;if(mv||dv||cr||sr)$fatal(1,"reset");rst_n=1;ce=1;tick;sv=1;tick;sv=0;if(ec!=1)$fatal(1,"reset config");\n'
    code+='$display("PASS lens distortion 49 frames 1715 coordinates");$finish;end endmodule\n'
    with tempfile.TemporaryDirectory(prefix='lens_map_') as td:
        t=Path(td);(t/'tb.sv').write_text(code)
        execute(['iverilog','-g2012','-s','tb','-o',t/'sim',HERE/'lens_distortion_map.sv',t/'tb.sv'],HERE,t/'compile.log')
        output=execute(['vvp',t/'sim'],HERE,t/'sim.log')
        print(output.strip())
        import cv2,numpy as np
        errors=[]
        for c in cases[:46]:
            fx,fy,cx,cy,ix,iy,k1,k2,k3,p1,p2=c
            K=np.array([[fx/65536,0,cx/65536],[0,fy/65536,cy/65536],[0,0,1]],dtype=np.float64)
            D=np.array([k1,k2,p1,p2,k3],dtype=np.float64)/65536
            mx,my=cv2.initUndistortRectifyMap(K,D,None,K,(7,5),cv2.CV_32FC1)
            for yy in range(5):
                for xx in range(7):
                    a,b,o,v=oracle(xx,yy,c)
                    errors.extend([a/65536-float(mx[yy,xx]),b/65536-float(my[yy,xx])])
        (HERE/'opencv_comparison.json').write_text(json.dumps({'opencv':cv2.__version__,'frames':46,'coordinate_components':len(errors),'max_abs_pixels':float(np.max(np.abs(errors))),'rmse_pixels':float(np.sqrt(np.mean(np.square(errors))))},indent=2)+'\n')
        (HERE/'test_evidence.json').write_text(json.dumps({'frames':len(cases)+1,'coordinates':(len(cases)+1)*35,'result':output.strip()},indent=2)+'\n')
if __name__=='__main__':main()

