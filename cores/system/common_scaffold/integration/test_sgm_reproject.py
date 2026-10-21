"""Actual Census SGM disparity stream -> general-Q 3D reconstruction RTL."""
import hashlib
import importlib.util
import random
import tempfile
from pathlib import Path

from tooling import PACKAGE,ROOT,evidence_dir,execute,write_json

SOURCES = [PACKAGE/p for p in ('image/stereo_sgm/stereo_sgm.sv',
                              'image/disparity_reproject/disparity_reproject.sv')]
spec = importlib.util.spec_from_file_location('frozen_sgm_oracle',PACKAGE/'image/stereo_sgm/run_tests.py')
sgm_reference = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sgm_reference)


def reproject(x,y,d,bad,q):
    if bad:
        return 1 << 96
    vector = [x,y,d,1]
    h = [sum(q[row*4+c]*vector[c] for c in range(4)) for row in range(4)]
    if not h[3]:
        return (1 << 96) | (1 << 97)
    saturated = 0
    xyz = []
    for axis in range(3):
        n = abs(h[axis]) << 12
        den = abs(h[3])
        value,remainder = divmod(n,den)
        value += 2*remainder >= den
        if (h[axis] < 0) != (h[3] < 0):
            value = -value
        if not -(1 << 31) <= value < (1 << 31):
            saturated |= 1 << axis
            value = max(-(1 << 31),min((1 << 31)-1,value))
        xyz.append(value & 0xffffffff)
    return (xyz[0] | (xyz[1] << 32) | (xyz[2] << 64) | (int(bool(saturated)) << 96)
            | (int(h[3] < 0) << 98) | (saturated << 99))


TB = r'''
module tb;
localparam W=@W@,H=@H@,D=@D@,F=@F@,N=W*H;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start=0,sv=0,sof=0,eol=0,last=0,lb=0,rb=0,mr=0,ack=0;
reg[23:0]l,r;wire sr,sg_start_ready,sgv,sg_sof,sg_eol,sg_last,sg_bad,sg_done,sg_error;
wire[$clog2(D)-1:0] disparity;wire[13:0] cost;wire[2:0] sg_code;
wire pr;
stereo_sgm #(.WIDTH(W),.HEIGHT(H),.DESC_BITS(24),.DISPARITIES(D))sgm(
 .clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(sg_start_ready),.cfg_p1(8'd3),.cfg_p2(8'd15),
 .s_left(l),.s_right(r),.s_left_border(lb),.s_right_border(rb),.s_valid(sv),.s_ready(sr),.s_sof(sof),.s_eol(eol),.s_last(last),
 .m_disparity(disparity),.m_score(cost),.m_invalid(sg_bad),.m_valid(sgv),.m_ready(pr),
 .m_sof(sg_sof),.m_eol(sg_eol),.m_last(sg_last),.done_valid(sg_done),.done_ready(ack),.done_error(sg_error),.error_code(sg_code));
reg cv=0,commit=0;reg[3:0]ci;reg signed[31:0]cq;
wire cr,ccr,cfge,psr,mv,ms,me,ml,bad,wzero,wnegative,done,error;
wire[2:0]sat,code;wire signed[31:0]mx,my,mz;
wire signed[23:0] signed_disparity={{(24-$clog2(D)){1'b0}},disparity};
disparity_reproject #(.WIDTH(W),.HEIGHT(H),.DISP_FRAC(0))projection(
 .clk(clk),.rst_n(rst_n),.ce(ce),.cfg_valid(cv),.cfg_ready(cr),.cfg_index(ci),.cfg_value(cq),
 .cfg_commit_valid(commit),.cfg_commit_ready(ccr),.cfg_error(cfge),.start_valid(start),.start_ready(psr),
 .s_disparity(signed_disparity),.s_invalid(sg_bad),.s_valid(sgv),.s_ready(pr),
 .s_sof(sg_sof),.s_eol(sg_eol),.s_last(sg_last),
 .m_x(mx),.m_y(my),.m_z(mz),.m_invalid(bad),.m_wzero(wzero),.m_wnegative(wnegative),.m_saturated(sat),
 .m_valid(mv),.m_ready(mr),.m_sof(ms),.m_eol(me),.m_last(ml),
 .done_valid(done),.done_ready(ack),.done_error(error),.error_code(code));
reg[23:0]ls[0:F*N-1],rs[0:F*N-1];reg lbs[0:F*N-1],rbs[0:F*N-1];
reg[101:0]expected[0:F*N-1];reg[31:0]matrices[0:F*16-1];
integer n=0,paired=0,cy=0,f,i;reg take,held=0;reg[104:0]token;reg[31:0]rng=32'h29af4781;
always @(posedge clk)begin
 cy=cy+1;if(cy>2000000)$fatal(1,"timeout");
 if(rst_n)begin
  if(held&&(!mv||{sat,wnegative,wzero,bad,mz,my,mx,ms,me,ml}!==token))$fatal(1,"XYZ stall");
  held=mv&&!(ce&&mr);token={sat,wnegative,wzero,bad,mz,my,mx,ms,me,ml};
  if(ce&&sgv&&pr)paired=paired+1;
  if(ce&&mv&&mr)begin
   if(n>=F*N||{sat,wnegative,wzero,bad,mz,my,mx}!==expected[n])$fatal(1,"3D result %0d got %h expected %h",n,{sat,wnegative,wzero,bad,mz,my,mx},expected[n]);
   if(ms!==(n%N==0)||me!==(n%W==W-1)||ml!==(n%N==N-1))$fatal(1,"XYZ markers");
   n=n+1;
  end
 end
end
task tick;begin @(negedge clk);#1;rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]||rng[4];mr=rng[2]||rng[3];end endtask
initial begin
 $readmemh("left.hex",ls);$readmemh("right.hex",rs);$readmemh("lb.hex",lbs);$readmemh("rb.hex",rbs);
 $readmemh("expected.hex",expected);$readmemh("q.hex",matrices);
 repeat(3)@(negedge clk);#1;rst_n=1;
 for(f=0;f<F;f=f+1)begin
  // Configuration is deliberately sent with CE=1, computation subsequently stalls.
  ce=1;for(i=0;i<16;i=i+1)begin ci=i;cq=matrices[f*16+i];cv=1;@(negedge clk);#1;if(!cr)$fatal(1,"Q write");end
  cv=0;commit=1;@(negedge clk);#1;commit=0;#1;if(cfge||!psr||!sg_start_ready)$fatal(1,"Q commit");
  start=1;@(negedge clk);#1;start=0;
  i=0;while(i<N)begin
   sv=1;l=ls[f*N+i];r=rs[f*N+i];lb=lbs[f*N+i];rb=rbs[f*N+i];sof=i==0;eol=i%W==W-1;last=i==N-1;
   @(posedge clk);take=ce&&sr;if(take)i=i+1;tick;
  end
  sv=0;while(!done||!sg_done)tick;
  if(n!=(f+1)*N||paired!=(f+1)*N||error||code||sg_error||sg_code)$fatal(1,"3D completion");
  ce=1;ack=1;@(negedge clk);#1;ack=0;
 end
 $display("SGM_REPROJECT PASS frames=%0d pixels=%0d",F,n);$finish;
end
endmodule
'''


def main():
    folder = evidence_dir('sgm_reproject')
    w,h,d = 11,7,5
    rng = random.Random(0x33444950)
    q0 = [1,0,0,-5, 0,1,0,-3, 0,0,0,16, 0,0,.5,0]
    q1 = [1,.25,.5,-2, -.5,1,.125,3, .25,.5,2,16, .5,-.25,.5,-1]
    fixtures = []
    for mode,q in enumerate((q0,q0,q0,q1,[-v for v in q1])):
        left = [rng.getrandbits(24) for _ in range(w*h)]
        right = [left[y*w+min(w-1,x+2)] for y in range(h) for x in range(w)]
        lb = [int(mode==2 or (mode==1 and i//w==0)) for i in range(w*h)]
        rb = [int(mode==2) for _ in left]
        qi = [round(v*65536) for v in q]
        matched,_,_ = sgm_reference.oracle(left,right,lb,rb,w,h,d,3,15)
        expected = [reproject(i%w,i//w,disparity,bad,qi) for i,(disparity,_,bad) in enumerate(matched)]
        fixtures.append((left,right,lb,rb,qi,expected))
    with tempfile.TemporaryDirectory(prefix='sgm_reproject_') as tmp:
        td = Path(tmp)
        for filename,index in [('left.hex',0),('right.hex',1),('lb.hex',2),('rb.hex',3),('q.hex',4),('expected.hex',5)]:
            (td/filename).write_text(''.join(f'{v & ((1<<102)-1):x}\n' if index==5 else f'{v & 0xffffffff:x}\n'
                                           for case in fixtures for v in case[index]),encoding='ascii')
        tb = TB
        for key,value in dict(W=w,H=h,D=d,F=len(fixtures)).items():
            tb = tb.replace('@'+key+'@',str(value))
        (td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,folder/'compile.log')
        log = execute(['vvp',td/'sim'],td,folder/'simulation.log',timeout=180)
        assert 'SGM_REPROJECT PASS' in log,log
    write_json(folder/'results.json',dict(status='PASS',frames=len(fixtures),pixels=w*h*len(fixtures),
        full_general_q=True,board_tested=False,
        sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}))
    print(folder,flush=True)


if __name__ == '__main__':
    main()
