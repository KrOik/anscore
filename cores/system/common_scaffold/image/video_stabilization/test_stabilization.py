from pathlib import Path
import sys,tempfile,json,math,random,hashlib
import numpy as np
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
Q=65536;I=(Q,0,0,0,Q,0)
stats={'transactions':0,'successful':0,'errors':{},'max_matrix_error':0.0,'max_warp_point_error':0.0}
rng=random.Random(71054)
def rounded(n):return (-1 if n<0 else 1)*((abs(n)+32768)//Q)
def bounded(v):
 if not -(1<<31)<=v<(1<<31):raise OverflowError
 return v
def compose(a,b):
 return tuple(bounded(rounded(a[r]*b[c]+a[r+1]*b[c+3]+(a[r+2]*Q if c==2 else 0))) for r in (0,3) for c in (0,1,2))
def inverse(a,mindet):
 aa,b,tx,c,d,ty=a;det=aa*d-b*c
 if abs(det)<=mindet:raise ZeroDivisionError
 def div(n):return bounded((-1 if (n<0)^(det<0) else 1)*((abs(n)<<32)//abs(det)))
 ai,bi,ci,di=map(div,(d,-b,-c,aa))
 return (ai,bi,bounded(-rounded(ai*tx+bi*ty)),ci,di,bounded(-rounded(ci*tx+di*ty)))
def mat(a):return np.array([[*a[:3]],[*a[3:]],[0,0,Q]],dtype=float)/Q
def encode(a):return tuple(int(round(z*Q)) for z in a)
class Oracle:
 def __init__(self):self.t=I;self.s=I;self.ft=np.eye(3);self.fs=np.eye(3)
 def step(self,a,alpha,mininliers,inliers,cut,mindet):
  if cut:self.__init__();return I+I+(1,0)
  if alpha>Q:return (0,)*12+(0,4)
  if inliers<mininliers:return (0,)*12+(0,1)
  try:
   t=compose(a,self.t)
   s=tuple(bounded(z+rounded(alpha*(v-z))) for v,z in zip(t,self.s))
   it=inverse(t,mindet);iss=inverse(s,mindet)
   c=compose(s,it);w=compose(t,iss)
  except ZeroDivisionError:return (0,)*12+(0,2)
  except OverflowError:return (0,)*12+(0,3)
  self.t=t;self.s=s
  # Independent floating NumPy long-path tracking and inverse transforms.
  ft=mat(a)@self.ft;fs=self.fs+(alpha/Q)*(ft-self.fs)
  fs[2]=[0,0,1]
  fc=fs@np.linalg.inv(ft);fw=ft@np.linalg.inv(fs)
  err=max(np.max(np.abs(mat(c)-fc)),np.max(np.abs(mat(w)-fw)))
  stats['max_matrix_error']=max(stats['max_matrix_error'],float(err))
  samples=np.array([[0,0,1],[10,20,1],[-25,40,1],[100,-80,1]],dtype=float).T
  # Pixel sampler's inverse warp must satisfy W*S*p ~= T*p for initial points.
  pe=np.max(np.abs((mat(w)@mat(s)@samples-mat(t)@samples)[:2]))
  stats['max_warp_point_error']=max(stats['max_warp_point_error'],float(pe))
  if np.linalg.cond(ft[:2,:2])<100 and np.max(np.abs(ft))<1000:
   forward_error=np.max(np.abs((mat(c)@mat(t)@samples-mat(s)@samples)[:2]))
   stats['max_forward_point_error']=max(stats.get('max_forward_point_error',0),float(forward_error))
  self.ft=ft;self.fs=fs
  return c+w+(1,0)
def generate():
 seq=[]
 def add(a=I,alpha=0,minin=3,inliers=24,cut=0,mindet=0):seq.append((a,alpha,minin,inliers,cut,mindet))
 def cut():add(cut=1)
 cut()
 for a in (encode((1,0,8,0,1,-3)),encode((0,-1,0,1,0,0)),encode((1,.25,0,-.5,1,0)),encode((2,0,0,0,2,0))):add(a)
 # Rotation/translation order differs; reference chain checks full products.
 cut();add(encode((0,-1,0,1,0,0)));add(encode((1,0,8,0,1,-3)))
 cut()
 for j in range(100):
  angle=.002*math.sin(j*.27);scale=1+.0005*math.sin(j*.11)
  a=encode((scale*math.cos(angle),-math.sin(angle)+.0003*math.cos(j),.4+(.2 if j%2 else -.2),math.sin(angle),scale*math.cos(angle),-.1+.15*math.sin(j)))
  add(a,alpha=8192)
 # EMA endpoints and signed fractional/halfway increments.
 cut()
 for alpha in (0,Q,1,32768,65535):add(encode((1,.03125,-.5,0,1,.125)),alpha)
 # Every rejected transaction must leave both T and S intact.
 add(encode((0,0,0,0,0,0)),inliers=0);add(I,alpha=8192)
 add(I,alpha=65537);add(I,alpha=8192)
 add(encode((1,0,0,0,0,0)));add(I,alpha=8192)
 add(I,mindet=(1<<64)-1);add(I,alpha=8192)
 add((2147483647,2147483647,2147483647,2147483647,2147483647,2147483647));add(I,alpha=8192)
 cut();add(encode((-1,0,0,0,-1,0)),alpha=32768);add(I)
 cut();add(encode((-1,0,0,0,-1,0)),alpha=32767,mindet=4);add(I)
 cut();add((1,0,0,0,Q,0));add(I)
 # Translation accumulates beyond representable range: explicit range failure.
 cut();add(encode((1,0,20000,0,1,0)),alpha=Q);add(encode((1,0,20000,0,1,0)),alpha=Q);add(I,alpha=Q)
 # Scene-cut priority overrides malformed config, low confidence and singular A.
 add((0,)*6,alpha=131071,minin=127,inliers=0,cut=1,mindet=(1<<64)-1);add(I)
 # Full signed32 multiplicands, >signed64 determinant subtraction intermediates,
 # and negation of INT32_MIN as an inverse cofactor (must be 33 bits).
 cut();add((-2147483648,-2147483648,0,-2147483648,2147483647,0));cut()
 add((-2147483648,2147483647,0,2147483647,-2147483648,0));add(I)
 cut()
 for j in range(20):
  a=encode((1+rng.uniform(-.01,.01),rng.uniform(-.02,.02),rng.uniform(-1,1),rng.uniform(-.02,.02),1+rng.uniform(-.01,.01),rng.uniform(-1,1)))
  add(a,alpha=rng.choice((0,8192,32768,Q)))
 return seq
def run(seq):
 oracle=Oracle();expected=[]
 for a,alpha,mi,ni,cut,det in seq:
  exp=oracle.step(a,alpha,mi,ni,cut,det);expected.append(exp);stats['transactions']+=1
  if exp[-2]:stats['successful']+=1
  else:stats['errors'][str(exp[-1])]=stats['errors'].get(str(exp[-1]),0)+1
 def packed_input(s):
  a,alpha,mi,ni,cut,det=s;v=0
  for i,z in enumerate(a):v|=(z&0xffffffff)<<(32*i)
  return v|(alpha<<192)|(mi<<209)|(ni<<216)|(cut<<223)|(det<<224)
 def packed_output(exp):
  v=0
  for i,z in enumerate(exp[:12]):v|=(z&0xffffffff)<<(32*i)
  return v|(exp[12]<<384)|(exp[13]<<385)
 with tempfile.TemporaryDirectory(prefix='stabilizer_') as td:
  td=Path(td)
  (td/'input.hex').write_text('\n'.join(f'{packed_input(s):x}' for s in seq)+'\n')
  (td/'expected.hex').write_text('\n'.join(f'{packed_output(s):x}' for s in expected)+'\n')
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,s_valid=0,s_scene_cut=0,m_ready=0;
 reg signed [31:0]s_a00=0,s_a01=0,s_a02=0,s_a10=0,s_a11=0,s_a12=0;
 reg [6:0]s_inliers=0,cfg_min_inliers=0;reg [16:0]cfg_alpha=0;reg [63:0]cfg_min_det=0;
 wire s_ready,busy,done,m_valid,m_model_valid;wire [3:0]error_code;
 wire signed [31:0]m_c00,m_c01,m_c02,m_c10,m_c11,m_c12,m_w00,m_w01,m_w02,m_w10,m_w11,m_w12;
 affine_video_stabilizer dut(.*);
 reg [287:0]ins[0:{len(seq)-1}];reg [388:0]expected[0:{len(seq)-1}],held;
 wire [388:0]actual={{error_code,m_model_valid,m_w12,m_w11,m_w10,m_w02,m_w01,m_w00,m_c12,m_c11,m_c10,m_c02,m_c01,m_c00}};
 integer f,k,t,cycles,target;
 task reset;begin @(negedge clk);rst_n=0;ce=0;@(negedge clk);if(m_valid||busy||done||error_code)$fatal(1,"reset leak");rst_n=1;ce=1;s_valid=0;m_ready=0;end endtask
 task send(input integer i);begin
 @(negedge clk);{{cfg_min_det,s_scene_cut,s_inliers,cfg_min_inliers,cfg_alpha,s_a12,s_a11,s_a10,s_a02,s_a01,s_a00}}=ins[i];s_valid=1;
 if(!s_ready)$fatal(1,"not ready");ce=0;@(negedge clk);if(!s_ready || m_valid || busy)$fatal(1,"CE accepted");ce=1;
 @(negedge clk);s_valid=0;cfg_alpha=131071;cfg_min_det=64'hffffffffffffffff;cfg_min_inliers=127;s_inliers=0;
 end endtask
 initial begin
 $readmemh("input.hex",ins);$readmemh("expected.hex",expected);
 // Full replay after reset proves deterministic state and reset initialization.
 for(k=0;k<2;k=k+1)begin reset;
 for(f=0;f<{len(seq)};f=f+1)begin
  send(f);cycles=0;
  while(!m_valid)begin @(negedge clk);ce=(cycles%7!=1);cycles=cycles+1;if(cycles>10000)$fatal(1,"timeout");end
  if(actual!==expected[f])$fatal(1,"numeric frame %d got %h expected %h",f,actual,expected[f]);
  held=actual;repeat(4)begin @(negedge clk);ce=1;if(!m_valid||actual!==held)$fatal(1,"held");end
  ce=0;m_ready=1;@(negedge clk);if(!m_valid||actual!==held)$fatal(1,"CE held");
  ce=1;@(negedge clk);if(m_valid||!done||busy)$fatal(1,"completion");m_ready=0;
 end end
 // Abort each major arithmetic stage with reset overriding CE.
 for(target=0;target<5;target=target+1)begin
  reset;send(1);t=0;
  while((target==0&&dut.state!=4)||(target==1&&dut.state!=11)||(target==2&&dut.state!=6)||(target==3&&dut.state!=9)||(target==4&&!m_valid))begin
   @(negedge clk);t=t+1;if(t>10000)$fatal(1,"reset reach");end
  reset;send(0);while(!m_valid)@(negedge clk);
  if(actual!==expected[0])$fatal(1,"reset recovery");
 end
 $display("VIDEO STABILIZATION PASS");$finish;
 end
 initial begin #1000000000;$fatal(1,"watchdog");end
 endmodule'''
  (td/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'affine_video_stabilizer.sv',td/'tb.sv'],td,td/'compile.log')
  assert 'VIDEO STABILIZATION PASS' in execute(['vvp',td/'sim'],td,td/'sim.log',timeout=300)
if __name__=='__main__':
 seq=generate();run(seq)
 assert set(stats['errors'])=={'1','2','3','4'}
 assert stats['max_matrix_error']<.03 and stats['max_warp_point_error']<.03 and stats['max_forward_point_error']<.03,stats
 evidence={'result':'PASS',**stats,'complete_rtl_replays':2,'rtl_transactions':2*len(seq),'numpy_version':np.__version__,'oracle':'independent arbitrary precision fixed-point affine compose/EMA/inverse + NumPy full-trajectory point audit','board':False,'rtl_sha256':hashlib.sha256((HERE/'affine_video_stabilizer.sv').read_bytes()).hexdigest()}
 (HERE/'evidence.json').write_text(json.dumps(evidence,indent=2)+'\n');print(evidence)
