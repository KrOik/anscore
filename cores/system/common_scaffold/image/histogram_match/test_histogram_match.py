"""Exact brute-force Python CDF argmin oracle, plus NumPy cross-check."""
from pathlib import Path
import os,tempfile,subprocess,json,random,itertools,bisect
import numpy as np
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])

def oracle(pixels,histogram):
 n=len(pixels);total=sum(histogram);bins=len(histogram)
 counts=[0]*bins
 for pixel in pixels:counts[pixel]+=1
 source_cdf=list(itertools.accumulate(counts));ref_cdf=list(itertools.accumulate(histogram))
 reference_cross=[v*n for v in ref_cdf];mapping={}
 for pixel in set(pixels):
  target=source_cdf[pixel]*total
  # Scan ALL target intensities. Tuple ordering independently enforces low ties.
  mapping[pixel]=min((abs(cross-target),j) for j,cross in enumerate(reference_cross))[1]
  # Object integers preserve exact cross products, unlike float normalized CDFs.
  check=int(np.argmin(np.abs(np.asarray(reference_cross,dtype=object)-target)))
  assert mapping[pixel]==check
 full_mapping=[]
 for cdf in source_cdf:
  target=cdf*total;upper=bisect.bisect_left(reference_cross,target)
  choices=[upper]
  if upper:choices.append(bisect.bisect_left(reference_cross,reference_cross[upper-1]))
  full_mapping.append(min(choices,key=lambda j:(abs(reference_cross[j]-target),j)))
 assert all(full_mapping[p]==mapping[p] for p in pixels)
 output=[mapping[pixel] for pixel in pixels]
 occupied=np.flatnonzero(histogram)
 interp=np.interp(np.asarray([source_cdf[p] for p in pixels],dtype=float)/n,
                  np.asarray([ref_cdf[j] for j in occupied],dtype=float)/total,occupied)
 return output,full_mapping,{'max_difference_vs_skimage_interpolation_formula':float(np.max(np.abs(np.asarray(output)-interp))),
                'differing_pixels_vs_interpolation':int(np.count_nonzero(np.abs(np.asarray(output)-interp)>1e-9))}

def run():
 rng=random.Random(2026472);results=[]
 for bits,w,h,cw in ((8,1,1,8),(8,1,7,8),(8,7,1,8),(8,6,5,8),(8,3,2,24),(10,5,4,12),(12,4,3,8)):
  bins=1<<bits;d=bins-1;n=w*h;maximum=(1<<cw)-1
  refs=[]
  refs.append([maximum]*bins)
  constant=[0]*bins;constant[d//3]=7;refs.append(constant)
  bimodal=[0]*bins;bimodal[d//4]=1;bimodal[3*d//4]=1;refs.append(bimodal)
  random_hist=[0]*bins
  for _ in range(31):random_hist[rng.randrange(bins)]+=rng.randrange(1,7)
  refs.append(random_hist)
  frames=[[0]*n,[d]*n,[d*i//max(1,n-1) for i in range(n)],
          [d if i%2 else 0 for i in range(n)],
          [rng.randrange(bins) for _ in range(n)],
          [d//3]*n,[d*i//max(1,n-1) for i in reversed(range(n))],[0]*n]
  expected=[];expected_lut=[];seq=[];audits=[];reference=refs[0]
  def load(hist,error=0,bad=False,begun=False):
   if not begun:seq.append('begin_reference;')
   for j,value in enumerate(hist):seq.append(f'load_count({value},{int(j==bins-1 and not bad)});')
   seq.append(f'commit_reference({error});')
  load([0]*bins,1)
  seq+=['if(active||sr)$fatal(1,"empty initial reference accepted");']
  for fi,pixels in enumerate(frames):
   if fi in (0,1,2,4):reference=refs[(0,1,2,4).index(fi)];load(reference)
   if fi==3:load([0]*bins,1)
   if fi==5:load(refs[0],2,True)
   if fi==7:
    # Reset after partial capture and rebuild a fresh reference.
    seq+=['send_pixel(1,1,0);reset_dut;']
    seq+=['begin_reference;load_count(1,0);reset_dut;']
    load(reference)
    for ii in range(n):seq.append(f'send_pixel(1,{int(ii==0)},{int(ii%w==w-1)});')
    seq+=['while(dut.state!=7)@(negedge clk);reset_dut;']
    load(reference)
    if bits==8 and w==6 and h==5:
     seq+=['hold_output=1;']
     for ii in range(n):seq.append(f'send_pixel(1,{int(ii==0)},{int(ii%w==w-1)});')
     seq+=['while(!mv)@(negedge clk);repeat(5)@(negedge clk);reset_dut;hold_output=0;']
     load(reference)
   values,lut,audit=oracle(pixels,reference);expected.extend(values);expected_lut.extend(lut);audits.append(audit)
   for i,pixel in enumerate(pixels):
    seq.append(f'send_pixel({pixel},{int(i==0 and fi!=5)},{int(i%w==w-1 and fi!=6)});')
    if fi==2 and i==0:seq.append('rbv=1;')
   seq.append(f'finish_frame({(fi+1)*n},{int(fi in (5,6))});')
   if fi==2:
    seq.append('accept_pending_begin;')
    load(reference,begun=True)
  with tempfile.TemporaryDirectory(prefix='histmatch_test_') as temporary:
   t=Path(temporary)
   (t/'expected.hex').write_text('\n'.join(f'{v:x}' for v in expected)+'\n')
   (t/'lut.hex').write_text('\n'.join(f'{v:x}' for v in expected_lut)+'\n')
   (t/'tb.v').write_text(TB.replace('@PARAM@',f'B={bits},W={w},H={h},CW={cw},N={len(expected)}').replace('@SEQ@','\n'.join(seq)))
   p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(t/'sim'),str(ROOT/'histogram_match_frame.v'),str(t/'tb.v')],capture_output=True,text=True)
   if p.returncode:raise RuntimeError(p.stderr)
   p=subprocess.run(['vvp',str(t/'sim')],cwd=t,capture_output=True,text=True,timeout=240)
   if p.returncode or 'PASS' not in p.stdout:raise RuntimeError(p.stdout+p.stderr)
   print(bits,w,h,p.stdout.strip(),flush=True)
  results.append({'bits':bits,'width':w,'height':h,'reference_count_bits':cw,'frames':len(frames),'pixels':len(expected),'lut_entries':len(expected_lut),'reference_totals':[sum(ref) for ref in refs],'interpolation_audits':audits})
 with tempfile.TemporaryDirectory(prefix='histmatch_invalid_') as temporary:
  t=Path(temporary);invalid=[('BITS',7),('BITS',13),('WIDTH',0),('HEIGHT',4097),('REF_COUNT_W',0),('REF_COUNT_W',25)]
  for parameter,value in invalid:
   (t/'tb.v').write_text(f'module tb;histogram_match_frame #(.{parameter}({value})) dut();initial #1 $finish;endmodule')
   p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(t/'sim'),str(ROOT/'histogram_match_frame.v'),str(t/'tb.v')],capture_output=True,text=True)
   if p.returncode:continue
   p=subprocess.run(['vvp',str(t/'sim')],capture_output=True,text=True)
   if p.returncode==0:raise AssertionError(f'invalid parameter accepted {parameter}={value}')
 (ROOT/'test_result.json').write_text(json.dumps({'status':'PASS','cases':results,'invalid_parameters':len(invalid),'seed':2026472},indent=2)+'\n')

TB=r'''
module tb;
localparam @PARAM@;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,sv=0,sof=0,eol=0,mr=0,dr=0,pause=0,hold_output=0;
reg rbv=0,rv=0,rl=0,rcv=0,rrr=0;reg[CW-1:0] count=0;
wire rbr,rr,rcr,rrv,active;wire[1:0] error;
reg[B-1:0] gray=0;wire sr,mv,ms,me,ml,done,marker,arithmetic,busy;wire[B-1:0] value;
wire[((W<2)?1:$clog2(W))-1:0] x;wire[((H<2)?1:$clog2(H))-1:0] y;
histogram_match_frame #(.BITS(B),.WIDTH(W),.HEIGHT(H),.REF_COUNT_W(CW)) dut(
.clk(clk),.rst(rst),.ce(ce),.ref_begin_valid(rbv),.ref_begin_ready(rbr),.ref_count(count),.ref_valid(rv),.ref_last(rl),.ref_ready(rr),
.ref_commit_valid(rcv),.ref_commit_ready(rcr),.ref_result_valid(rrv),.ref_result_ready(rrr),.ref_error(error),.ref_active_valid(active),
.s_gray(gray),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),.m_valid(mv),.m_ready(mr),.m_gray(value),.m_x(x),.m_y(y),.m_sof(ms),.m_eol(me),.m_last(ml),
.done_valid(done),.done_ready(dr),.marker_error(marker),.arithmetic_error(arithmetic),.busy(busy));
reg[B-1:0] expected[0:N-1];reg[31:0] random_state=32'h6194af01;
reg[B-1:0] expected_lut[0:(N/(W*H))*(1<<B)-1];
integer received=0,cycles=0,local_index,j;reg held=0;reg[127:0] payload;
always @(negedge clk)begin
random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
ce=pause?0:random_state[3:0]!=0;mr=hold_output?0:random_state[6:4]!=0;
end
always @(posedge clk)if(!rst)begin
cycles=cycles+1;if(cycles>15000000)$fatal(1,"timeout state%0d",dut.state);
if(held&&(!mv||{value,x,y,ms,me,ml}!==payload))$fatal(1,"output stall");
held=mv&&!(ce&&mr);payload={value,x,y,ms,me,ml};
if(ce&&mv&&mr)begin
if(received>=N||value!==expected[received])$fatal(1,"pixel%0d got%0d expected%0d",received,value,expected[received]);
local_index=received%(W*H);
if(x!==local_index%W||y!==local_index/W||ms!==(local_index==0)||me!==(local_index%W==W-1)||ml!==(local_index==W*H-1))$fatal(1,"metadata");
received=received+1;
end
if(dut.state!=1&&(rbr||rcr||rr))$fatal(1,"reference changed during frame");
if(dut.capture_addr!=0&&rbr)$fatal(1,"reference allowed in partial frame");
end
task begin_reference;begin
@(negedge clk);#1;rbv=1;sv=1;gray=0;sof=1;eol=W==1;
@(posedge clk);while(!rbr)@(posedge clk);
@(negedge clk);#1;rbv=0;sv=0;
if(sr||dut.capture_addr!=0)$fatal(1,"reference begin priority");
end endtask
task accept_pending_begin;begin
@(posedge clk);while(!rbr)@(posedge clk);
@(negedge clk);#1;rbv=0;
if(!dut.loading||sr)$fatal(1,"pending begin not accepted at boundary");
end endtask
task load_count(input[CW-1:0] v,input lastcount);begin
repeat(v%2)@(negedge clk);#1;count=v;rl=lastcount;rv=1;
@(posedge clk);while(!rr)@(posedge clk);
@(negedge clk);#1;rv=0;
end endtask
task commit_reference(input[1:0] expected_error);begin
@(negedge clk);#1;rcv=1;
@(posedge clk);while(!rcr)@(posedge clk);
@(negedge clk);#1;rcv=0;
if(!rrv||error!==expected_error)$fatal(1,"reference commit error got%0d expected%0d",error,expected_error);
repeat(5)begin @(negedge clk);#1;if(!rrv||error!==expected_error||sr)$fatal(1,"reference response stall");end
rrr=1;@(posedge clk);while(!ce)@(posedge clk);
@(negedge clk);#1;rrr=0;
end endtask
task send_pixel(input[B-1:0] v,input first,lastpixel);begin
repeat(v%2)@(negedge clk);#1;gray=v;sof=first;eol=lastpixel;sv=1;
@(posedge clk);while(!sr)@(posedge clk);
@(negedge clk);#1;sv=0;
end endtask
task finish_frame(input integer expected_count,expected_marker);begin
while(!done)@(negedge clk);#1;
if(received!=expected_count||marker!=expected_marker||arithmetic)$fatal(1,"terminal count %0d expected%0d marker%0d arithmetic%0d",received,expected_count,marker,arithmetic);
for(j=0;j<(1<<B);j=j+1)begin
if(dut.lut_mem[j]!==expected_lut[(expected_count/(W*H)-1)*(1<<B)+j])$fatal(1,"LUT mismatch %0d got%0d expected%0d",j,dut.lut_mem[j],expected_lut[(expected_count/(W*H)-1)*(1<<B)+j]);
if(j>0&&dut.lut_mem[j]<dut.lut_mem[j-1])$fatal(1,"nonmonotone LUT");
end
repeat(5)begin @(negedge clk);#1;if(!done||marker!=expected_marker||arithmetic)$fatal(1,"DONE stall");end
dr=1;@(posedge clk);while(!ce)@(posedge clk);
@(negedge clk);#1;dr=0;
end endtask
task reset_dut;begin
@(negedge clk);#1;pause=1;rst=1;sv=0;repeat(2)@(negedge clk);#1;rst=0;held=0;
if(mv||done||marker||arithmetic||active||rrv)$fatal(1,"reset");pause=0;
end endtask
initial begin
$readmemh("expected.hex",expected);$readmemh("lut.hex",expected_lut);repeat(3)@(negedge clk);#1;rst=0;
@SEQ@
$display("PASS %0d exact normalized-CDF matched pixels",received);$finish;
end
endmodule
'''
if __name__=='__main__':run()
