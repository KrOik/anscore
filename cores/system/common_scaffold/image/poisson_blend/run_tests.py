"""Independent integer GS oracle, sparse Dirichlet solve, real OpenCV comparison."""
from pathlib import Path
import sys,tempfile,json,hashlib,random
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
def problem(src,dst,mask,w,h,mixed):
    active=[p for p in range(w*h) if mask[p] and p%w not in (0,w-1) and p//w not in (0,h-1)]
    adjacent={p:(p-1,p+1,p-w,p+w) for p in active}
    rhs={}
    for p in active:
        gradients=[]
        for q in adjacent[p]:
            a,b=src[p]-src[q],dst[p]-dst[q]
            gradients.append(b if mixed and abs(b)>abs(a) else a)
        rhs[p]=sum(gradients)
    return active,adjacent,rhs
def oracle(src,dst,mask,w,h,limit,tolerance,mixed):
    active,adjacent,rhs=problem(src,dst,mask,w,h,mixed)
    values=[v*256 for v in dst]
    for iteration in range(1,limit+1):
        for p in active:values[p]=(sum(values[q] for q in adjacent[p])+rhs[p]*256)//4
        residual=max((abs(values[p]*4-sum(values[q] for q in adjacent[p])-rhs[p]*256) for p in active),default=0)
        if residual<=tolerance:break
    return dict(values=values,output=[min(255,max(0,(v+128)//256)) for v in values],iterations=iteration,residual=residual,converged=int(residual<=tolerance),active=len(active))
def sparse_solve(src,dst,mask,w,h,mixed):
    import numpy as np
    from scipy.sparse import lil_matrix
    from scipy.sparse.linalg import spsolve
    active,adjacent,rhs=problem(src,dst,mask,w,h,mixed)
    result=np.array(dst,dtype=float);indices={p:i for i,p in enumerate(active)}
    if active:
        a=lil_matrix((len(active),len(active)));b=np.zeros(len(active))
        for p,i in indices.items():
            a[i,i]=4;b[i]=rhs[p]
            for q in adjacent[p]:
                if q in indices:a[i,indices[q]]=-1
                else:b[i]+=dst[q]
        result[active]=spsolve(a.tocsr(),b)
    return result
TB='''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=0,start_valid=0;wire start_ready;
reg [7:0] cfg_max_iterations;reg [23:0] cfg_tolerance;reg cfg_mixed;
reg [7:0] s_source,s_target;reg s_mask,s_valid=0,s_sof=0,s_eol=0;wire s_ready;
wire [7:0] m_gray;wire m_valid;reg m_ready=0;wire m_sof,m_eol,m_last;
wire [7:0] iterations;wire converged;wire [23:0] residual;
wire done_valid;reg done_ready=0;wire done_error;wire [3:0] error_code;wire busy;
poisson_blend_frame #(.WIDTH(W),.HEIGHT(H)) dut(.*);
integer cycles=0,got=0,frame=0,i;reg [10:0] expected[0:N-1];reg signed [27:0] expected_state[0:N-1];
reg [31:0] noise=32'h83927111;reg stalls=0;reg [10:0] held;reg was_stalled=0;
always @(negedge clk)begin
noise=noise^(noise<<13);noise=noise^(noise>>17);noise=noise^(noise<<5);
if(stalls)begin ce=noise[0]|noise[1];m_ready=noise[2]|noise[3];end end
always @(posedge clk)begin
cycles=cycles+1;if(cycles>25000000)$fatal(1,"timeout frame%0d state%0d",frame,dut.state);
if(rst_n)begin
if(was_stalled&&{m_last,m_eol,m_sof,m_gray}!==held)$fatal(1,"unstable output");
was_stalled=m_valid&&!(ce&&m_ready);held={m_last,m_eol,m_sof,m_gray};
if(m_valid&&ce&&m_ready)begin
if({m_last,m_eol,m_sof,m_gray}!==expected[got])$fatal(1,"pixel frame%0d pos%0d actual%h expected%h",frame,got,{m_last,m_eol,m_sof,m_gray},expected[got]);got=got+1;end end end
task tick;begin @(posedge clk);#1;end endtask
task ack;begin @(negedge clk);done_ready=1;@(posedge clk);while(!ce)@(posedge clk);#1;done_ready=0;end endtask
task send(input [7:0] a,b,input mask,sof,eol);begin
@(negedge clk);s_source=a;s_target=b;s_mask=mask;s_sof=sof;s_eol=eol;s_valid=1;
@(posedge clk);while(!s_ready)@(posedge clk);#1;s_valid=0;end endtask
task begin_frame(input [7:0] lim,input [23:0] tolerance,input mixed);begin
while(!start_ready)tick();@(negedge clk);cfg_max_iterations=lim;cfg_tolerance=tolerance;cfg_mixed=mixed;start_valid=1;
@(posedge clk);while(!start_ready)@(posedge clk);#1;start_valid=0;
cfg_max_iterations=0;cfg_tolerance=24'hffffff;cfg_mixed=!mixed;got=0;end endtask
initial begin tick();tick();rst_n=1;ce=1;m_ready=1;stalls=1;
BODY
$display("PASS cycles=%0d",cycles);$finish;end
endmodule
'''
def test_profile(w,h,fixtures):
    n=w*h;body=[];linear=[];converged=0
    for idx,(src,dst,mask,limit,tolerance,mixed,bad) in enumerate(fixtures):
        r=oracle(src,dst,mask,w,h,limit,tolerance,mixed);converged+=r['converged']
        solution=sparse_solve(src,dst,mask,w,h,mixed)
        difference=max(abs(v/256-s) for v,s in zip(r['values'],solution))
        # The discrete residual gives a conservative inverse-Laplacian error bound.
        # A rectangle barrier x(W-1-x)/2 has Laplacian 1, including mask holes.
        bound=r['residual']/256*max(0,((w-1)**2)/8)
        assert difference<=bound+1e-7,(w,h,idx,difference,bound)
        linear.append(dict(frame=idx,active=r['active'],iterations=r['iterations'],converged=bool(r['converged']),residual_q8=r['residual'],max_unclipped_value_error_vs_sparse=float(difference),residual_error_bound=float(bound)))
        for i,p in enumerate(r['output']):
            value=p|((i==0)<<8)|((i%w==w-1)<<9)|((i==n-1)<<10)
            body.append(f"expected[{i}]=11'h{value:x};expected_state[{i}]=28'h{r['values'][i]&((1<<28)-1):x};")
        body.append(f"frame={idx};begin_frame(8'd{limit},24'd{tolerance},1'b{mixed});")
        for i,(a,b,m) in enumerate(zip(src,dst,mask)):
            body.append(f"send(8'd{a},8'd{b},1'b{int(m)},1'b{int((i==0)^(bad==1 and i==0))},1'b{int((i%w==w-1)^(bad==2 and i==n-1))});")
        body.append(f"while(!done_valid)tick();if(got!={n}||done_error!=1'b{int(bool(bad))}||error_code!=4'd{2 if bad else 0})$fatal(1,\"DONE/length\");")
        for name,bits,value in [('iterations',8,r['iterations']),('converged',1,r['converged']),('residual',24,min(0xffffff,r['residual']))]:
            body.append(f"if({name}!=={bits}'d{value})$fatal(1,\"{name} frame{idx} actual%0d expected{value}\",{name});")
        body.append(f"for(i=0;i<{n};i=i+1)if(dut.solution_mem[i]!==expected_state[i])$fatal(1,\"internal Q8 frame{idx} addr%0d\",i);")
        body.append("repeat(7)tick();if(!done_valid)$fatal(1,\"DONE hold\");ack();")
        if idx==0:
            body.append("begin_frame(8'd0,24'd0,1'b1);while(!done_valid)tick();if(!done_error||error_code!=1||got!=0)$fatal(1,\"invalid config\");")
            body.append(f"if(iterations!={r['iterations']}||converged!={r['converged']}||residual!={min(0xffffff,r['residual'])})$fatal(1,\"invalid START corrupts stats\");ack();")
    # Reset while capturing with CE disabled, then actually process a recovery frame.
    body.append("begin_frame(8'd5,24'd0,1'b0);stalls=0;@(negedge clk);ce=0;rst_n=0;tick();if(busy||m_valid||done_valid)$fatal(1,\"disabledCE reset\");rst_n=1;ce=1;m_ready=1;begin_frame(8'd255,24'd0,1'b0);")
    for i in range(n):
        val=55|((i==0)<<8)|((i%w==w-1)<<9)|((i==n-1)<<10)
        body.append(f"expected[{i}]=11'h{val:x};send(8'd19,8'd55,1'b1,1'b{int(i==0)},1'b{int(i%w==w-1)});")
    body.append(f"while(!done_valid)tick();if(got!={n}||done_error||iterations!=1||!converged||residual!=0)$fatal(1,\"reset recovery\");ack();")
    tb=TB.replace('BODY','\n'.join(body)).replace('.WIDTH(W),.HEIGHT(H)',f'.WIDTH({w}),.HEIGHT({h})').replace('[0:N-1]',f'[0:{n-1}]')
    with tempfile.TemporaryDirectory(prefix='poisson_test_') as temporary:
        td=Path(temporary);(td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'poisson_blend_frame.sv',td/'tb.sv'],HERE,td/'compile.log')
        out=execute(['vvp',td/'sim'],HERE,td/'sim.log',timeout=180);assert 'PASS' in out;print(w,h,out.strip(),flush=True)
    return dict(width=w,height=h,frames=len(fixtures)+1,pixels=n*(len(fixtures)+1),invalid_configs=1,converged_frames=converged+1,linear_comparisons=linear)
def opencv_compare():
    import cv2,numpy as np
    w=h=32;src=[(x*9+y*3)%256 for y in range(h) for x in range(w)];dst=[(x*2+y*5+35)%256 for y in range(h) for x in range(w)]
    mask=[int(5<=x<27 and 5<=y<27) for y in range(h) for x in range(w)]
    results=[]
    source=np.repeat(np.array(src,dtype=np.uint8).reshape(h,w,1),3,axis=2)
    target=np.repeat(np.array(dst,dtype=np.uint8).reshape(h,w,1),3,axis=2)
    for mixed in (0,1):
        r=oracle(src,dst,mask,w,h,255,4,mixed)
        # bounding box (5,5)..(26,26) has center(16,16), preserving coordinates.
        clone=cv2.seamlessClone(source,target,np.array(mask,dtype=np.uint8).reshape(h,w)*255,(16,16),cv2.MIXED_CLONE if mixed else cv2.NORMAL_CLONE)
        diff=np.abs(clone[:,:,0].astype(int)-np.array(r['output']).reshape(h,w))
        results.append(dict(mode='MIXED_CLONE' if mixed else 'NORMAL_CLONE',pixels=w*h,max_gray_difference=int(diff.max()),mean_gray_difference=float(diff.mean()),note='Actual OpenCV RGB-domain seamlessClone uses different ROI/boundary/discretization/solver; measured comparison only, no bit-exact claim.'))
    return dict(version=cv2.__version__,comparisons=results)
if __name__=='__main__':
    rng=random.Random(392213);profiles=[]
    for w,h,total in [(1,1,5),(1,7,5),(7,7,18),(16,9,8),(32,32,6)]:
        fixtures=[];n=w*h
        for i in range(total):
            src=[rng.randrange(256) for _ in range(n)];dst=[rng.randrange(256) for _ in range(n)]
            mask=[True]*n;limit=64 if n<1024 else 32;tolerance=4;mixed=i%2
            if i%8==0:mask=[False]*n
            elif i%8==1:dst=src[:]
            elif i%8==2:mask=[j==n//2 for j in range(n)]
            elif i%8==3:mask=[rng.randrange(3)!=0 for _ in range(n)]
            elif i%8==4:
                src=[255 if j%w in (0,w-1) or j//w in (0,h-1) else 0 for j in range(n)];dst=[0]*n;mixed=0
            elif i%8==5:
                src=[0 if j%w in (0,w-1) or j//w in (0,h-1) else 255 for j in range(n)];dst=[255]*n;mixed=0
            elif i%8==6:limit=1;tolerance=0
            elif i%8==7:limit=255;tolerance=8
            if i==11:tolerance=0xffffff
            fixtures.append((src,dst,mask,limit,tolerance,mixed,1 if i==total-2 else 2 if i==total-1 else 0))
        profiles.append(test_profile(w,h,fixtures))
    comparison=opencv_compare()
    (HERE/'test_evidence.json').write_text(json.dumps(dict(status='PASS',profiles=profiles,opencv=comparison,rtl_sha256=hashlib.sha256((HERE/'poisson_blend_frame.sv').read_bytes()).hexdigest()),indent=2)+'\n',encoding='utf-8');print('ALL PASS')
