"""Top-level failure, abort, held completion, and CE-low reset recovery."""
import hashlib,importlib.util,json,shutil,sys,tempfile
from pathlib import Path
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from test_lab_kmeans_quantizer import SOURCES,LAB,cluster,packed_rgb
from tooling import execute

spec=importlib.util.spec_from_file_location('lab_error_oracle',LAB/'oracle.py')
reference=importlib.util.module_from_spec(spec);spec.loader.exec_module(reference)
pixels=[(10,40,90),(240,20,40),(20,180,230),(190,220,30),(70,80,90),(230,200,180)]
lab=[reference.oracle(p,False) for p in pixels]
initial,centers,labels,counts,inertia,iterations,converged=cluster(lab,2,8,0,999)
rgb=[reference.oracle(centers[j],True) for j in labels]
expected=[packed_rgb(p)|(j<<24)|((i==0)<<26)|((i%3==2)<<27)|((i==5)<<28) for i,(p,j) in enumerate(zip(rgb,labels))]
pi=sum(packed_rgb(p)<<(24*j) for j,p in enumerate(initial));pf=sum(packed_rgb(p)<<(24*j) for j,p in enumerate(centers))
pc=sum(n<<(11*j) for j,n in enumerate(counts));stats=pi|(pf<<96)|(pc<<192)|(inertia<<236)|(iterations<<268)|(int(converged)<<276)
inputs=SOURCES+[LAB/n for n in ('decode.mem','nonlinear.mem','oracle.py','coefficients.json')]
hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}

tb=r'''module tb;
 localparam W=3,H=2,N=6;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,abort=0,done_ready=0;
 reg[2:0]cfg_k=2;reg[7:0]cfg_max_iterations=8,cfg_tolerance=0;reg[31:0]cfg_seed=999;
 reg[23:0]s_rgb=0;reg s_valid=0,s_sof=0,s_eol=0,m_ready=0;
 wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy,converged;
 wire[23:0]m_rgb;wire[1:0]m_label;wire[7:0]iterations,error_code;
 wire[31:0]inertia;wire[95:0]initial_centers_lab,final_centers_lab;wire[43:0]cluster_counts;
 lab_kmeans_quantizer #(.WIDTH(W),.HEIGHT(H)) dut(.*);
 reg[23:0]pixels[0:N-1];reg[28:0]expected[0:N-1];
 wire[28:0]token={m_last,m_eol,m_sof,m_label,m_rgb};
 wire[276:0]statistics={converged,iterations,inertia,cluster_counts,final_centers_lab,initial_centers_lab};
 localparam[276:0]GOLD=277'h@STATS@;
 integer i,phase,count=0,healthy_frames=0,cycles=0;reg check_pixels=0;reg[7:0]saved_code;
 always @(posedge clk)begin
  cycles=cycles+1;if(cycles>1000000)$fatal(1,"watchdog top=%d k=%d lab=%d",dut.state,dut.cluster.state,dut.color.state);
  if(rst_n&&ce&&m_valid&&m_ready&&check_pixels)begin
   if(count>=N||token!==expected[count])$fatal(1,"healthy pixel %d got=%h expected=%h",count,token,expected[count]);
   count=count+1;
  end
 end
 task tick;begin @(negedge clk);#1;end endtask
 task reset;
 begin tick;rst_n=0;ce=0;start_valid=0;s_valid=0;abort=0;m_ready=0;done_ready=0;check_pixels=0;
 tick;if(done_valid||m_valid||start_ready||s_ready)$fatal(1,"CE-low reset validity");
 rst_n=1;ce=1;tick;end endtask
 task start;
 begin while(!start_ready)tick;start_valid=1;tick;start_valid=0;end endtask
 task feed;
 input integer bad;
 begin
  for(i=0;i<N;i=i+1)begin
   s_rgb=pixels[i];s_sof=i==0;s_eol=i%W==W-1;
   if(bad==1&&i==0)s_sof=0;
   if(bad==2&&i==0)s_eol=1;
   if(bad==3&&i==W-1)s_eol=0;
   while(!s_ready)tick;s_valid=1;tick;s_valid=0;
  end
 end endtask
 task acknowledge;
 begin done_ready=1;tick;done_ready=0;tick;end endtask
 task error_result;
 input[7:0]expected_code;
 begin
  while(!done_valid)tick;
  if(!done_error||error_code!==expected_code||m_valid||!busy)$fatal(1,"error got=%h expected=%h",error_code,expected_code);
  saved_code=error_code;abort=1;
  repeat(4)begin tick;if(!done_valid||!done_error||error_code!==saved_code||m_valid)$fatal(1,"held FAILED");end
  ce=0;done_ready=1;repeat(3)tick;if(!done_valid||error_code!==saved_code)$fatal(1,"CE-gated failed ACK");
  done_ready=0;abort=0;ce=1;acknowledge;
 end endtask
 task healthy;
 begin
  cfg_k=2;cfg_max_iterations=8;cfg_tolerance=0;cfg_seed=999;
  count=0;check_pixels=1;m_ready=1;start;feed(0);
  while(!done_valid)tick;
  if(done_error||error_code||count!=N||statistics!==GOLD)$fatal(1,"healthy completion count=%d stats=%h gold=%h",count,statistics,GOLD);
  abort=1;repeat(4)begin tick;if(!done_valid||done_error||error_code||statistics!==GOLD)$fatal(1,"late abort changed DONE");end
  ce=0;done_ready=1;repeat(3)tick;if(!done_valid||done_error||error_code)$fatal(1,"CE-gated success ACK");
  done_ready=0;abort=0;ce=1;acknowledge;check_pixels=0;m_ready=0;healthy_frames=healthy_frames+1;
 end endtask
 initial begin
  $readmemh("pixels.hex",pixels);$readmemh("expected.hex",expected);reset;
  for(phase=1;phase<=3;phase=phase+1)begin
   cfg_k=2;cfg_max_iterations=8;start;feed(phase);
   case(phase)1:error_result(8'h11);2:error_result(8'h18);3:error_result(8'h14);endcase
   healthy;
  end
  cfg_k=0;start;error_result(8'h21);healthy;
  cfg_max_iterations=0;start;error_result(8'h21);healthy;
  // Abort before full capture, during real Lloyd arithmetic, and held RGB output.
  cfg_k=2;cfg_max_iterations=8;start;
  s_rgb=pixels[0];s_sof=1;s_eol=0;while(!s_ready)tick;s_valid=1;tick;s_valid=0;
  abort=1;tick;error_result(8'h93);healthy;
  start;feed(0);while(dut.cluster.state!=9)tick;
  abort=1;tick;error_result(8'h93);healthy;
  start;feed(0);while(!m_valid)tick;
  abort=1;tick;error_result(8'h93);healthy;
  // Every reset cancels the active frame; each is followed by an exact healthy frame.
  for(phase=0;phase<6;phase=phase+1)begin
   start;
   if(phase==0)begin
    s_rgb=pixels[0];s_sof=1;s_eol=0;while(!s_ready)tick;s_valid=1;tick;s_valid=0;
   end else begin
    feed(0);
    case(phase)
     1:while(dut.cluster.state!=9)tick;
     2:while(dut.cluster.state!=18)tick;
     3:while(dut.state!=4||dut.color.state==1)tick;
     4:while(!m_valid)tick;
     5:begin m_ready=1;while(!done_valid)tick;end
    endcase
   end
   reset;healthy;
  end
  $display("ERROR_RECOVERY PASS healthy=%d",healthy_frames);$finish;
 end
endmodule'''.replace('@STATS@',f'{stats:x}')
with tempfile.TemporaryDirectory(prefix='lab_kmeans_errors_') as td:
 td=Path(td)
 for name in ('decode.mem','nonlinear.mem'):shutil.copyfile(LAB/name,td/name)
 (td/'pixels.hex').write_text(''.join(f'{packed_rgb(p):06x}\n' for p in pixels))
 (td/'expected.hex').write_text(''.join(f'{p:x}\n' for p in expected));(td/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,td/'compile.log')
 log=execute(['vvp',td/'sim'],td,td/'simulation.log',timeout=300)
 assert 'ERROR_RECOVERY PASS healthy=         14' in log,log
assert hashes=={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},'source changed during test'
report=dict(status='PASS',geometry=[3,2],healthy_recovery_frames=14,
 errors={'bad_sof':'11','early_eol':'18','missing_eol':'14','bad_k':'21','zero_iterations':'21'},
 abort=['forward capture','actual Lloyd square state','held RGB output'],
 held=['FAILED with abort','FAILED ACK CE0','successful DONE with abort','successful DONE ACK CE0'],
 reset_ce0=['partial forward','Lloyd square','centroid divider','inverse converter','held RGB output','held DONE'],
 golden='Independent Lab oracle + root integer Lloyd helper; all RGB, labels, markers, initial/final centers, counts, inertia, iteration and convergence checked on every healthy recovery frame',
 sources=hashes,board=False)
(HERE/'error_evidence.json').write_text(json.dumps(report,indent=2)+'\n');print(report)
