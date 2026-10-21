"""Exact centered-moment integer oracle, float NumPy and real OpenCV ZNCC."""
from pathlib import Path
import sys,tempfile,json,hashlib,math
import numpy as np,cv2
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent;sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
def oracle(image,template):
    h,w=image.shape;th,tw=template.shape;n=tw*th;result=[];best=None;audits=[]
    b=[int(x) for x in template.flat];sb=sum(b);v_b=n*sum(x*x for x in b)-sb*sb
    cv=cv2.matchTemplate(image,template,cv2.TM_CCOEFF_NORMED)
    for y in range(h-th+1):
        for x in range(w-tw+1):
            a=[int(q) for q in image[y:y+th,x:x+tw].flat];sa=sum(a)
            v_a=n*sum(q*q for q in a)-sa*sa;num=n*sum(q*r for q,r in zip(a,b))-sa*sb
            invalid=not(v_a and v_b)
            if invalid:score=0;float_score=None
            else:
                denominator=math.isqrt((v_a*v_b)<<32)
                score=((abs(num)<<31)+denominator//2)//denominator
                if num<0:score=-score
                af=np.array(a,dtype=float);bf=np.array(b,dtype=float);af-=af.mean();bf-=bf.mean()
                float_score=float(np.dot(af,bf)/np.sqrt(np.dot(af,af)*np.dot(bf,bf)))
                # Q16 sqrt denominator error plus nearest Q15 quantization <=1 LSB.
                assert abs(score/32768-float_score)<=1/32768+1e-12,(score,float_score,v_a,v_b)
                # OpenCV uses float accumulations and its own degeneracy policy.
                assert abs(float(cv[y,x])-float_score)<0.002,(float(cv[y,x]),float_score)
                audits.append(dict(numpy_error=abs(score/32768-float_score),opencv_error=abs(score/32768-float(cv[y,x]))))
            result.append((x,y,score,int(invalid)))
            if not invalid and (best is None or score>best[2]):best=(x,y,score)
    return result,best,dict(valid_windows=len(audits),invalid_windows=len(result)-len(audits),max_numpy_error=max((q['numpy_error'] for q in audits),default=0),max_opencv_error=max((q['opencv_error'] for q in audits),default=0))
TB='''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=0,start_valid=0;wire start_ready;
reg [3:0] cfg_template_width,cfg_template_height;
reg [7:0] t_pixel,s_pixel;reg t_valid=0,t_sof=0,t_eol=0,t_last=0,s_valid=0,s_sof=0,s_eol=0,s_last=0;wire t_ready,s_ready;
wire signed [16:0] m_score,best_score;wire [5:0] m_x,m_y,best_x,best_y;
wire m_invalid,m_valid,m_sof,m_eol,m_last,best_valid;reg m_ready=0;
wire done_valid,done_error,busy;reg done_ready=0;wire [3:0]error_code;
template_match_zncc #(.WIDTH(W),.HEIGHT(H)) dut(.*);
reg [32:0] expected[0:1023];reg [32:0] held;reg was_stalled=0,stalls=0;
reg [31:0] noise=32'h13331201;integer cycles=0,got=0,frame=0;
always @(negedge clk)begin noise=noise^(noise<<13);noise=noise^(noise>>17);noise=noise^(noise<<5);
if(stalls)begin ce=noise[0]|noise[1];m_ready=noise[2]|noise[3];end end
always @(posedge clk)begin cycles=cycles+1;if(cycles>15000000)$fatal(1,"timeout");
if(!rst_n)was_stalled=0;else begin
if(was_stalled&&(!m_valid||held!=={m_last,m_eol,m_sof,m_invalid,m_y,m_x,m_score}))$fatal(1,"unstable output");
was_stalled=m_valid&&!(ce&&m_ready);held={m_last,m_eol,m_sof,m_invalid,m_y,m_x,m_score};
if(m_valid&&ce&&m_ready)begin if({m_last,m_eol,m_sof,m_invalid,m_y,m_x,m_score}!==expected[got])$fatal(1,"map frame%0d pos%0d got%h expected%h",frame,got,{m_last,m_eol,m_sof,m_invalid,m_y,m_x,m_score},expected[got]);got=got+1;end end end
task tick;begin @(posedge clk);#1;end endtask
task ack;begin @(negedge clk);done_ready=1;@(posedge clk);while(!ce)@(posedge clk);#1;done_ready=0;end endtask
task begin_frame(input [3:0] tw,th);begin
while(!start_ready)tick();@(negedge clk);cfg_template_width=tw;cfg_template_height=th;start_valid=1;
@(posedge clk);while(!start_ready)@(posedge clk);#1;start_valid=0;cfg_template_width=0;cfg_template_height=0;got=0;end endtask
task send_t(input [7:0] p,input sof,eol,last);begin
@(negedge clk);t_pixel=p;t_sof=sof;t_eol=eol;t_last=last;t_valid=1;
@(posedge clk);while(!t_ready)@(posedge clk);#1;t_valid=0;end endtask
task send_s(input [7:0] p,input sof,eol,last);begin
@(negedge clk);s_pixel=p;s_sof=sof;s_eol=eol;s_last=last;s_valid=1;
@(posedge clk);while(!s_ready)@(posedge clk);#1;s_valid=0;end endtask
initial begin tick();tick();rst_n=1;ce=1;m_ready=1;stalls=1;
BODY
$display("PASS frames=%0d cycles=%0d",frame+1,cycles);$finish;end
endmodule
'''
def expectation(results,bad,w,tw):
    body=[]
    for i,(x,y,score,invalid) in enumerate(results):
        value=(score&0x1ffff)|(x<<17)|(y<<23)|((invalid or bad!=0)<<29)|((i==0)<<30)|((x==w-tw)<<31)|((i==len(results)-1)<<32)
        body.append(f"expected[{i}]=33'h{value:x};")
    return body
def feed(image,template,bad):
    h,w=image.shape;th,tw=template.shape;body=[]
    for which,array in [('t',template),('s',image)]:
        ah,aw=array.shape
        for i,p in enumerate(array.flat):
            e=bad if which=='t' else bad-3
            body.append(f"send_{which}(8'd{int(p)},1'b{int((i==0)^(e==1 and i==0))},1'b{int((i%aw==aw-1)^(e==2 and i==aw*ah-1))},1'b{int((i==aw*ah-1)^(e==3 and i==aw*ah-1))});")
    return body
def run_profile(w,h,tw,th,total,resets=False):
    rng=np.random.default_rng(w*133+h*17+tw);body=[];audits=[]
    for idx in range(total):
        image=rng.integers(0,256,(h,w),dtype=np.uint8);template=rng.integers(0,256,(th,tw),dtype=np.uint8)
        if idx%6==0:template=image[h-th:h,w-tw:w].copy()
        elif idx%6==1:image[:]=123
        elif idx%6==2:template[:]=55
        elif idx%6==3:
            image=(image%2+127).astype(np.uint8);template=(template%2+127).astype(np.uint8)
            if (w,h,tw,th)==(2,2,2,2):
                # variance product 12: naive floor(sqrt(12)) would distort ZNCC.
                image=np.array([[127,127],[127,128]],np.uint8)
                template=np.array([[127,127],[128,128]],np.uint8)
        elif idx%6==4:
            template=np.array([(i%2) for i in range(th*tw)],np.uint8).reshape(th,tw);image=np.tile(255-template,(math.ceil(h/th),math.ceil(w/tw)))[:h,:w].copy()
        bad=(idx-5)//2 if total>=18 and idx>=7 and idx%2 else 0
        result,best,audit=oracle(image,template);audit.update(frame=idx,template_width=tw,template_height=th,error=bad);audits.append(audit)
        body+=expectation(result,bad,w,tw);body.append(f"frame={idx};begin_frame(4'd{tw},4'd{th});");body+=feed(image,template,bad)
        bx,by,bs=best if best is not None and not bad else (0,0,0);bv=best is not None and not bad
        body.append(f"while(!done_valid)tick();if(got!={len(result)}||done_error!=1'b{int(bool(bad))}||error_code!={2 if 1<=bad<=3 else 3 if bad else 0}||best_valid!=1'b{int(bv)})$fatal(1,\"DONE/length/best valid\");")
        if bv:body.append(f"if(best_x!={bx}||best_y!={by}||best_score!==17'h{bs&0x1ffff:x})$fatal(1,\"best coordinate/score\");")
        body.append("repeat(7)tick();if(!done_valid)$fatal(1,\"held DONE\");ack();")
        if idx==0:
            invalid=[(0,1),(1,0),(9,1),(1,9)]
            if w<8:invalid.append((w+1,1))
            if h<8:invalid.append((1,h+1))
            for a,b in invalid:
                body.append(f"begin_frame(4'd{a},4'd{b});while(!done_valid)tick();if(!done_error||error_code!=1||got!=0||best_valid||best_score||best_x||best_y)$fatal(1,\"invalid cfg/old best metadata\");ack();")
    recovery=0
    if resets:
        image=rng.integers(0,256,(h,w),dtype=np.uint8);template=image[:th,:tw].copy();result,best,_=oracle(image,template)
        for phase in [1,2,5,33,28,34,31,32]:
            body.append("stalls=0;ce=1;m_ready=0;begin_frame(4'd2,4'd2);")
            # Feed the reset transaction with the same template geometry as normal.
            body[-1]=f"stalls=0;ce=1;m_ready=0;begin_frame(4'd{tw},4'd{th});"
            if phase!=1:
                commands=feed(image,template,0)
                body+=commands[:tw*th] if phase==2 else commands
            if phase==32:body+=expectation(result,0,w,tw);body.append("m_ready=1;")
            body.append(f"while(dut.state!={phase})tick();repeat(2)tick();@(negedge clk);ce=0;rst_n=0;tick();if(busy||m_valid||done_valid||t_ready||s_ready||start_ready)$fatal(1,\"reset phase{phase}\");rst_n=1;ce=1;m_ready=1;")
            body+=expectation(result,0,w,tw);body.append(f"begin_frame(4'd{tw},4'd{th});");body+=feed(image,template,0)
            bx,by,bs=best
            body.append(f"while(!done_valid)tick();if(got!={len(result)}||done_error||!best_valid||best_x!={bx}||best_y!={by}||best_score!==17'h{bs&0x1ffff:x})$fatal(1,\"recovery\");ack();");recovery+=1
    tb=TB.replace('BODY','\n'.join(body)).replace('.WIDTH(W),.HEIGHT(H)',f'.WIDTH({w}),.HEIGHT({h})')
    with tempfile.TemporaryDirectory(prefix='zncc_test_') as temporary:
        td=Path(temporary);(td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'template_match_zncc.sv',td/'tb.sv'],HERE,td/'compile.log')
        out=execute(['vvp',td/'sim'],HERE,td/'run.log',timeout=300);assert 'PASS' in out;print(w,h,tw,th,out.strip(),flush=True)
    return dict(width=w,height=h,template_width=tw,template_height=th,frames=total+recovery,score_map_outputs=len(result)*(total+recovery),reset_recovery_frames=recovery,numerical_comparisons=audits)
if __name__=='__main__':
    profiles=[run_profile(*args) for args in [(1,1,1,1,4),(1,7,1,2,6),(2,2,2,2,6),(7,5,2,3,18,True),(7,7,3,3,6),(32,32,8,8,1),(32,32,1,1,1)]]
    (HERE/'test_evidence.json').write_text(json.dumps(dict(status='PASS',profiles=profiles,opencv_version=cv2.__version__,numpy_version=np.__version__,rtl_sha256=hashlib.sha256((HERE/'template_match_zncc.sv').read_bytes()).hexdigest()),indent=2)+'\n',encoding='utf-8');print('ALL PASS')
