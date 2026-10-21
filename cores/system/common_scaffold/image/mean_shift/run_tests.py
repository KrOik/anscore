"""Exact integer joint-mode iteration reference, actual OpenCV comparison."""
from pathlib import Path
import sys,tempfile,json,hashlib
import numpy as np,cv2
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent;sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
def oracle(image,hs,hr,limit,epsilon):
    h,w,_=image.shape;out=[]
    for y in range(h):
        for x in range(w):
            center=[x,y,*map(int,image[y,x])];empty=False;converged=False
            for iteration in range(1,limit+1):
                members=[]
                for sy in range(max(0,center[1]-hs),min(h-1,center[1]+hs)+1):
                    for sx in range(max(0,center[0]-hs),min(w-1,center[0]+hs)+1):
                        pixel=list(map(int,image[sy,sx]))
                        if (sx-center[0])**2+(sy-center[1])**2<=hs*hs and sum((a-b)**2 for a,b in zip(pixel,center[2:]))<=hr*hr:members.append([sx,sy,*pixel])
                support=len(members)
                if not support:empty=True;break
                updated=[(sum(v[d] for v in members)+support//2)//support for d in range(5)]
                movement=max(abs(a-b) for a,b in zip(updated,center));center=updated
                if movement<=epsilon:converged=True;break
            out.append(dict(center=center,iterations=iteration,converged=converged,empty=empty,support=support))
    return out
def token(r,i,w,n):
    rgb=sum(int(v)<<(8*(2-j)) for j,v in enumerate(r['center'][2:]))
    return rgb|(r['center'][0]<<24)|(r['center'][1]<<30)|(r['iterations']<<36)|(r['support']<<44)|(r['converged']<<55)|(r['empty']<<56)|((i==0)<<57)|((i%w==w-1)<<58)|((i==n-1)<<59)
TB='''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=0,start_valid=0;wire start_ready;
reg [3:0] cfg_spatial_radius;reg [7:0]cfg_range_radius,cfg_max_iterations,cfg_epsilon;
reg [23:0]s_rgb;reg s_valid=0,s_sof=0,s_eol=0,s_last=0;wire s_ready;
wire [23:0]m_rgb;wire [7:0]m_iterations;wire m_converged,m_empty;wire [10:0]m_support;wire [5:0]m_mode_x,m_mode_y;
wire m_valid,m_sof,m_eol,m_last;reg m_ready=0;wire [10:0]converged_pixels,limited_pixels,empty_pixels;
wire done_valid,done_error,busy;reg done_ready=0;wire [3:0]error_code;
mean_shift_frame #(.WIDTH(W),.HEIGHT(H)) dut(.*);
reg [59:0]expected[0:N-1],held;reg stalled=0,stalls=0;reg [31:0]noise=32'h71639111;integer cycles=0,got=0,frame=0;
wire [59:0]actual={m_last,m_eol,m_sof,m_empty,m_converged,m_support,m_iterations,m_mode_y,m_mode_x,m_rgb};
always @(negedge clk)begin noise=noise^(noise<<13);noise=noise^(noise>>17);noise=noise^(noise<<5);
if(stalls)begin ce=noise[0]|noise[1];m_ready=noise[2]|noise[3];end end
always @(posedge clk)begin cycles=cycles+1;if(cycles>12000000)$fatal(1,"timeout frame%0d state%0d",frame,dut.state);
if(!rst_n)stalled=0;else begin if(stalled&&(!m_valid||actual!==held))$fatal(1,"unstable output");
stalled=m_valid&&!(ce&&m_ready);held=actual;
if(ce&&m_valid&&m_ready)begin if(got>=N||actual!==expected[got])$fatal(1,"pixel frame%0d pos%0d got%h expected%h",frame,got,actual,expected[got]);got=got+1;end end end
task tick;begin @(posedge clk);#1;end endtask
task ack;begin @(negedge clk);done_ready=1;@(posedge clk);while(!ce)@(posedge clk);#1;done_ready=0;end endtask
task begin_frame(input [3:0]hs,input [7:0]hr,lim,eps);begin
while(!start_ready)tick();@(negedge clk);cfg_spatial_radius=hs;cfg_range_radius=hr;cfg_max_iterations=lim;cfg_epsilon=eps;start_valid=1;
@(posedge clk);while(!start_ready)@(posedge clk);#1;start_valid=0;got=0;cfg_spatial_radius=0;cfg_range_radius=~hr;cfg_max_iterations=0;cfg_epsilon=~eps;end endtask
task send(input [23:0]p,input sof,eol,last);begin @(negedge clk);s_rgb=p;s_sof=sof;s_eol=eol;s_last=last;s_valid=1;
@(posedge clk);while(!s_ready)@(posedge clk);#1;s_valid=0;end endtask
initial begin tick();tick();rst_n=1;ce=1;m_ready=1;stalls=1;
BODY
$display("PASS cycles=%0d",cycles);$finish;end endmodule
'''
def vectors(image,results,w):
    n=len(results);return [f"expected[{i}]=60'h{token(r,i,w,n):x};" for i,r in enumerate(results)]
def feed(image,bad=0):
    h,w,_=image.shape;n=h*w;out=[]
    for i,p in enumerate(image.reshape(n,3)):
        rgb=sum(int(v)<<(8*(2-j)) for j,v in enumerate(p))
        out.append(f"send(24'h{rgb:x},1'b{int((i==0)^(bad==1 and i==0))},1'b{int((i%w==w-1)^(bad==2 and i==n-1))},1'b{int((i==n-1)^(bad==3 and i==n-1))});")
    return out
def run_profile(w,h,total,resets=False):
    rng=np.random.default_rng(w*133+h*17);n=w*h;body=[];comparisons=[];totals=dict(converged=0,limited=0,empty=0)
    for idx in range(total):
        image=rng.integers(0,256,(h,w,3),dtype=np.uint8)
        hs=[1,2,3,1,8,2][idx%6];hr=[0,30,255,100,255,15][idx%6];limit=[1,8,12,1,2,16][idx%6];eps=255 if idx%7==0 else 0
        if n==1024:hs=1;limit=2
        if idx%5==0:image[:]=77
        elif idx%5==1:image=(image%20+100).astype(np.uint8)
        elif idx%5==2:image[:]=0;image[:,w//2:]=[220,140,50]
        elif idx%5==3:image[:]=0;image[h//2,w//2]=[255,255,255]
        r=oracle(image,hs,hr,limit,eps)
        expected=np.array([v['center'][2:] for v in r],np.uint8).reshape(h,w,3)
        cv=cv2.pyrMeanShiftFiltering(image,float(hs),float(hr),maxLevel=0,termcrit=(cv2.TERM_CRITERIA_MAX_ITER|cv2.TERM_CRITERIA_EPS,limit,float(eps)))
        err=np.abs(expected.astype(int)-cv.astype(int))
        # Constant data must be exactly preserved by both algorithms; arbitrary
        # differences are reported because spatial kernel/centers differ.
        if idx%5==0:assert not err.any()
        converged=sum(v['converged'] for v in r);empty=sum(v['empty'] for v in r);limited=n-converged-empty
        for key,val in [('converged',converged),('limited',limited),('empty',empty)]:totals[key]+=val
        comparisons.append(dict(frame=idx,hs=hs,hr=hr,maxiter=limit,epsilon=eps,converged=converged,limited=limited,empty=empty,opencv_max_channel_difference=int(err.max()),opencv_mean_channel_difference=float(err.mean()),constant_exact=idx%5==0))
        body+=vectors(image,r,w);body.append(f"frame={idx};begin_frame(4'd{hs},8'd{hr},8'd{limit},8'd{eps});")
        bad=idx-total+4 if idx>=total-3 else 0;body+=feed(image,bad)
        body.append(f"while(!done_valid)tick();if(got!={n}||done_error!=1'b{int(bool(bad))}||error_code!={2 if bad else 0}||converged_pixels!={converged}||limited_pixels!={limited}||empty_pixels!={empty})$fatal(1,\"DONE/stats\");repeat(5)tick();if(!done_valid)$fatal(1,\"held DONE\");ack();")
        if idx==0:
            for hs0,lim in [(0,4),(9,4),(1,0)]:body.append(f"begin_frame(4'd{hs0},8'd0,8'd{lim},8'd0);while(!done_valid)tick();if(!done_error||error_code!=1||got||converged_pixels||limited_pixels||empty_pixels)$fatal(1,\"invalid config\");ack();")
    recovery=0
    if resets:
        image=rng.integers(100,120,(h,w,3),dtype=np.uint8);r=oracle(image,2,50,4,0);converged=sum(v['converged'] for v in r);empty=sum(v['empty'] for v in r)
        for phase in [1,2,6,9,15,19,20]:
            body.append("stalls=0;ce=1;m_ready=0;begin_frame(4'd2,8'd50,8'd4,8'd0);")
            if phase!=1:body+=feed(image)
            if phase==20:body+=vectors(image,r,w);body.append("m_ready=1;")
            body.append(f"while(dut.state!={phase})tick();@(negedge clk);ce=0;rst_n=0;tick();if(busy||m_valid||done_valid||start_ready||s_ready)$fatal(1,\"reset phase{phase}\");rst_n=1;ce=1;m_ready=1;")
            body+=vectors(image,r,w);body.append("begin_frame(4'd2,8'd50,8'd4,8'd0);");body+=feed(image)
            body.append(f"while(!done_valid)tick();if(got!={n}||done_error||converged_pixels!={converged}||empty_pixels!={empty})$fatal(1,\"recovery\");ack();");recovery+=1
    if n==1024:
        # Maximum radius on maximum RAM geometry: verify a real 17x17-bound
        # neighborhood and spatial-center movement, then reset held output.
        image=np.full((h,w,3),77,np.uint8);r=oracle(image,8,0,1,255)
        assert r[0]['center'][:2]!=[0,0]
        body+=vectors(image,r,w);body.append("stalls=0;ce=1;m_ready=0;begin_frame(4'd8,8'd0,8'd1,8'd255);");body+=feed(image)
        body.append("while(!m_valid)tick();if(actual!==expected[0])$fatal(1,\"maxradius center probe\");repeat(3)tick();@(negedge clk);ce=0;rst_n=0;tick();if(m_valid||busy||done_valid)$fatal(1,\"maxradius reset\");rst_n=1;ce=1;m_ready=1;")
        r=oracle(image,1,0,1,0);body+=vectors(image,r,w);body.append("begin_frame(4'd1,8'd0,8'd1,8'd0);");body+=feed(image)
        body.append(f"while(!done_valid)tick();if(got!={n}||done_error||converged_pixels!={n})$fatal(1,\"maxradius recovery\");ack();");recovery+=1
    tb=TB.replace('BODY','\n'.join(body)).replace('.WIDTH(W),.HEIGHT(H)',f'.WIDTH({w}),.HEIGHT({h})').replace('[0:N-1]',f'[0:{n-1}]').replace('got>=N',f'got>={n}')
    with tempfile.TemporaryDirectory(prefix='mean_shift_test_') as temporary:
        td=Path(temporary);(td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'mean_shift_frame.sv',td/'tb.sv'],HERE,td/'compile.log')
        out=execute(['vvp',td/'sim'],HERE,td/'run.log',timeout=300);assert 'PASS' in out;print(w,h,out.strip(),flush=True)
    return dict(width=w,height=h,frames=total+recovery,pixels=(total+recovery)*n,recovery_frames=recovery,max_radius_first_pixel_probe=n==1024,comparisons=comparisons,totals=totals)
if __name__=='__main__':
    profiles=[run_profile(*args) for args in [(1,1,6),(1,7,6),(7,5,18,True),(5,5,12),(32,32,4)]]
    (HERE/'test_evidence.json').write_text(json.dumps(dict(status='PASS',profiles=profiles,opencv_version=cv2.__version__,comparison_note='OpenCV uses rectangular spatial windows, different center/termination rules; only constant preservation is asserted equivalent. Other discrepancies are measured, not hidden.',rtl_sha256=hashlib.sha256((HERE/'mean_shift_frame.sv').read_bytes()).hexdigest()),indent=2)+'\n',encoding='utf-8');print('ALL PASS')
