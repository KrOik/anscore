"""All-256-threshold exhaustive Fraction oracle and actual skimage reference."""
from pathlib import Path
from fractions import Fraction
import sys,json,hashlib,tempfile
import numpy as np
from skimage.filters import threshold_multiotsu
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'multi_otsu.sv'
def hashes():return {RTL.name:hashlib.sha256(RTL.read_bytes()).hexdigest()}
def score(a,t0,t1):
 groups=[a[a<=t0],a[(a>t0)&(a<=t1)],a[a>t1]]
 if any(len(g)==0 for g in groups):return None
 return sum((Fraction(sum(map(int,g))**2,len(g)) for g in groups),Fraction(0))
def oracle(a):
 hist=np.bincount(a.ravel(),minlength=256);counts=np.cumsum(hist);sums=np.cumsum(hist*np.arange(256));total=len(a.ravel());total_sum=int(sums[-1])
 best=None;thresholds=None;ties=0
 # Deliberately enumerate all intensity thresholds, including empty histogram bins.
 for t0 in range(255):
  n0=int(counts[t0]);s0=int(sums[t0])
  if not n0:continue
  for t1 in range(t0+1,255):
   n1=int(counts[t1])-n0;n2=total-int(counts[t1])
   if n1==0 or n2==0:continue
   s1=int(sums[t1])-s0;s2=total_sum-int(sums[t1])
   q=Fraction(s0*s0,n0)+Fraction(s1*s1,n1)+Fraction(s2*s2,n2)
   if best is None or q>best:best=q;thresholds=(t0,t1);ties=1
   elif q==best:ties+=1
 if best is None:return None
 return thresholds,best,ties

BASE=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[5:0]cfg_width=WW,cfg_height=HH;reg[7:0]cfg_level0=L0,cfg_level1=L1,cfg_level2=L2,s_data=0;
 wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;wire[7:0]m_data,error_code,threshold0,threshold1;wire[1:0]m_class;
 multi_otsu dut(.*);
 localparam W=WW,H=HH,N=W*H;localparam[127:0] OBJNUM=ONUM,OBJDEN=ODEN;
 wire[127:0]score_left=dut.best_a*OBJDEN,score_right=OBJNUM*dut.best_den;
 reg[7:0]pixels[0:N-1];reg[12:0]expected[0:N-1];reg[12:0]held;reg stalled=0;
 integer cyc=0,got=0,i,rep;
 wire[12:0]token={m_class,m_last,m_eol,m_sof,m_data};
 always @(negedge clk)begin cyc=cyc+1;ce=cyc%11>1;m_ready=cyc%7<4;if(cyc>40000000)$fatal(1,"timeout %d",dut.state);end
 always @(posedge clk)if(rst_n)begin
  if(stalled&&(!m_valid||held!==token))$fatal(1,"unstable output");
  stalled=m_valid&&!(ce&&m_ready);held=token;
  if(ce&&dut.state==8&&(dut.run_count!=N||dut.run_sum!=SUM))$fatal(1,"histogram totals %d %d",dut.run_count,dut.run_sum);
  if(ce&&m_valid&&m_ready)begin if(got>=N||token!==expected[got])$fatal(1,"pixel %d got %h expected %h",got,token,expected[got]);got=got+1;end
 end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin
 INITDATA
 repeat(3)tick;rst_n=1;
 for(rep=0;rep<RR;rep=rep+1)begin
  got=0;cfg_width=W;cfg_height=H;cfg_level0=L0;cfg_level1=L1;cfg_level2=L2;
  while(!start_ready)tick;start_valid=1;tick;start_valid=0;
  cfg_width=0;cfg_height=0;cfg_level0=255;cfg_level1=0;cfg_level2=0;
  for(i=0;i<N;i=i+1)begin
   if(i%5==0)repeat(2)tick;
   s_data=pixels[i];s_sof=i==0;s_eol=i%W==W-1;s_last=i==N-1;
   while(!s_ready)tick;s_valid=1;tick;s_valid=0;
  end
  while(!done_valid)tick;
  if(done_error||error_code||got!=N||threshold0!=T0||threshold1!=T1||score_left!==score_right)$fatal(1,"bad done err=%h got=%d thresholds=%d,%d",error_code,got,threshold0,threshold1);
  abort=1;repeat(9)begin tick;if(!done_valid||done_error||error_code||threshold0!=T0||threshold1!=T1)$fatal(1,"held done late abort");end abort=0;
  while(!ce)tick;done_ready=1;tick;done_ready=0;tick;
 end
 $display("MULTIOTSU OK pixels=%d",got);$finish;
 end
endmodule'''

def simulate(tb,label):
 with tempfile.TemporaryDirectory(prefix='multiotsu_'+label+'_') as d:
  d=Path(d);(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',str(d/'sim.vvp'),str(RTL),str(d/'tb.sv')],d,d/'compile.log')
  text=execute(['vvp',str(d/'sim.vvp')],d,d/'run.log',timeout=300)
  assert 'MULTIOTSU OK' in text,text

def run(label,a,levels=(0,127,255),replays=1):
 result=oracle(a);assert result is not None
 thresholds,best,ties=result
 reference=tuple(map(int,threshold_multiotsu(a,classes=3)))
 ref_score=score(a.ravel(),*reference)
 assert ref_score==best,(label,thresholds,reference,best,ref_score)
 classes=np.digitize(a,thresholds,right=True).astype(np.uint8);expected=np.take(levels,classes)
 ref_classes=np.digitize(a,reference,right=True).astype(np.uint8)
 same_classes=bool(np.array_equal(classes,ref_classes))
 if not same_classes:assert reference!=thresholds and ties>1
 h,w=a.shape
 init='\n'.join(f"pixels[{i}]=8'd{int(v)};expected[{i}]=13'h{(int(c)<<11)|((i==w*h-1)<<10)|((i%w==w-1)<<9)|((i==0)<<8)|int(o):04x};" for i,(v,c,o) in enumerate(zip(a.flat,classes.flat,expected.flat)))
 tb=BASE
 for key,val in [('INITDATA',init),('ONUM',best.numerator),('ODEN',best.denominator),('WW',w),('HH',h),('L0',levels[0]),('L1',levels[1]),('L2',levels[2]),('RR',replays),('SUM',int(a.sum())),('T0',thresholds[0]),('T1',thresholds[1])]:tb=tb.replace(key,str(val))
 simulate(tb,label)
 row=dict(label=label,width=w,height=h,frames=replays,status='PASS',thresholds=thresholds,objective_numerator=best.numerator,objective_denominator=best.denominator,tied_all_intensity_pairs=ties,skimage_thresholds=reference,skimage_same_classification=same_classes,skimage_different_class_pixels=int(np.count_nonzero(classes!=ref_classes)),output_levels=levels,class_counts=np.bincount(classes.ravel(),minlength=3).tolist(),output_sha256=hashlib.sha256(expected.astype(np.uint8).tobytes()).hexdigest())
 print(row,flush=True);return row

if __name__=='__main__':
 rng=np.random.default_rng(20261020)
 cases=[('three_values',np.array([[0,0,0,63,63,63,255,255]],dtype=np.uint8),(0,127,255),2),('nonzero_min_gap_ties',np.array([[20,20,80,80],[220,220,220,80]],dtype=np.uint8),(10,100,240),1),('four_equal_tie',np.array([[0,80,160,240]]*3,dtype=np.uint8),(0,128,255),1),('random_sparselevels',rng.choice(np.array([0,7,33,55,97,129,168,211,255],np.uint8),(8,9)),(1,60,250),1),('nearwhite',rng.choice(np.array([252,253,254,255],np.uint8),(7,7)),(0,127,255),1),('ramp_all256',np.arange(256,dtype=np.uint8).reshape(16,16),(0,127,255),1),('maximum32_three_modes',rng.choice(np.array([5,6,7,120,121,122,248,249,250],np.uint8),(32,32)),(0,127,255),1),('row',np.array([[0,10,11,100,101,102,254,255]],np.uint8),(0,127,255),1),('column',np.array([[0],[125],[126],[255]],np.uint8),(0,127,255),1)]
 skew=np.zeros((32,32),np.uint8);skew[-1,-2:]=[254,255]
 cases.append(('maximum32_skew1022',skew,(0,127,255),1))
 results=[run(*c) for c in cases]
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),cases=results,reference='Actual skimage threshold_multiotsu classes3; inclusive-lower bins via digitize right=True; all selected exact objectives match; distinct exact-optimum tie classifications explicitly recorded',board=False),indent=2)+'\n')
