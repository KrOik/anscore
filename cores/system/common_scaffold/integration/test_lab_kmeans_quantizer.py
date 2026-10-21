"""Complete real RGB/Lab/Lloyd/Lab-inverse hierarchy, exact frame oracle."""
import hashlib
import importlib.util
import random
import shutil
import tempfile

from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

LAB = PACKAGE/'image/cielab_color'
SOURCES = [LAB/'rgb_cielab_stream.v',
           PACKAGE/'image/kmeans_segmentation/kmeans_rgb_frame.sv',
           PACKAGE/'image/lab_kmeans_quantizer/lab_kmeans_quantizer.sv']


def xorshift(v):
    v ^= (v << 13) & 0xffffffff
    v ^= v >> 17
    return (v ^ (v << 5)) & 0xffffffff


def cluster(pixels, k, maximum, tolerance, seed):
    state = seed or 1
    centers = []
    for _ in range(k):
        centers.append(pixels[state % len(pixels)])
        state = xorshift(state)
    initial = list(centers)
    converged = False
    for iteration in range(1, maximum+1):
        groups = [[] for _ in range(k)]
        for p in pixels:
            label = min(range(k), key=lambda j:sum((a-b)**2 for a,b in zip(p,centers[j])))
            groups[label].append(p)
        updated = [tuple((sum(p[c] for p in group)+len(group)//2)//len(group)
                         for c in range(3)) if group else centers[j]
                   for j,group in enumerate(groups)]
        converged = max(abs(a-b) for p,q in zip(centers,updated) for a,b in zip(p,q)) <= tolerance
        centers = updated
        if converged:
            break
    labels = [min(range(k),key=lambda j:sum((a-b)**2 for a,b in zip(p,centers[j])))
              for p in pixels]
    counts = [labels.count(j) for j in range(k)]
    inertia = sum(sum((a-b)**2 for a,b in zip(p,centers[j])) for p,j in zip(pixels,labels))
    return initial,centers,labels,counts,inertia,iteration,converged


def packed_rgb(p):
    return (p[0]<<16)|(p[1]<<8)|p[2]


TB = r'''module tb;
localparam W=@W@,H=@H@,N=W*H,F=@F@;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0,done_ready=0;
reg[2:0]cfg_k=2;reg[7:0]cfg_max_iterations=8,cfg_tolerance=0;reg[31:0]cfg_seed=0;
reg[23:0]s_rgb=0;reg s_valid=0,s_sof=0,s_eol=0,m_ready=0;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy,converged;
wire[23:0]m_rgb;wire[1:0]m_label;wire[7:0]iterations,error_code;
wire[31:0]inertia;wire[95:0]initial_centers_lab,final_centers_lab;wire[43:0]cluster_counts;
lab_kmeans_quantizer #(.WIDTH(W),.HEIGHT(H)) dut(.*);
reg[23:0]pixels[0:N*F-1];reg[28:0]expected[0:N*F-1];reg[276:0]stats[0:F-1];
reg[28:0]held;reg stalled=0;integer count=0,cycles=0,f,i;
wire[28:0]token={m_last,m_eol,m_sof,m_label,m_rgb};
wire[276:0]statistics={converged,iterations,inertia,cluster_counts,final_centers_lab,initial_centers_lab};
always @(negedge clk)begin cycles=cycles+1;ce=cycles%13!=0&&cycles%13!=1;m_ready=cycles%7!=0&&cycles%7!=1;end
always @(posedge clk)begin
 if(!rst_n)stalled=0;
 else begin
  if(stalled&&(!m_valid||token!==held))$fatal(1,"unstable output");
  stalled=m_valid&&!(ce&&m_ready);held=token;
  if(ce&&m_valid&&m_ready)begin
   if(count>=N*F||token!==expected[count])$fatal(1,"pixel %0d got=%h expected=%h",count,token,expected[count]);
   count=count+1;
  end
 end
end
task tick;begin @(negedge clk);#1;end endtask
initial begin
 $readmemh("pixels.hex",pixels);$readmemh("expected.hex",expected);$readmemh("stats.hex",stats);
 repeat(3)tick;rst_n=1;
 for(f=0;f<F;f=f+1)begin
  cfg_k=2+f%3;cfg_max_iterations=8;cfg_tolerance=f%2;cfg_seed=f==0?0:32'h35478a10+f;
  while(!start_ready)tick;start_valid=1;tick;start_valid=0;
  // Raw configuration changes immediately: children must retain START values.
  cfg_k=0;cfg_max_iterations=0;cfg_tolerance=255;cfg_seed=0;
  for(i=0;i<N;i=i+1)begin
   s_rgb=pixels[f*N+i];s_sof=i==0;s_eol=i%W==W-1;
   while(!s_ready)tick;s_valid=1;tick;s_valid=0;
  end
  while(!done_valid)tick;
  if(done_error||error_code||count!=(f+1)*N||statistics!==stats[f])
   $fatal(1,"completion frame=%0d error=%h stats=%h expected=%h count=%0d",f,error_code,statistics,stats[f],count);
  repeat(4)begin tick;if(!done_valid||!busy||m_valid||statistics!==stats[f])$fatal(1,"held DONE");end
  while(!ce)tick;done_ready=1;tick;done_ready=0;tick;
 end
 $display("LAB_KMEANS_FRAME PASS %0d frames %0dx%0d",F,W,H);$finish;
end
initial begin #1000000000;$fatal(1,"watchdog state=%d",dut.state);end
endmodule'''


def main():
    spec = importlib.util.spec_from_file_location('lab_reference', LAB/'oracle.py')
    reference = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reference)
    inputs = SOURCES+[LAB/n for n in ('oracle.py','coefficients.json','decode.mem','nonlinear.mem')]
    frozen = {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    folder = evidence_dir('lab_kmeans_quantizer')
    rng = random.Random(19238)
    reports = []
    with tempfile.TemporaryDirectory(prefix='lab_kmeans_quantizer_') as temporary:
        td = __import__('pathlib').Path(temporary)
        for name in ('decode.mem','nonlinear.mem'):
            shutil.copyfile(LAB/name,td/name)
        for w,h,frames in ((1,1,3),(7,5,3),(16,9,3),(32,32,1)):
            source=[];expected=[];statistics=[]
            for f in range(frames):
                pixels=[tuple(rng.randrange(256) for _ in range(3)) for _ in range(w*h)]
                if f==0:
                    pixels=[((x*9+y*3)%256,(x*5+y*11)%256,(x*2+y*7)%256)
                            for y in range(h) for x in range(w)]
                if f==2:
                    pixels=[(91,91,91)]*(w*h)  # All but one cluster may remain empty.
                lab=[reference.oracle(p,False) for p in pixels]
                k=2+f%3;seed=0 if f==0 else 0x35478a10+f
                initial,centers,labels,counts,inertia,iterations,converged=cluster(lab,k,8,f%2,seed)
                rgb=[reference.oracle(centers[j],True) for j in labels]
                source.extend(packed_rgb(p) for p in pixels)
                expected.extend(packed_rgb(p)|(j<<24)|((i==0)<<26)|((i%w==w-1)<<27)|((i==w*h-1)<<28)
                                for i,(p,j) in enumerate(zip(rgb,labels)))
                pi=sum(packed_rgb(p)<<(24*j) for j,p in enumerate(initial))
                pf=sum(packed_rgb(p)<<(24*j) for j,p in enumerate(centers))
                pc=sum(n<<(11*j) for j,n in enumerate(counts))
                statistics.append(pi|(pf<<96)|(pc<<192)|(inertia<<236)|(iterations<<268)|(int(converged)<<276))
                reports.append(dict(width=w,height=h,frame=f,k=k,iterations=iterations,converged=converged,
                                    empty_clusters=counts.count(0),encoded_lab_inertia=inertia,pixels=w*h,status='PASS'))
            for name,values in (('pixels',source),('expected',expected),('stats',statistics)):
                (td/f'{name}.hex').write_text(''.join(f'{v:x}\n' for v in values),encoding='utf-8')
            tb=TB.replace('@W@',str(w)).replace('@H@',str(h)).replace('@F@',str(frames))
            (td/'tb.sv').write_text(tb,encoding='utf-8')
            tag=f'{w}x{h}'
            execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],ROOT,folder/f'{tag}_compile.log')
            output=execute(['vvp',td/'sim'],td,folder/f'{tag}_simulation.log',timeout=300)
            assert 'LAB_KMEANS_FRAME PASS' in output
            print(tag,'PASS',flush=True)
    assert frozen=={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    write_json(folder/'results.json',dict(status='PASS',frames=len(reports),results=reports,sources=frozen,
        scope='Actual RGB->D65 Lab8->integer Lloyd clustering->RGB using one reused converter. Distance is squared Euclidean in encoded Lab8, not unscaled CIE DeltaE. Exact pixels, labels, initial/final centers, counts, inertia and convergence; CE/backpressure, START snapshots and held completion.',board_tested=False))
    print(folder)


if __name__=='__main__':
    main()
