"""Integer oracle + actual SciPy convolution/OpenCV references and RTL protocol tests."""
from pathlib import Path
import hashlib,json,sys,tempfile
import numpy as np
import scipy
from scipy.signal import convolve2d
import cv2
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
from coefficients import generate

def oracle(image, weights, shift):
    h,w=image.shape;k=len(weights);r=k//2
    raw=np.zeros((h,w),np.int64)
    for y in range(h):
        for x in range(w):
            raw[y,x]=sum(int(image[min(h-1,max(0,y+r-j)),min(w-1,max(0,x+r-i))])*int(weights[j,i])
                         for j in range(k) for i in range(k))
    rounded=(np.abs(raw)+(0 if shift==0 else 1<<(shift-1)))>>shift
    return np.where(raw<0,-rounded,rounded),raw

TB='''module tb;
localparam W=WW,H=HH,N=W*H;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=0,start_valid=0;wire start_ready;
reg [3:0]cfg_size;reg [4:0]cfg_shift;
reg signed [15:0]c_real,c_imag;reg c_valid=0,c_first=0,c_last=0;wire c_ready;
reg [7:0]s_pixel;reg s_valid=0,s_sof=0,s_eol=0,s_last=0;wire s_ready;
wire signed [31:0]m_real,m_imag;wire m_valid;reg m_ready=0;wire m_sof,m_eol,m_last;
wire done_valid;reg done_ready=0;wire done_error;wire [3:0]error_code;wire busy;
gabor_filter_frame #(.WIDTH(W),.HEIGHT(H)) dut(.*);
reg [66:0]expected[0:N-1];reg [66:0]held;reg was_stalled=0;
reg [31:0]noise=32'h6d13a981;reg stalls=0;
integer got=0,cycles=0,frame=0,completed=0,ce_pauses=0,output_stalls=0;
reg [3:0]saved_state;
always @(negedge clk)begin
 noise=noise^(noise<<13);noise=noise^(noise>>17);noise=noise^(noise<<5);
 if(stalls)begin ce=noise[0]|noise[1];m_ready=noise[2]|noise[3];end
end
always @(posedge clk)begin
 cycles=cycles+1;if(cycles>18000000)$fatal(1,"timeout");
 if(!rst_n)was_stalled=0;
 else begin
 if(was_stalled&&(!m_valid||{m_last,m_eol,m_sof,m_imag,m_real}!==held))$fatal(1,"held output changed");
 was_stalled=m_valid&&!(ce&&m_ready);held={m_last,m_eol,m_sof,m_imag,m_real};
 if(!ce)begin ce_pauses=ce_pauses+1;if(start_ready||c_ready||s_ready)$fatal(1,"CE0 ready");end
 if(m_valid&&!(ce&&m_ready))output_stalls=output_stalls+1;
 if(m_valid&&ce&&m_ready)begin
 if(got>=N||{m_last,m_eol,m_sof,m_imag,m_real}!==expected[got])$fatal(1,"response frame%0d pos%0d got %0d,%0d expected %h",frame,got,m_real,m_imag,expected[got]);got=got+1;
 end
 saved_state=dut.state;
 if(!ce)begin #1;if(dut.state!==saved_state)$fatal(1,"state changed with CE0");end
 end
end
task tick;begin @(posedge clk);#2;end endtask
task begin_frame(input [3:0]k,input [4:0]sh);begin
 while(!start_ready)tick();@(negedge clk);cfg_size=k;cfg_shift=sh;start_valid=1;
 @(posedge clk);while(!start_ready)@(posedge clk);#2;start_valid=0;
 cfg_size=0;cfg_shift=31;got=0;frame=frame+1;
end endtask
task coeff(input [15:0]re,im,input first,last);begin
 if(stalls&&noise[4])tick();@(negedge clk);c_real=re;c_imag=im;c_first=first;c_last=last;c_valid=1;
 @(posedge clk);while(!c_ready)@(posedge clk);#2;c_valid=0;
end endtask
task send(input [7:0]p,input sof,eol,last);begin
 if(stalls&&noise[5])tick();@(negedge clk);s_pixel=p;s_sof=sof;s_eol=eol;s_last=last;s_valid=1;
 @(posedge clk);while(!s_ready)@(posedge clk);#2;s_valid=0;
end endtask
task finish_frame(input integer outputs,code);begin
 while(!done_valid)tick();
 if(got!=outputs||done_error!=(code!=0)||error_code!=code||m_valid||s_ready||c_ready||start_ready)$fatal(1,"DONE frame%0d got%0d/%0d code%0d/%0d",frame,got,outputs,error_code,code);
 repeat(5)begin tick();if(!done_valid||error_code!=code)$fatal(1,"held DONE");end
 @(negedge clk);done_ready=1;@(posedge clk);while(!ce)@(posedge clk);#2;done_ready=0;completed=completed+1;
end endtask
initial begin tick();tick();rst_n=1;ce=1;m_ready=1;stalls=1;
BODY
$display("PASS frames=%0d cycles=%0d ce_pauses=%0d output_stalls=%0d",completed,cycles,ce_pauses,output_stalls);$finish;end
endmodule
'''

def coeff_lines(re,im,bad=None):
    k=re.shape[0];out=[]
    for i,(a,b) in enumerate(zip(re.flat,im.flat)):
        first,last=i==0,i==k*k-1
        if bad=='missing_first' and i==0:first=False
        if bad=='extra_first' and i==1:first=True
        if bad=='early_last' and i==0:last=True
        if bad=='missing_last' and i==k*k-1:last=False
        out.append(f"coeff(16'h{int(a)&65535:04x},16'h{int(b)&65535:04x},1'b{int(first)},1'b{int(last)});")
        if (bad in ('missing_first','early_last') and i==0) or (bad=='extra_first' and i==1):break
    return out

def frame_lines(image,bad=None):
    h,w=image.shape;n=w*h;out=[]
    for i,p in enumerate(image.flat):
        flags=[i==0,i%w==w-1,i==n-1]
        for kind,index,where in [('missing_sof',0,0),('extra_sof',0,1),('missing_eol',1,w-1),
                                 ('extra_eol',1,0),('missing_last',2,n-1),('early_last',2,0)]:
            if bad==kind and i==where:flags[index]=not flags[index]
        out.append(f"send(8'd{int(p)},1'b{int(flags[0])},1'b{int(flags[1])},1'b{int(flags[2])});")
    return out

def expected_lines(real,imag):
    h,w=real.shape;out=[]
    for i,(re,im) in enumerate(zip(real.flat,imag.flat)):
        word=(int(re)&0xffffffff)|((int(im)&0xffffffff)<<32)|((i==0)<<64)|((i%w==w-1)<<65)|((i==w*h-1)<<66)
        out.append(f"expected[{i}]=67'h{word:x};")
    return out

def simulate(w,h,body):
    with tempfile.TemporaryDirectory(prefix='gabor_sim_') as temporary:
        td=Path(temporary);tb=TB.replace('WW',str(w)).replace('HH',str(h)).replace('BODY','\n'.join(body))
        (td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'gabor_filter_frame.sv',td/'tb.sv'],HERE,td/'compile.log')
        result=execute(['vvp',td/'sim'],HERE,td/'run.log',timeout=240)
        assert 'PASS frames=' in result;print(w,h,result.strip(),flush=True)
        return result.strip()

def functional(w,h,count):
    rng=np.random.default_rng(811+w*53+h);body=[];records=[]
    for i in range(count):
        k=[1,3,5,7][i%4];shift=[0,12,14,20,1][i%5]
        p=generate(k, sigma=.7+i%4*.4,theta=i*.39,wavelength=2.1+i%3*.7,
                   gamma=.6+i%3*.4,phase=i*.37,fraction=min(shift,14),zero_dc=i%3==0)
        re=np.array(p['real'],np.int64).reshape(k,k);im=np.array(p['imag'],np.int64).reshape(k,k)
        image=rng.integers(0,256,(h,w),dtype=np.uint8)
        mode=i%8
        if mode==0:image[:]=255
        if mode==1:image[:]=0;image[h//2,w//2]=255
        if mode==2:image[:]=77
        if mode==3:
            image[:]=255;re[:]=-32768;im[:]=32767;shift=0
        if mode==4:
            re[:]=32767;im[:]=-32768;image[:]=255;shift=0
        if mode==5:
            re=np.where(np.indices((k,k)).sum(0)%2,-32768,32767);im=-re-1
        if mode==6:image=(np.indices((h,w)).sum(0)%2*255).astype(np.uint8)
        if mode==7:
            # Half-unit ties, positive and negative output rounding.
            re[:]=1;im[:]=-1;image[:]=1;shift=1
        if i%16==11:
            # Complementary all-positive 49-term extreme (mode 3 is negative).
            re[:]=32767;im[:]=-32768;image[:]=255;shift=0
        real,raw_re=oracle(image,re,shift);imag,raw_im=oracle(image,im,shift)
        r=k//2;padded=np.pad(image,((r,r),(r,r)),mode='edge')
        sr=convolve2d(padded.astype(np.int64),re,mode='valid');si=convolve2d(padded.astype(np.int64),im,mode='valid')
        assert np.array_equal(sr,raw_re) and np.array_equal(si,raw_im)
        cr=cv2.filter2D(image.astype(np.float64),cv2.CV_64F,re[::-1,::-1].astype(np.float64),borderType=cv2.BORDER_REPLICATE)
        ci=cv2.filter2D(image.astype(np.float64),cv2.CV_64F,im[::-1,::-1].astype(np.float64),borderType=cv2.BORDER_REPLICATE)
        err=max(float(np.max(np.abs(cr-raw_re))),float(np.max(np.abs(ci-raw_im))))
        assert err<.00001
        body+=expected_lines(real,imag)+[f'begin_frame(4\'d{k},5\'d{shift});']+coeff_lines(re,im)+frame_lines(image)+[f'finish_frame({w*h},0);']
        records.append(dict(size=k,shift=shift,fixture=mode,scipy_raw_exact=True,opencv_raw_max_error=err,
                            max_abs_real=int(np.max(np.abs(raw_re))),max_abs_imag=int(np.max(np.abs(raw_im)))))
    return dict(width=w,height=h,frames=count,pixels=count*w*h,fixtures=records,simulation=simulate(w,h,body))

def protocol():
    w,h=3,2;image=np.arange(6,dtype=np.uint8).reshape(h,w)
    re=np.array([[0,1,0],[2,-1,3],[0,-2,0]],np.int64);im=-re
    real,_=oracle(image,re,2);imag,_=oracle(image,im,2);body=[];recoveries=0
    def healthy():
        nonlocal recoveries
        body.extend(expected_lines(real,imag)+['begin_frame(3,2);']+coeff_lines(re,im)+frame_lines(image)+['finish_frame(6,0);']);recoveries+=1
    for k,sh in [(0,0),(2,1),(4,2),(6,3),(8,4),(15,0),(3,21),(7,31)]:
        body.extend([f'begin_frame({k},{sh});','finish_frame(0,1);']);healthy()
    for bad in ['missing_first','extra_first','early_last','missing_last']:
        body.extend(['begin_frame(3,2);']+coeff_lines(re,im,bad)+['finish_frame(0,2);']);healthy()
    for bad in ['missing_sof','extra_sof','missing_eol','extra_eol','missing_last','early_last']:
        body.extend(['begin_frame(3,2);']+coeff_lines(re,im)+frame_lines(image,bad)+['finish_frame(0,3);']);healthy()
    # Reset overrides CE in every processing state, both multiply components,
    # held output, held DONE and after an already accepted output prefix.
    phases=[(1,0),(2,0),(3,0),(4,0),(5,0),(6,0),(6,1),(7,0),(8,0),(9,0),(8,2)]
    poison_re=np.full((3,3),17,np.int64);poison_im=np.full((3,3),-23,np.int64)
    poison_image=np.full((h,w),255,np.uint8)
    poison_real,_=oracle(poison_image,poison_re,2);poison_imag,_=oracle(poison_image,poison_im,2)
    for phase,part in phases:
        body.extend(['stalls=0;ce=1;m_ready=0;begin_frame(3,2);'])
        if phase!=1:body.extend(coeff_lines(poison_re,poison_im))
        else:body.extend(coeff_lines(poison_re,poison_im)[:3])
        if phase not in (1,2):body.extend(expected_lines(poison_real,poison_imag)+frame_lines(poison_image))
        elif phase==2:body.extend(frame_lines(poison_image)[:3])
        if phase==9:body.append('m_ready=1;')
        if part==2:body.append('m_ready=1;while(got<1)tick();@(negedge clk);m_ready=0;')
        body.append(f'while(dut.state!={phase}'+('||dut.imag_part!=1' if part==1 else '')+')tick();')
        body.extend(['@(negedge clk);ce=0;rst_n=0;tick();if(busy||m_valid||done_valid||start_ready||s_ready||c_ready)$fatal(1,"CE0 reset");',
                     'rst_n=1;ce=1;m_ready=1;stalls=1;'])
        healthy()
    body.extend(['stalls=0;ce=1;m_ready=1;begin_frame(3,2);',
                 '@(negedge clk);dut.state=15;tick();finish_frame(0,4);'])
    healthy()
    return dict(invalid_runtime=8,kernel_marker_errors=4,frame_marker_errors=6,
                reset_phases=len(phases),illegal_state=1,full_recovery_frames=recoveries,
                simulation=simulate(w,h,body))

def static_invalid():
    template='''module tb;reg clk=0;always #5 clk=~clk;reg rst_n=0,start_valid=0;
wire done_valid,done_error;wire[3:0]error_code;
gabor_filter_frame #(.WIDTH(WW),.HEIGHT(HH)) dut(.clk(clk),.rst_n(rst_n),.ce(1'b1),.start_valid(start_valid),.cfg_size(4'd3),.cfg_shift(5'd12),.done_valid(done_valid),.done_ready(1'b0),.done_error(done_error),.error_code(error_code));
initial begin repeat(2)@(negedge clk);rst_n=1;start_valid=1;@(negedge clk);start_valid=0;
if(!done_valid||!done_error||error_code!=1)$fatal(1,"invalid dimensions");repeat(5)@(negedge clk);
if(!done_valid)$fatal(1,"held DONE");$display("INVALID PASS");$finish;end endmodule'''
    profiles=[(0,1),(33,1),(1,0),(1,33),(-1,2)]
    with tempfile.TemporaryDirectory(prefix='gabor_invalid_') as temporary:
        td=Path(temporary)
        for w,h in profiles:
            (td/'tb.sv').write_text(template.replace('WW',str(w)).replace('HH',str(h)),encoding='utf-8')
            execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'gabor_filter_frame.sv',td/'tb.sv'],HERE,td/'compile.log')
            assert 'INVALID PASS' in execute(['vvp',td/'sim'],HERE,td/'run.log')
    return profiles

def generator_tests():
    errors=[]
    for args in [dict(size=2),dict(size=True),dict(sigma=0),dict(sigma=float('nan')),
                 dict(wavelength=0),dict(gamma=0),dict(theta=float('inf')),
                 dict(phase=float('nan')),dict(fraction=15),dict(fraction=-1),dict(fraction=1.5)]:
        try:generate(**args)
        except ValueError:errors.append(str(args))
        else:raise AssertionError(args)
    records=[]
    for k in [1,3,5,7]:
        for theta,phase in [(0.,0.),(.37,.61),(1.23,-.91)]:
            p=generate(k,theta=theta,phase=phase,fraction=14)
            # OpenCV stores gabor values in reversed coordinate order.
            a=cv2.getGaborKernel((k,k),1.4,theta,3.,.8,phase,ktype=cv2.CV_64F)[::-1,::-1]
            b=cv2.getGaborKernel((k,k),1.4,theta,3.,.8,phase-np.pi/2,ktype=cv2.CV_64F)[::-1,::-1]
            q=lambda x:np.sign(x)*np.floor(np.abs(x)*16384+.5)
            assert np.array_equal(q(a).astype(np.int64).ravel(),p['real'])
            assert np.array_equal(q(b).astype(np.int64).ravel(),p['imag'])
            records.append(dict(size=k,theta=theta,phase=phase,opencv_quantized_coefficients_exact=True))
    return dict(invalid_cases=errors,opencv_generation=records)

if __name__=='__main__':
    gen=generator_tests()
    profiles=[functional(w,h,n) for w,h,n in [(1,1,8),(1,7,8),(7,1,8),(9,7,16),(32,32,4)]]
    protocol_result=protocol();invalid=static_invalid()
    report=dict(status='PASS',profiles=profiles,protocol=protocol_result,invalid_static=invalid,generator=gen,
                scipy_version=scipy.__version__,opencv_version=cv2.__version__,
                rtl_sha256=hashlib.sha256((HERE/'gabor_filter_frame.sv').read_bytes()).hexdigest(),
                generator_sha256=hashlib.sha256((HERE/'coefficients.py').read_bytes()).hexdigest(),board_tested=False)
    (HERE/'test_evidence.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print('ALL PASS',flush=True)
