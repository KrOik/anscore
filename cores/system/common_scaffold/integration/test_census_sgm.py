"""Two grayscale raster frames -> two Census RTL cores -> four-path SGM RTL."""
import hashlib
import random
import tempfile
from pathlib import Path

import numpy as np
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

SOURCES = [PACKAGE/p for p in ('image/census/img_census_frame.sv',
                              'image/stereo_sgm/stereo_sgm.sv')]


def reference(left, right, w, h, radius, disparities, p1, p2):
    def census(image):
        values = np.zeros((h,w),dtype=np.uint64)
        border = np.ones((h,w),dtype=bool)
        for y in range(radius,h-radius):
            for x in range(radius,w-radius):
                bits = [int(image[(y+dy)*w+x+dx] < image[y*w+x])
                        for dy in range(-radius,radius+1) for dx in range(-radius,radius+1)
                        if dx or dy]
                values[y,x] = sum(v << k for k,v in enumerate(bits))
                border[y,x] = False
        return values,border
    l,lb = census(left)
    r,rb = census(right)
    cost = np.full((h,w,disparities),1024,dtype=np.int64)
    legal = np.zeros(cost.shape,dtype=bool)
    for y in range(h):
        for x in range(w):
            for d in range(min(x+1,disparities)):
                if not lb[y,x] and not rb[y,x-d]:
                    legal[y,x,d] = True
                    cost[y,x,d] = (int(l[y,x]) ^ int(r[y,x-d])).bit_count()
    total = np.zeros_like(cost)
    # Each path updates a whole disparity vector from an independent predecessor.
    for axis,reverse in ((1,False),(1,True),(0,False),(0,True)):
        path = np.zeros_like(cost)
        outer = range(h) if axis == 1 else range(w)
        length = w if axis == 1 else h
        for a in outer:
            prev = None
            for b in (range(length-1,-1,-1) if reverse else range(length)):
                y,x = (a,b) if axis == 1 else (b,a)
                if prev is None:
                    current = cost[y,x].copy()
                else:
                    lower = np.r_[10**8,prev[:-1]+p1]
                    upper = np.r_[prev[1:]+p1,10**8]
                    current = cost[y,x] + np.minimum.reduce(
                        [prev,lower,upper,np.full(disparities,prev.min()+p2)])-prev.min()
                path[y,x] = current
                prev = current
        total += path
    out = []
    for y in range(h):
        for x in range(w):
            candidates = np.where(legal[y,x],total[y,x],10**9)
            d = int(candidates.argmin())
            out.append((d,int(total[y,x,d]),0) if legal[y,x,d] else (0,16383,1))
    return out


TB = r'''
module tb;
localparam W=@W@,H=@H@,R=@R@,D=@D@,B=@B@,F=@F@,C=(2*R+1)*(2*R+1)-1;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,sv=0,sof=0,eol=0,start=0,ack=0,mr=0;
reg[B-1:0] lp,rp;
wire lr,rr,lv,rv,lb,rb,ls,rs,le,re,ld,rd,lf,rf,sr,start_ready;
wire[C-1:0] lc,rc;
img_census_frame #(.BITS(B),.WIDTH(W),.HEIGHT(H),.RADIUS(R)) left_census(
 .clk(clk),.rst_n(rst_n),.ce(ce),.cfg_valid(1'b0),.cfg_ready(),.cfg_threshold({B{1'b0}}),
 .s_data(lp),.s_valid(sv&&rr),.s_ready(lr),.s_sof(sof),.s_eol(eol),
 .m_descriptor(lc),.m_border(lb),.m_valid(lv),.m_ready(sr&&rv),.m_sof(ls),.m_eol(le),
 .done_valid(ld),.done_ready(ack),.frame_error(lf));
img_census_frame #(.BITS(B),.WIDTH(W),.HEIGHT(H),.RADIUS(R)) right_census(
 .clk(clk),.rst_n(rst_n),.ce(ce),.cfg_valid(1'b0),.cfg_ready(),.cfg_threshold({B{1'b0}}),
 .s_data(rp),.s_valid(sv&&lr),.s_ready(rr),.s_sof(sof),.s_eol(eol),
 .m_descriptor(rc),.m_border(rb),.m_valid(rv),.m_ready(sr&&lv),.m_sof(rs),.m_eol(re),
 .done_valid(rd),.done_ready(ack),.frame_error(rf));
wire mv,ms,me,ml,mi,done,error;wire[2:0]ec;
wire[(D<=1?1:$clog2(D))-1:0] disparity;wire[13:0]score;
integer paired=0;
stereo_sgm #(.WIDTH(W),.HEIGHT(H),.DESC_BITS(C),.DISPARITIES(D)) sgm(
 .clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(start_ready),
 .cfg_p1(8'd3),.cfg_p2(8'd12),.s_left(lc),.s_right(rc),.s_left_border(lb),.s_right_border(rb),
 .s_valid(lv&&rv),.s_ready(sr),.s_sof(ls),.s_eol(le),.s_last(paired==W*H-1),
 .m_disparity(disparity),.m_score(score),.m_invalid(mi),.m_valid(mv),.m_ready(mr),
 .m_sof(ms),.m_eol(me),.m_last(ml),.done_valid(done),.done_ready(ack),.done_error(error),.error_code(ec));
reg[B-1:0] lefts[0:F*W*H-1],rights[0:F*W*H-1];reg[31:0] expected[0:F*W*H-1];
integer n=0,cycles=0,f,i;reg take,held=0;reg[31:0]token,rng=32'h45619caf;
always @(posedge clk)begin
 cycles=cycles+1;if(cycles>2000000)$fatal(1,"timeout frame=%0d n=%0d pair=%0d left=%0d right=%0d sgm=%0d",f,n,paired,left_census.state,right_census.state,sgm.state);
 if(rst_n)begin
  if(held&&(!mv||{disparity,score,mi,ms,me,ml}!==token))$fatal(1,"unstable");
  held=mv&&!(ce&&mr);token={disparity,score,mi,ms,me,ml};
  if(ce&&lv&&rv&&sr)begin
   if(ls!==rs||le!==re||ls!==(paired==0)||le!==(paired%W==W-1))$fatal(1,"Census pair alignment");
   paired<=paired+1;
  end
  if(ce&&mv&&mr)begin
   if(n>=F*W*H||{disparity,score,mi}!==expected[n])$fatal(1,"SGM pixel %0d got d%0d s%0d bad%0d expected %h",n,disparity,score,mi,expected[n]);
   if(ms!==(n%(W*H)==0)||me!==(n%W==W-1)||ml!==(n%(W*H)==W*H-1))$fatal(1,"SGM markers");
   n=n+1;
  end
 end
end
task tick;begin
 @(negedge clk);#1;rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
 ce=rng[0]||rng[3];mr=rng[1]||rng[5];
end endtask
initial begin
 $readmemh("left.hex",lefts);$readmemh("right.hex",rights);$readmemh("expected.hex",expected);
 repeat(3)@(negedge clk);#1;rst_n=1;
 for(f=0;f<F;f=f+1)begin
  ce=1;start=1;@(negedge clk);#1;start=0;
  i=0;
  while(i<W*H)begin
   sv=1;lp=lefts[f*W*H+i];rp=rights[f*W*H+i];sof=i==0;eol=i%W==W-1;
   @(posedge clk);take=ce&&lr&&rr;if(take)i=i+1;tick;
  end
  sv=0;
  while(!done||!ld||!rd)tick;
  if(n!=(f+1)*W*H||paired!=W*H||error||ec||lf||rf)$fatal(1,"completion");
  ce=1;ack=1;@(negedge clk);#1;ack=0;paired=0;
 end
 $display("CENSUS_SGM PASS frames=%0d pixels=%0d",F,n);$finish;
end
endmodule
'''


def run(bits,radius,folder):
    w,h,d = 13,9,6
    rng = random.Random(0x53474d + bits + radius)
    maximum = (1 << bits)-1
    fixtures = [([0]*(w*h),[0]*(w*h)),([maximum]*(w*h),[0]*(w*h))]
    for shift in (0,1,2,4):
        left = [rng.randrange(maximum+1) for _ in range(w*h)]
        right = [left[y*w+min(w-1,x+shift)] for y in range(h) for x in range(w)]
        fixtures.append((left,right))
    expected = [v for l,r in fixtures for v in reference(l,r,w,h,radius,d,3,12)]
    with tempfile.TemporaryDirectory(prefix='census_sgm_') as tmp:
        td = Path(tmp)
        for name,values in [('left.hex',[v for l,r in fixtures for v in l]),
                            ('right.hex',[v for l,r in fixtures for v in r]),
                            ('expected.hex',[(a << 15) | (s << 1) | bad for a,s,bad in expected])]:
            (td/name).write_text(''.join(f'{v:x}\n' for v in values),encoding='ascii')
        tb = TB
        for key,value in dict(W=w,H=h,R=radius,D=d,B=bits,F=len(fixtures)).items():
            tb = tb.replace('@'+key+'@',str(value))
        (td/'tb.sv').write_text(tb,encoding='utf-8')
        label = f'b{bits}_r{radius}'
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,folder/f'{label}_compile.log')
        result = execute(['vvp',td/'sim'],td,folder/f'{label}_simulation.log',timeout=180)
        assert 'CENSUS_SGM PASS' in result,result
    return dict(bits=bits,radius=radius,frames=len(fixtures),pixels=len(expected),status='PASS')


if __name__ == '__main__':
    folder = evidence_dir('census_sgm')
    rows = [run(b,r,folder) for b,r in ((8,1),(12,2))]
    write_json(folder/'results.json',dict(status='PASS',results=rows,board_tested=False,
        rtl_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}))
    print(folder,flush=True)
