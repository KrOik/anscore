"""Independent integer unsharp oracle and actual OpenCV Gaussian/addWeighted."""
from pathlib import Path
import sys,tempfile,json,hashlib,random
import numpy as np,cv2
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
def oracle(image,gain,threshold):
    h,w,c=image.shape;blur=np.zeros_like(image);output=np.zeros_like(image);clips=0
    for y in range(h):
        for x in range(w):
            for z in range(c):
                sm=sum(int(image[min(h-1,max(0,y+dy)),min(w-1,max(0,x+dx)),z])*wy*wx for dy,wy in [(-1,1),(0,2),(1,1)] for dx,wx in [(-1,1),(0,2),(1,1)])
                low=(sm+8)//16;blur[y,x,z]=low;detail=int(image[y,x,z])-low
                boost=((abs(detail)*gain+8)//16)*(1 if detail>=0 else -1) if abs(detail)>threshold else 0
                raw=int(image[y,x,z])+boost;clips+=raw<0 or raw>255;output[y,x,z]=min(255,max(0,raw))
    return output,blur,int(clips)
def packed(pixel):return sum(int(v)<<(8*i) for i,v in enumerate(reversed(pixel)))
TB='''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=0,start_valid=0;wire start_ready;
reg [7:0] cfg_gain,cfg_threshold;
reg [C*8-1:0] s_pixel;reg s_valid=0,s_sof=0,s_eol=0,s_last=0;wire s_ready;
wire [C*8-1:0] m_pixel;wire m_valid;reg m_ready=0;wire m_sof,m_eol,m_last;
wire [12:0] clipped_samples;wire done_valid;reg done_ready=0;wire done_error;wire [3:0] error_code;wire busy;
unsharp_mask_frame #(.WIDTH(W),.HEIGHT(H),.CHANNELS(C)) dut(.*);
integer cycles=0,got=0,frame=0,i;reg [C*8+2:0] expected[0:N-1];
reg [31:0] noise=32'h33183929;reg stalls=0;reg [C*8+2:0] held;reg was_stalled=0;
always @(negedge clk)begin noise=noise^(noise<<13);noise=noise^(noise>>17);noise=noise^(noise<<5);
if(stalls)begin ce=noise[0]|noise[1];m_ready=noise[2]|noise[3];end end
always @(posedge clk)begin
cycles=cycles+1;if(cycles>3000000)$fatal(1,"timeout");
if(rst_n)begin
if(was_stalled&&(!m_valid||{m_last,m_eol,m_sof,m_pixel}!==held))$fatal(1,"unstable output");
was_stalled=m_valid&&!(ce&&m_ready);held={m_last,m_eol,m_sof,m_pixel};
if(m_valid&&ce&&m_ready)begin
if(got>=N||{m_last,m_eol,m_sof,m_pixel}!==expected[got])$fatal(1,"pixel frame%0d pos%0d actual%h expected%h",frame,got,{m_last,m_eol,m_sof,m_pixel},expected[got]);got=got+1;end end end
task tick;begin @(posedge clk);#1;end endtask
task ack;begin @(negedge clk);done_ready=1;@(posedge clk);while(!ce)@(posedge clk);#1;done_ready=0;end endtask
task send(input [C*8-1:0] p,input sof,eol,last);begin
@(negedge clk);s_pixel=p;s_sof=sof;s_eol=eol;s_last=last;s_valid=1;
@(posedge clk);while(!s_ready)@(posedge clk);#1;s_valid=0;end endtask
task begin_frame(input [7:0] gain,threshold);begin
while(!start_ready)tick();@(negedge clk);cfg_gain=gain;cfg_threshold=threshold;start_valid=1;
@(posedge clk);while(!start_ready)@(posedge clk);#1;start_valid=0;
cfg_gain=~gain;cfg_threshold=~threshold;got=0;end endtask
initial begin tick();tick();rst_n=1;ce=1;m_ready=1;stalls=1;
BODY
$display("PASS frames=%0d cycles=%0d",frame+1,cycles);$finish;end
endmodule
'''
def run_profile(w,h,c,total):
    rng=np.random.default_rng(w*977+h*31+c);n=w*h;body=[];comparison=[]
    for idx in range(total):
        image=rng.integers(0,256,(h,w,c),dtype=np.uint8)
        gain=[0,16,32,255,1,8,24,128][idx%8];threshold=[0,0,12,0,255,2,20,127][idx%8]
        if idx%7==0:image[:]=77
        elif idx%7==1:image[:]=0;image[h//2,w//2,:]=255
        elif idx%7==2:image[:]=255;image[h//2,w//2,:]=0
        elif idx%7==3:image[:]=0;image[h//2,w//2,:]=16;threshold=12 if idx==3 else 11;gain=16
        elif idx%7==4:image[:]=np.array([255 if (x+y)%2 else 0 for y in range(h) for x in range(w)],np.uint8).reshape(h,w,1)
        expected,blur,clips=oracle(image,gain,threshold)
        actual_blur=cv2.GaussianBlur(image,(3,3),0,borderType=cv2.BORDER_REPLICATE)
        if c==1:actual_blur=actual_blur[:,:,None]
        assert np.array_equal(actual_blur,blur)
        cv=cv2.addWeighted(image,1+gain/16,actual_blur,-gain/16,0)
        if c==1:cv=cv[:,:,None]
        cv=np.where(np.abs(image.astype(int)-actual_blur.astype(int))>threshold,cv,image)
        error=np.abs(cv.astype(int)-expected.astype(int));assert error.max()<=1
        comparison.append(dict(frame=idx,gain_q4_4=gain,threshold=threshold,gaussian_exact=True,opencv_max_output_error=int(error.max()),clipped_samples=clips))
        for i,p in enumerate(expected.reshape(n,c)):
            value=packed(p)|((i==0)<<(c*8))|((i%w==w-1)<<(c*8+1))|((i==n-1)<<(c*8+2))
            body.append(f"expected[{i}]={c*8+3}'h{value:x};")
        body.append(f"frame={idx};begin_frame(8'd{gain},8'd{threshold});")
        bad=idx-total+4 if idx>=total-3 else 0
        for i,p in enumerate(image.reshape(n,c)):
            body.append(f"send({c*8}'h{packed(p):x},1'b{int((i==0)^(bad==1 and i==0))},1'b{int((i%w==w-1)^(bad==2 and i==n-1))},1'b{int((i==n-1)^(bad==3 and i==n-1))});")
        body.append(f"while(!done_valid)tick();if(got!={n}||done_error!=1'b{int(bool(bad))}||error_code!={2 if bad else 0}||clipped_samples!={clips})$fatal(1,\"DONE/count/clips\");repeat(5)tick();if(!done_valid||clipped_samples!={clips})$fatal(1,\"held DONE\");ack();")
    # CE-low reset at capture, RAM reads, gain arithmetic, held output and DONE.
    for phase in [1,2,5,8,10,11]:
        body.append("stalls=0;ce=1;m_ready=0;begin_frame(8'd16,8'd0);")
        if phase!=1:
            for i in range(n):body.append(f"send({c*8}'d0,1'b{int(i==0)},1'b{int(i%w==w-1)},1'b{int(i==n-1)});")
        if phase==11:body.append("m_ready=1;")
        body.append(f"while(dut.state!={phase})tick();@(negedge clk);ce=0;rst_n=0;tick();if(busy||m_valid||done_valid||start_ready||s_ready)$fatal(1,\"CE0 reset phase{phase}\");rst_n=1;ce=1;m_ready=1;begin_frame(8'd255,8'd0);")
        for i in range(n):
            val=((i==0)<<(c*8))|((i%w==w-1)<<(c*8+1))|((i==n-1)<<(c*8+2))
            body.append(f"expected[{i}]={c*8+3}'h{val:x};send({c*8}'d0,1'b{int(i==0)},1'b{int(i%w==w-1)},1'b{int(i==n-1)});")
        body.append(f"while(!done_valid)tick();if(got!={n}||done_error||clipped_samples)$fatal(1,\"recovery\");ack();")
    tb=TB.replace('BODY','\n'.join(body)).replace('[0:N-1]',f'[0:{n-1}]').replace('got>=N',f'got>={n}').replace('.WIDTH(W),.HEIGHT(H),.CHANNELS(C)',f'.WIDTH({w}),.HEIGHT({h}),.CHANNELS({c})').replace('C*8',f'{c}*8')
    with tempfile.TemporaryDirectory(prefix='unsharp_test_') as temporary:
        td=Path(temporary);(td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'unsharp_mask_frame.sv',td/'tb.sv'],HERE,td/'compile.log')
        out=execute(['vvp',td/'sim'],HERE,td/'run.log',timeout=180);assert 'PASS' in out;print(w,h,c,out.strip(),flush=True)
    return dict(width=w,height=h,channels=c,frames=total+6,pixels=(total+6)*n,reset_phases=6,comparisons=comparison)
def invalid_parameters():
    tb='''module tb;reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0;wire start_ready,done_valid,done_error,busy;wire [3:0]error_code;
unsharp_mask_frame #(.WIDTH(WW),.HEIGHT(HH),.CHANNELS(CC)) dut(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.start_ready(start_ready),.done_valid(done_valid),.done_error(done_error),.error_code(error_code),.done_ready(1'b0));
initial begin repeat(2)@(negedge clk);rst_n=1;start_valid=1;@(negedge clk);start_valid=0;if(!done_valid||!done_error||error_code!=1)$fatal(1,"invalid static config");repeat(3)@(negedge clk);if(!done_valid)$fatal(1,"held invalid config");$display("INVALID PASS");$finish;end endmodule'''
    with tempfile.TemporaryDirectory(prefix='unsharp_invalid_') as temporary:
        td=Path(temporary)
        for w,h,c in [(0,1,1),(33,1,1),(1,0,3),(1,33,3),(1,1,2)]:
            (td/'tb.sv').write_text(tb.replace('WW',str(w)).replace('HH',str(h)).replace('CC',str(c)),encoding='utf-8')
            execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'unsharp_mask_frame.sv',td/'tb.sv'],HERE,td/'compile.log')
            assert 'INVALID PASS' in execute(['vvp',td/'sim'],HERE,td/'run.log')
    return 5
if __name__=='__main__':
    profiles=[run_profile(w,h,c,n) for w,h,c,n in [(1,1,1,8),(1,7,3,8),(7,1,1,8),(7,5,1,24),(7,5,3,24),(32,32,3,8)]]
    invalid=invalid_parameters()
    report=dict(status='PASS',profiles=profiles,invalid_static_parameters=invalid,opencv_version=cv2.__version__,rtl_sha256=hashlib.sha256((HERE/'unsharp_mask_frame.sv').read_bytes()).hexdigest())
    (HERE/'test_evidence.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('ALL PASS')
