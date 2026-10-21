"""Independent integer Lloyd reference and real sklearn comparison; transient binaries."""
from pathlib import Path
import sys,tempfile,json,hashlib,random,datetime,urllib.request
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
def advance(a):
    a=(a^(a<<13))&0xffffffff;a^=a>>17;return (a^(a<<5))&0xffffffff
def oracle(pixels,k,limit,tol,seed):
    a=seed or 1;centers=[]
    for _ in range(k):centers.append(list(pixels[a%len(pixels)]));a=advance(a)
    initial=[p[:] for p in centers]
    def assign():return [min(range(k),key=lambda j:sum((p[c]-centers[j][c])**2 for c in range(3))) for p in pixels]
    for iteration in range(1,limit+1):
        labels=assign();updated=[]
        for j in range(k):
            members=[p for p,l in zip(pixels,labels) if l==j];n=len(members)
            updated.append([(sum(p[c] for p in members)+n//2)//n for c in range(3)] if n else centers[j][:])
        movement=max(abs(a-b) for p,q in zip(centers,updated) for a,b in zip(p,q));centers=updated
        if movement<=tol:break
    labels=assign();counts=[labels.count(j) for j in range(k)]
    inertia=sum(sum((p[c]-centers[l][c])**2 for c in range(3)) for p,l in zip(pixels,labels))
    return dict(initial=initial,centers=centers,labels=labels,counts=counts,iterations=iteration,converged=int(movement<=tol),inertia=inertia)
def rgb(p):return (p[0]<<16)|(p[1]<<8)|p[2]
def packed(v,bits):return sum(x<<(bits*i) for i,x in enumerate(v))
TB='''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=0,start_valid=0;wire start_ready;
reg [2:0] cfg_k;reg [7:0] cfg_max_iterations,cfg_tolerance;reg [31:0] cfg_seed;
reg [23:0] s_rgb;reg s_valid=0,s_sof=0,s_eol=0;wire s_ready;
wire [23:0] m_rgb;wire [1:0] m_label;wire m_valid;reg m_ready=0;wire m_sof,m_eol,m_last;
wire [95:0] initial_centers,final_centers;wire [43:0] cluster_counts;wire [7:0] iterations;
wire converged;wire [31:0] inertia;wire done_valid;reg done_ready=0;wire done_error;wire [3:0] error_code;wire busy;
kmeans_rgb_frame #(.WIDTH(W),.HEIGHT(H)) dut(.*);
integer cycles=0,got=0,frame=0,i;reg [29:0] expected[0:N-1];
reg [31:0] noise=32'h12345678;reg stalls=0;reg [29:0] held;reg was_stalled=0;
always @(negedge clk)begin
noise=noise^(noise<<13);noise=noise^(noise>>17);noise=noise^(noise<<5);
if(stalls)begin ce=noise[0]|noise[1];m_ready=noise[2]|noise[3];end
end
always @(posedge clk)begin
cycles=cycles+1;if(cycles>12000000)$fatal(1,"timeout");
if(cycles%1000000==0)$display("progress state=%0d frame=%0d got=%0d ce=%0d ready=%0d",dut.state,frame,got,ce,m_ready);
if(rst_n)begin
if(was_stalled && {m_last,m_eol,m_sof,m_label,m_rgb}!==held)$fatal(1,"unstable output");
was_stalled=m_valid&&!(ce&&m_ready);held={m_last,m_eol,m_sof,m_label,m_rgb};
if(m_valid&&ce&&m_ready)begin
if({m_last,m_eol,m_sof,m_label,m_rgb}!==expected[got])$fatal(1,"pixel frame=%0d pos=%0d actual=%h expected=%h",frame,got,{m_last,m_eol,m_sof,m_label,m_rgb},expected[got]);got=got+1;end
end end
task tick;begin @(posedge clk);#1;end endtask
task ack;begin @(negedge clk);done_ready=1;@(posedge clk);while(!ce)@(posedge clk);#1;done_ready=0;end endtask
task send(input [23:0] p,input sof,input eol);begin
@(negedge clk);s_rgb=p;s_sof=sof;s_eol=eol;s_valid=1;
@(posedge clk);while(!s_ready)@(posedge clk);#1;s_valid=0;
end endtask
task begin_frame(input [2:0] k,input [7:0] lim,input [7:0] tolerance,input [31:0] seed);begin
while(!start_ready)tick();@(negedge clk);cfg_k=k;cfg_max_iterations=lim;cfg_tolerance=tolerance;cfg_seed=seed;start_valid=1;
@(posedge clk);while(!start_ready)@(posedge clk);#1;start_valid=0;
cfg_k=7;cfg_max_iterations=0;cfg_tolerance=255;cfg_seed=0;got=0;
end endtask
initial begin tick();tick();rst_n=1;ce=1;m_ready=1;stalls=1;
BODY
$display("PASS frames=%0d cycles=%0d",frame,cycles);$finish;end
endmodule
'''
def test_profile(w,h,fixtures):
    n=w*h;body=[]
    for idx,(pixels,k,limit,tol,seed,bad) in enumerate(fixtures):
        r=oracle(pixels,k,limit,tol,seed)
        for i,l in enumerate(r['labels']):
            value=rgb(r['centers'][l])|(l<<24)|((i==0)<<26)|((i%w==w-1)<<27)|((i==n-1)<<28)
            body.append(f"expected[{i}]=30'h{value:x};")
        body.append(f"frame={idx};begin_frame(3'd{k},8'd{limit},8'd{tol},32'h{seed:x});")
        for i,p in enumerate(pixels):body.append(f"send(24'h{rgb(p):06x},1'b{int((i==0)^(bad==1 and i==0))},1'b{int((i%w==w-1)^(bad==2 and i==n-1))});")
        body.append("while(!done_valid)tick();")
        body.append(f"if(got!={n}||done_error!=1'b{int(bool(bad))}||error_code!=4'd{2 if bad else 0})$fatal(1,\"done/length %0d %0d %0d\",got,done_error,error_code);")
        vals=dict(initial_centers=(96,packed([rgb(p) for p in r['initial']],24)),final_centers=(96,packed([rgb(p) for p in r['centers']],24)),cluster_counts=(44,packed(r['counts'],11)),iterations=(8,r['iterations']),converged=(1,r['converged']),inertia=(32,r['inertia']))
        for name,(bits,value) in vals.items():body.append(f"if({name}!=={bits}'h{value:x})$fatal(1,\"{name} frame={idx} actual=%h expected={value:x}\",{name});")
        body.append("repeat(5)tick();if(!done_valid)$fatal(1,\"DONE hold\");ack();")
        # Invalid configurations must preserve the successful preceding statistics.
        if idx==0:
            for ik,il in [(0,4),(1,4),(5,4),(7,4),(2,0)]:
                body.append(f"begin_frame(3'd{ik},8'd{il},8'd0,32'd1);while(!done_valid)tick();if(!done_error||error_code!=1||got!=0)$fatal(1,\"bad config\");")
                for name,(bits,value) in vals.items():body.append(f"if({name}!=={bits}'h{value:x})$fatal(1,\"invalid cfg corrupts {name}\");")
                body.append("ack();")
    # synchronous reset must work while CE is disabled, even during capture
    body.append("begin_frame(3'd2,8'd3,8'd0,32'd1);stalls=0;@(negedge clk);ce=0;rst_n=0;tick();if(busy||m_valid||done_valid)$fatal(1,\"disabled CE reset\");rst_n=1;ce=1;m_ready=1;")
    # Recovery must actually process a fresh full frame after disabled-CE reset.
    body.append("begin_frame(3'd2,8'd255,8'd0,32'd0);")
    for i in range(n):
        value=0x123456|((i==0)<<26)|((i%w==w-1)<<27)|((i==n-1)<<28)
        body.append(f"expected[{i}]=30'h{value:x};send(24'h123456,1'b{int(i==0)},1'b{int(i%w==w-1)});")
    body.append(f"while(!done_valid)tick();if(got!={n}||done_error||iterations!=1||!converged||inertia!=0||cluster_counts!=44'd{n})$fatal(1,\"reset recovery\");ack();")
    tb=TB.replace('BODY','\n'.join(body)).replace('.WIDTH(W),.HEIGHT(H)',f'.WIDTH({w}),.HEIGHT({h})').replace('[0:N-1]',f'[0:{n-1}]')
    with tempfile.TemporaryDirectory(prefix='kmeans_test_') as temporary:
        td=Path(temporary);(td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'kmeans_rgb_frame.sv',td/'tb.sv'],HERE,td/'compile.log')
        out=execute(['vvp',td/'sim'],HERE,td/'sim.log',timeout=180)
        assert 'PASS' in out;print(w,h,out.strip(),flush=True)
    return dict(width=w,height=h,frames=len(fixtures)+1,pixels=n*(len(fixtures)+1),invalid_configs=5,disabled_ce_reset_and_recovery=True)
def reference_comparison():
    import numpy as np
    from sklearn.cluster import KMeans
    # Integral, widely separated symmetric groups have exactly the same floating
    # and rounded means. Arbitrary images are NOT claimed sklearn-bit-exact.
    results=[]
    for k in (2,3,4):
        pixels=[]
        for j in range(k):
            c=25+j*55
            pixels.extend([(c+d,c-d,c) for d in (-8,-4,0,4,8)])
        seed=next(s for s in range(1,10000) if len(set(i//5 for i in _indices(s,len(pixels),k)))==k)
        r=oracle(pixels,k,40,0,seed)
        fit=KMeans(n_clusters=k,init=np.array(r['initial'],dtype=float),n_init=1,max_iter=40,tol=0,algorithm='lloyd').fit(np.array(pixels,dtype=float))
        assert np.array_equal(fit.labels_,r['labels']);assert np.array_equal(fit.cluster_centers_,r['centers']);assert fit.inertia_==r['inertia']
        results.append(dict(k=k,seed=seed,pixels=len(pixels),labels_exact=True,centers_exact=True,inertia=r['inertia']))
    rng=random.Random(1121)
    random_results=[]
    for k in (2,3,4):
        for seed in (31,211,901):
            pixels=[tuple(rng.randrange(256) for _ in range(3)) for _ in range(35)]
            r=oracle(pixels,k,64,0,seed)
            fit=KMeans(n_clusters=k,init=np.array(r['initial'],dtype=float),n_init=1,max_iter=64,tol=0,algorithm='lloyd').fit(np.array(pixels,dtype=float))
            random_results.append(dict(k=k,seed=seed,pixels=35,label_disagreement=int(np.count_nonzero(fit.labels_!=r['labels'])),max_center_channel_difference=float(np.max(np.abs(fit.cluster_centers_-np.array(r['centers'])))),integer_inertia=r['inertia'],sklearn_float_inertia=float(fit.inertia_)))
    return dict(exact_integral_fixtures=results,arbitrary_random_comparisons=random_results,note='Identical initial centers and Lloyd assignment; hardware rounds half-up every iteration and retains empty centers. sklearn uses floating means and relocates empty centers. Arbitrary image equivalence is not asserted.')
def _indices(seed,n,k):
    a=seed or 1;out=[]
    for _ in range(k):out.append(a%n);a=advance(a)
    return out
if __name__=='__main__':
    rng=random.Random(74111);profiles=[]
    for w,h,total in [(1,1,8),(1,7,12),(7,5,28),(32,32,5)]:
        fixtures=[]
        for i in range(total):
            n=w*h;k=2+i%3;limit=1 if i%5==0 else 16;tol=255 if i%9==0 else 0;seed=0 if i%4==0 else rng.getrandbits(32)
            if i%6==0:pixels=[(77,77,77)]*n
            elif i%6==1:pixels=[((j%k)*255//(k-1),)*3 for j in range(n)]
            elif i%6==2:pixels=[(0,0,0) if j%2 else (255,255,255) for j in range(n)]
            else:pixels=[tuple(rng.randrange(256) for _ in range(3)) for _ in range(n)]
            fixtures.append((pixels,k,limit,tol,seed,1 if i==total-2 else 2 if i==total-1 else 0))
        profiles.append(test_profile(w,h,fixtures))
    comparison=reference_comparison()
    evidence=dict(status='PASS',profiles=profiles,sklearn_version=__import__('sklearn').__version__,sklearn_comparable_integral_fixtures=comparison,rtl_sha256=hashlib.sha256((HERE/'kmeans_rgb_frame.sv').read_bytes()).hexdigest())
    (HERE/'test_evidence.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8');print('ALL PASS')
