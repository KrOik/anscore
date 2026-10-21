"""Every local histogram + Q20 entropy; independent float, SciPy, actual skimage."""
from pathlib import Path
from collections import Counter
import hashlib,json,math,sys,tempfile
import numpy as np
import scipy,skimage
from scipy.stats import entropy
from skimage.filters.rank import entropy as rank_entropy
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
from generate_rom import content

def oracle(image,k):
    h,w=image.shape;r=k//2;n=k*k
    terms=[0 if c in (0,n) else math.floor(-(c/n)*math.log2(c/n)*(1<<20)+.5) for c in range(n+1)]
    fixed=np.zeros((h,w),np.int64);ideal=np.zeros((h,w),float);scipy_max=0.
    for y in range(h):
        for x in range(w):
            counts=Counter(int(image[min(h-1,max(0,y+j)),min(w-1,max(0,x+i))])
                           for j in range(-r,r+1) for i in range(-r,r+1))
            fixed[y,x]=sum(terms[c] for c in counts.values())
            ideal[y,x]=sum(-(c/n)*math.log2(c/n) for c in counts.values())
            scipy_max=max(scipy_max,abs(float(entropy(list(counts.values()),base=2))-ideal[y,x]))
    external=rank_entropy(np.pad(image,r,mode='edge'),np.ones((k,k),np.uint8))[r:-r,r:-r]
    err=float(np.max(np.abs(fixed/(1<<20)-ideal)));bound=n/(2*(1<<20))
    assert err<=bound+1e-14 and scipy_max<1e-12
    skimage_error=float(np.max(np.abs(external-ideal)));assert skimage_error<1e-12
    return fixed,dict(window=k,actual_skimage_max_error=skimage_error,actual_scipy_max_error=scipy_max,
                      fixed_max_error_bits=err,theoretical_error_bound_bits=bound,
                      max_entropy_q20=int(fixed.max()),min_entropy_q20=int(fixed.min()))

TB='''module tb;
localparam W=WW,H=HH,N=W*H;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=0,start_valid=0;wire start_ready;reg[3:0]cfg_size;
reg[7:0]s_pixel;reg s_valid=0,s_sof=0,s_eol=0,s_last=0;wire s_ready;
wire[22:0]m_entropy_q20;wire m_valid;reg m_ready=0;wire m_sof,m_eol,m_last;
wire done_valid;reg done_ready=0;wire done_error;wire[3:0]error_code;wire busy;
entropy_filter_frame #(.WIDTH(W),.HEIGHT(H))dut(.*);
reg[25:0]expected[0:N-1];reg[7:0]pixels[0:N-1];reg[25:0]held;reg was_stalled=0;
reg[31:0]noise=32'h41de8071;reg stalls=0,check_hist=1;
integer got=0,cycles=0,completed=0,frame=0,pauses=0,holds=0,histograms=0;
integer histogram_check[0:255];integer v,j,i,xx,yy,total;
reg[3:0]saved_state;
always @(negedge clk)begin noise=noise^(noise<<13);noise=noise^(noise>>17);noise=noise^(noise<<5);
if(stalls)begin ce=noise[0]|noise[1];m_ready=noise[2]|noise[3];end end
always @(posedge clk)begin
cycles=cycles+1;if(cycles>20000000)$fatal(1,"timeout %d",dut.state);
if(!rst_n)was_stalled=0;
else begin
 if(was_stalled&&(!m_valid||{m_last,m_eol,m_sof,m_entropy_q20}!==held))$fatal(1,"held output changed");
 was_stalled=m_valid&&!(ce&&m_ready);held={m_last,m_eol,m_sof,m_entropy_q20};
 if(!ce)begin pauses=pauses+1;if(start_ready||s_ready)$fatal(1,"CE0 ready");end
 if(m_valid&&!(ce&&m_ready))holds=holds+1;
 if(m_valid&&ce&&m_ready)begin
  if(got>=N||{m_last,m_eol,m_sof,m_entropy_q20}!==expected[got])$fatal(1,"entropy frame%0d pos%0d got%0d expected%h",frame,got,m_entropy_q20,expected[got]);got=got+1;
 end
 if(check_hist&&ce&&dut.state==8&&dut.scan_index==0)begin
  for(v=0;v<256;v=v+1)histogram_check[v]=0;
  for(j=0;j<dut.side;j=j+1)for(i=0;i<dut.side;i=i+1)begin
   xx=dut.x+i-dut.radius;yy=dut.y+j-dut.radius;
   if(xx<0)xx=0;if(xx>=W)xx=W-1;if(yy<0)yy=0;if(yy>=H)yy=H-1;
   histogram_check[pixels[yy*W+xx]]=histogram_check[pixels[yy*W+xx]]+1;
  end
  total=0;for(v=0;v<256;v=v+1)begin
   if(dut.histogram[v]!==histogram_check[v])$fatal(1,"histogram frame%0d pixel%0d bin%0d",frame,dut.position,v);
   total=total+dut.histogram[v];
  end
  if(total!=dut.side*dut.side)$fatal(1,"histogram mass");histograms=histograms+1;
 end
 saved_state=dut.state;if(!ce)begin #1;if(dut.state!==saved_state)$fatal(1,"CE0 state changed");end
end end
task tick;begin @(posedge clk);#2;end endtask
task begin_frame(input[3:0]k);begin
while(!start_ready)tick();@(negedge clk);cfg_size=k;start_valid=1;
@(posedge clk);while(!start_ready)@(posedge clk);#2;start_valid=0;cfg_size=0;got=0;frame=frame+1;end endtask
task send(input[7:0]p,input sof,eol,last);begin
if(stalls&&noise[4])tick();@(negedge clk);s_pixel=p;s_sof=sof;s_eol=eol;s_last=last;s_valid=1;
@(posedge clk);while(!s_ready)@(posedge clk);#2;s_valid=0;end endtask
task finish_frame(input integer outputs,code);begin
while(!done_valid)tick();if(got!=outputs||done_error!=(code!=0)||error_code!=code||m_valid||s_ready||start_ready)$fatal(1,"DONE got%0d code%0d expected%0d",got,error_code,code);
repeat(5)begin tick();if(!done_valid||error_code!=code)$fatal(1,"held DONE");end
@(negedge clk);done_ready=1;@(posedge clk);while(!ce)@(posedge clk);#2;done_ready=0;completed=completed+1;end endtask
initial begin tick();tick();rst_n=1;ce=1;m_ready=1;stalls=1;
BODY
$display("PASS frames=%0d cycles=%0d pauses=%0d output_holds=%0d histograms=%0d",completed,cycles,pauses,holds,histograms);$finish;end endmodule'''

def initialize(image,expected):
    h,w=image.shape;out=[]
    for i,(p,e) in enumerate(zip(image.flat,expected.flat)):
        token=int(e)|((i==0)<<23)|((i%w==w-1)<<24)|((i==w*h-1)<<25)
        out.append(f"pixels[{i}]=8'd{int(p)};expected[{i}]=26'h{token:x};")
    return out

def feed(image,bad=None):
    h,w=image.shape;n=w*h;out=[]
    patterns={'missing_sof':(0,0),'extra_sof':(1,0),'missing_eol':(w-1,1),
              'extra_eol':(0,1),'missing_last':(n-1,2),'early_last':(0,2)}
    for i,p in enumerate(image.flat):
        flags=[i==0,i%w==w-1,i==n-1]
        if bad and patterns[bad][0]==i:flags[patterns[bad][1]]=not flags[patterns[bad][1]]
        out.append(f"send(8'd{int(p)},1'b{int(flags[0])},1'b{int(flags[1])},1'b{int(flags[2])});")
    return out

def simulate(w,h,body):
    with tempfile.TemporaryDirectory(prefix='entropy_sim_') as tmp:
        td=Path(tmp);(td/'entropy.mem').write_bytes((HERE/'entropy.mem').read_bytes())
        (td/'tb.sv').write_text(TB.replace('WW',str(w)).replace('HH',str(h)).replace('BODY','\n'.join(body)),encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'entropy_filter_frame.sv',td/'tb.sv'],td,td/'compile.log')
        out=execute(['vvp',td/'sim'],td,td/'run.log',timeout=300);assert 'PASS frames=' in out;print(w,h,out.strip(),flush=True);return out.strip()

def functional(w,h,frames):
    rng=np.random.default_rng(911+w*71+h);body=[];records=[]
    for i in range(frames):
        k=[3,5,7][i%3];image=rng.integers(0,256,(h,w),dtype=np.uint8);mode=i%6
        if mode==0:image[:]=255
        if mode==1:image[:]=0;image[h//2,w//2]=255
        if mode==2:image=(np.arange(w*h,dtype=np.uint16).reshape(h,w)%256).astype(np.uint8)
        if mode==3:image=(np.indices((h,w)).sum(0)%2*255).astype(np.uint8)
        if mode==4:image=rng.integers(254,256,(h,w),dtype=np.uint8)
        expected,record=oracle(image,k);record['fixture']=mode;records.append(record)
        body+=initialize(image,expected)+[f'begin_frame({k});']+feed(image)+[f'finish_frame({w*h},0);']
    return dict(width=w,height=h,frames=frames,pixels=w*h*frames,fixtures=records,simulation=simulate(w,h,body))

def protocol():
    w,h=3,2;image=np.array([[0,127,255],[1,127,254]],np.uint8)
    expected,_=oracle(image,3);poison=np.full((h,w),255,np.uint8);pe,_=oracle(poison,7)
    body=[];recoveries=0
    def healthy():
        nonlocal recoveries
        body.extend(initialize(image,expected)+['begin_frame(3);']+feed(image)+['finish_frame(6,0);']);recoveries+=1
    for k in [0,1,2,4,6,8,15]:
        body.extend([f'begin_frame({k});','finish_frame(0,1);']);healthy()
    for bad in ['missing_sof','extra_sof','missing_eol','extra_eol','missing_last','early_last']:
        body.extend(['begin_frame(3);']+feed(image,bad)+['finish_frame(0,2);']);healthy()
    # All active phases, stalled output, DONE, and reset after an accepted prefix.
    phases=list(range(1,15))+[15]
    for phase in phases:
        body.extend(['stalls=0;ce=1;m_ready=0;']+initialize(poison,pe)+['begin_frame(7);'])
        if phase!=1:body.extend(feed(poison))
        else:body.extend(feed(poison)[:3])
        if phase in (14,15):body.append('m_ready=1;')
        if phase==15:body.append('while(got<1)tick();@(negedge clk);m_ready=0;while(!m_valid)tick();')
        else:body.append(f'while(dut.state!={phase})tick();')
        body.extend(['@(negedge clk);ce=0;rst_n=0;tick();if(busy||m_valid||done_valid||s_ready||start_ready)$fatal(1,"CE0 reset");',
                     'rst_n=1;ce=1;m_ready=1;stalls=1;'])
        healthy()
    body.extend(['stalls=0;ce=1;begin_frame(3);@(negedge clk);dut.state=15;tick();finish_frame(0,3);']);healthy()
    # Test explicit histogram-overflow containment without changing source.
    body.extend(['stalls=0;ce=1;']+initialize(image,expected)+['begin_frame(3);']+feed(image)+[
        'while(dut.state!=7)tick();@(negedge clk);dut.histogram_q=9;tick();finish_frame(0,4);']);healthy()
    return dict(invalid_runtime=7,marker_errors=6,reset_ce0_phases=15,illegal_state=1,
                histogram_fault=1,full_recovery_frames=recoveries,simulation=simulate(w,h,body))

def invalid_static():
    tb='''module tb;reg clk=0;always #5 clk=~clk;reg rst_n=0,start_valid=0;wire done_valid,done_error;wire[3:0]error_code;
entropy_filter_frame #(.WIDTH(WW),.HEIGHT(HH))dut(.clk(clk),.rst_n(rst_n),.ce(1'b1),.start_valid(start_valid),.cfg_size(4'd3),.done_valid(done_valid),.done_ready(1'b0),.done_error(done_error),.error_code(error_code));
initial begin repeat(2)@(negedge clk);rst_n=1;start_valid=1;@(negedge clk);start_valid=0;if(!done_valid||!done_error||error_code!=1)$fatal(1,"static illegal");repeat(4)@(negedge clk);if(!done_valid)$fatal(1,"held error");$display("INVALID PASS");$finish;end endmodule'''
    profiles=[(0,1),(33,1),(1,0),(1,33),(-1,2)]
    with tempfile.TemporaryDirectory(prefix='entropy_invalid_') as tmp:
        td=Path(tmp);(td/'entropy.mem').write_bytes((HERE/'entropy.mem').read_bytes())
        for w,h in profiles:
            (td/'tb.sv').write_text(tb.replace('WW',str(w)).replace('HH',str(h)),encoding='utf-8')
            execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'entropy_filter_frame.sv',td/'tb.sv'],td,td/'compile.log')
            assert 'INVALID PASS' in execute(['vvp',td/'sim'],td,td/'run.log')
    return profiles

def main():
    assert (HERE/'entropy.mem').read_text(encoding='ascii')==content(),'ROM reproducibility'
    rom=[int(v,16) for v in (HERE/'entropy.mem').read_text().split()]
    for bank,n in enumerate((9,25,49)):
        for c in range(64):
            expected=0 if c==0 or c>=n else math.floor(-(c/n)*math.log2(c/n)*(1<<20)+.5)
            assert rom[bank*64+c]==expected,'independent float ROM check'
    profiles=[functional(w,h,n) for w,h,n in [(1,1,6),(1,7,6),(7,1,6),(9,7,12),(32,32,3)]]
    error=protocol();static=invalid_static()
    sha=lambda n:hashlib.sha256((HERE/n).read_bytes()).hexdigest()
    report=dict(status='PASS',profiles=profiles,protocol=error,invalid_static=static,rom_entries_checked=192,
                skimage_version=skimage.__version__,scipy_version=scipy.__version__,
                rtl_sha256=sha('entropy_filter_frame.sv'),rom_sha256=sha('entropy.mem'),board_tested=False)
    (HERE/'test_evidence.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('ALL PASS',flush=True)

if __name__=='__main__':main()
