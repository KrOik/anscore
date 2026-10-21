"""Independent exhaustive donor oracle plus SciPy cKDTree nearest-distance cross-check."""
from pathlib import Path
import sys,tempfile,json,hashlib,re
import numpy as np
from scipy.spatial import cKDTree
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
RTL=H/'defect_map.sv'
def oracle(pixels,bad,fill):
 h,w=pixels.shape;out=pixels.copy();status=np.zeros_like(pixels);coords=list(np.ndindex(h,w))
 for y,x in coords:
  if not bad[y,x]:continue
  donors=[(a,b) for a,b in coords if not bad[a,b] and a%2==y%2 and b%2==x%2]
  if not donors:out[y,x]=fill;status[y,x]=2;continue
  distances=[(a-y)**2+(b-x)**2 for a,b in donors];best=min(distances)
  tied=[pixels[a,b].item() for (a,b),d in zip(donors,distances) if d==best]
  out[y,x]=(sum(tied)+len(tied)//2)//len(tied);status[y,x]=1
  # Independent tree nearest search; enumerate its radius hits then retain exact integer ties.
  tree=cKDTree(donors);dist,nearest=tree.query([y,x]);assert abs(dist*dist-best)<1e-7
  hit=tree.query_ball_point([y,x],float(dist)+1e-8)
  vals=[pixels[donors[k]].item() for k in hit if sum((a-b)**2 for a,b in zip(donors[k],(y,x)))==best]
  assert sorted(vals)==sorted(tied)
 return out,status
TB=r'''module tb;
localparam W=WW,H=HH,B=BB,N=W*H,A=$clog2(N+1),F=FF;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cfg_begin_valid=0,cfg_valid=0,cfg_commit_valid=0,cfg_abort=0,cfg_done_ready=0,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=1,done_ready=0;
reg[A-1:0]cfg_index=0;reg cfg_bad=0;reg[1:0]cfg_pattern=0;reg[B-1:0]cfg_fill=0,s_pixel=0;
wire cfg_begin_ready,cfg_ready,cfg_commit_ready,cfg_done_valid,cfg_error,map_active_valid,start_ready,s_ready,m_valid,m_sof,m_eol,m_last,m_repaired,m_unrepaired,m_invalid,done_valid,frame_error,busy;
wire[3:0]cfg_error_code,error_code;wire[B-1:0]m_pixel;wire[1:0]m_status;
defect_map #(.WIDTH(W),.HEIGHT(H),.BITS(B))dut(.*);
reg[B-1:0]pixels[0:F*N-1],fills[0:F-1];reg masks[0:F*N-1];reg[B+1:0]expected[0:F*N-1];
integer cycle=0,got=0,f,i;reg held_valid=0;reg[B+7:0]held;wire[B+7:0]token={m_pixel,m_status,m_repaired,m_unrepaired,m_invalid,m_sof,m_eol,m_last};
always @(negedge clk)begin cycle=cycle+1;ce=cycle%13>1;m_ready=cycle%7>1;if(cycle>5000000)$fatal(1,"timeout state %d",dut.state);end
always @(posedge clk)if(rst_n)begin
 if(held_valid&&(!m_valid||token!==held))$fatal(1,"unstable token");held_valid=m_valid&&!(ce&&m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin
 if(got>=F*N||{m_status,m_pixel}!==expected[got])$fatal(1,"output %d got %h expected %h",got,{m_status,m_pixel},expected[got]);
 if(m_repaired!==(m_status==1)||m_invalid!==(m_status==2)||m_unrepaired!==m_invalid)$fatal(1,"status");
 if(m_sof!==(got%N==0)||m_eol!==(got%W==W-1)||m_last!==(got%N==N-1))$fatal(1,"markers");got=got+1;end end
 task tick;begin @(negedge clk);#1;end endtask
 task wait_begin;reg ok;begin ok=0;while(!ok)begin @(posedge clk);ok=ce&&cfg_begin_ready;end tick;end endtask
 task wait_cfg;reg ok;begin ok=0;while(!ok)begin @(posedge clk);ok=ce&&cfg_ready;end tick;end endtask
 task wait_commit;reg ok;begin ok=0;while(!ok)begin @(posedge clk);ok=ce&&cfg_commit_ready;end tick;end endtask
 task wait_start;reg ok;begin ok=0;while(!ok)begin @(posedge clk);ok=ce&&start_ready;end tick;end endtask
 task wait_pixel;reg ok;begin ok=0;while(!ok)begin @(posedge clk);ok=ce&&s_ready;end tick;end endtask
 task cfg_ack;begin cfg_done_ready=1;while(!ce)tick;@(posedge clk);tick;cfg_done_ready=0;end endtask
 task frame_ack;begin done_ready=1;while(!ce)tick;@(posedge clk);tick;done_ready=0;end endtask
 initial begin
 $readmemh("PIX",pixels);$readmemh("MASK",masks);$readmemh("EXP",expected);$readmemh("FILL",fills);
 repeat(3)tick;rst_n=1;tick;
 for(f=0;f<F;f=f+1)begin
 cfg_begin_valid=1;wait_begin;cfg_begin_valid=0;
 for(i=N-1;i>=0;i=i-1)begin cfg_index=i;cfg_bad=masks[f*N+i];cfg_valid=1;wait_cfg;end cfg_valid=0;
 cfg_commit_valid=1;wait_commit;cfg_commit_valid=0;if(!cfg_done_valid||cfg_error||!map_active_valid)$fatal(1,"cfg");cfg_ack;
 cfg_fill=fills[f];cfg_pattern=f%4;start_valid=1;wait_start;start_valid=0;cfg_pattern=(f+1)%4;cfg_fill=~fills[f];
 for(i=0;i<N;i=i+1)begin s_pixel=pixels[f*N+i];s_sof=i==0;s_eol=i%W==W-1;s_last=i==N-1;s_valid=1;wait_pixel;end s_valid=0;
 while(!done_valid)tick;if(frame_error||got!=(f+1)*N)$fatal(1,"frame count %d error %h",got,error_code);
 repeat(5)tick;if(!done_valid)$fatal(1,"done hold");frame_ack;
 end $display("PASS defect_map %d frames %d pixels",F,got);$finish;end
endmodule'''
def run_case(name,bits,shape,cases):
 h,w=shape;pixels=[];masks=[];expected=[];fills=[]
 for a,m,fill in cases:
  out,status=oracle(a,m,fill);pixels.extend(a.flat);masks.extend(m.flat);expected.extend(((status<<bits)|out).flat);fills.append(fill)
 with tempfile.TemporaryDirectory(prefix='defect_map_') as td:
  d=Path(td);tb=TB
  for token,values in [('PIX',pixels),('MASK',masks),('EXP',expected),('FILL',fills)]:
   p=d/(token+'.hex');p.write_text('\n'.join(f'{int(x):x}' for x in values)+'\n');tb=tb.replace('"'+token+'"','"'+p.as_posix()+'"')
  for a,b in [('WW',w),('HH',h),('BB',bits),('FF',len(cases))]:tb=re.sub(r'\b'+a+r'\b',str(b),tb)
  (d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',str(d/'a.vvp'),str(RTL),str(d/'tb.sv')],ROOT,H/(name+'_compile.log'))
  text=execute(['vvp',str(d/'a.vvp')],ROOT,H/(name+'_simulation.log'),timeout=180);assert 'PASS defect_map' in text
 return {'name':name,'bits':bits,'shape':shape,'frames':len(cases),'pixels':len(pixels),'max_error':0,'patterns':[i%4 for i in range(len(cases))]}
def make_cases(bits,shape):
 rng=np.random.default_rng(bits+sum(shape));peak=(1<<bits)-1;h,w=shape;cases=[]
 for mode in range(8):
  a=rng.integers(0,peak+1,shape);m=np.zeros(shape,dtype=np.uint8)
  if mode==1:m[:]=1
  if mode==2:m[h//4:3*h//4+1,w//4:3*w//4+1]=1
  if mode==3:m=rng.integers(0,2,shape)
  if mode==4:m[0,0]=1;m[-1,-1]=1
  if mode==5:m[::2,::2]=1 # no donor for entire CFA phase
  if mode==6:m[:]=1;m[::2,1::2]=0 # only one donor phase remains
  if mode==7:
   m[h//2,w//2]=1;a=np.indices(shape).sum(axis=0)%2*peak # extreme original samples
  cases.append((a,m,(peak//3+mode)%(peak+1)))
 return cases
def main():
 rows=[]
 for bits in (8,10,12):
  for shape in ((1,1),(1,7),(7,1),(2,2),(7,9),(12,16)):
   row=run_case(f'b{bits}_{shape[0]}x{shape[1]}',bits,shape,make_cases(bits,shape));rows.append(row);print(json.dumps(row),flush=True)
 (H/'test_evidence.json').write_text(json.dumps({'result':'PASS','rtl_sha256':hashlib.sha256(RTL.read_bytes()).hexdigest(),'oracle':'exhaustive original same-parity donors and exact integer tie mean; independent scipy.spatial.cKDTree nearest distance and radius tie set','cases':rows},indent=2)+'\n')
if __name__=='__main__':main()
