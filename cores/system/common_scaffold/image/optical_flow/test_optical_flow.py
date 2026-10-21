from pathlib import Path
import tempfile,sys,json,random,hashlib
import numpy as np
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
rng=random.Random(91022)
stats={'frames':0,'pixels':0,'valid_vectors':0,'overflow_invalid':0}
quality=[]
def oracle(p,q,win,frac,outbits,threshold):
 h,w=p.shape;r=win//2;out=[]
 for y in range(h):
  for x in range(w):
   u=v=ok=0
   if r+1<=x<w-r-1 and r+1<=y<h-r-1:
    a=b=c=d=e=0
    for sy in range(y-r,y+r+1):
     for sx in range(x-r,x+r+1):
      ix=int(p[sy,sx+1])-int(p[sy,sx-1]);iy=int(p[sy+1,sx])-int(p[sy-1,sx]);it=2*(int(q[sy,sx])-int(p[sy,sx]))
      a+=ix*ix;b+=ix*iy;c+=iy*iy;d+=ix*it;e+=iy*it
    det=a*c-b*b
    stats['max_abs_normal_sum']=max(stats.get('max_abs_normal_sum',0),abs(a),abs(b),abs(c),abs(d),abs(e))
    stats['max_determinant']=max(stats.get('max_determinant',0),det)
    if det>threshold:
     nu=b*e-c*d;nv=b*d-a*e
     u=(-1 if nu<0 else 1)*((abs(nu)<<frac)//det);v=(-1 if nv<0 else 1)*((abs(nv)<<frac)//det)
     if -(1<<(outbits-1))<=u<(1<<(outbits-1)) and -(1<<(outbits-1))<=v<(1<<(outbits-1)):ok=1
     else:u=v=0;stats['overflow_invalid']+=1
   out.append((u,v,ok))
 return out
def run(w,h,bits,win,frac=8,outbits=24):
 maximum=(1<<bits)-1
 yy,xx=np.indices((h,w))
 fixtures=[]
 for val in (0,maximum):fixtures.append((np.full((h,w),val),np.full((h,w),val),0,'flat'))
 aperture=(xx*3)%(maximum+1);fixtures.append((aperture,np.clip(aperture-3,0,maximum),0,'aperture'))
 base=np.clip(maximum//3+xx*xx+2*yy*yy,0,maximum)
 fixtures.append((base,base.copy(),0,'static'))
 # Exact first-order x/y displacement of 1 pixel on a quadratic reference.
 for u,v in ((1,0),(-1,0),(0,1),(0,-1)):
  q=np.clip(base-2*xx*u-4*yy*v,0,maximum)
  fixtures.append((base,q,0,'linearized'))
 # Actual image translations, not generated from the equation under test.
 p=np.rint(maximum*.5+maximum*.13*np.sin(xx*.22)+maximum*.13*np.cos(yy*.27)+maximum*.08*np.sin((xx+yy)*.19)).astype(int)
 for dx,dy in ((1,0),(-1,0),(0,1),(0,-1)):
  q=p[np.clip(yy-dy,0,h-1),np.clip(xx-dx,0,w-1)]
  fixtures.append((p,q,0,f'translation{dx},{dy}'))
 fixtures.append((p,p,2**64-1,'threshold'))
 # Fullscale discontinuities stress accumulation/determinant widths at BITS12/WINDOW5.
 hard=np.where(((xx//2+yy//3)%2)!=0,maximum,0)
 fixtures.append((hard,maximum-hard,0,'fullscale_edges'))
 hard=np.array([[maximum if rng.randrange(2) else 0 for _ in range(w)] for _ in range(h)])
 fixtures.append((hard,maximum-hard,0,'fullscale_random'))
 for _ in range(5):
  p=np.array([[rng.randrange(maximum+1) for _ in range(w)] for _ in range(h)])
  q=np.array([[rng.randrange(maximum+1) for _ in range(w)] for _ in range(h)])
  fixtures.append((p,q,rng.randrange(100),'random'))
 if outbits<16:
  # Near-aperture texture gives a large solved displacement, exercising range rejection.
  p=20+xx+((xx+yy)%3==0).astype(int)
  q=np.clip(p+xx*8+yy*12,0,maximum)
  fixtures.append((p,q,0,'overflow'))
 stim=[];expected=[]
 for p,q,th,label in fixtures:
  out=oracle(p,q,win,frac,outbits,th)
  expected+=out
  for k,(a,b) in enumerate(zip(p.flat,q.flat)):
   stim.append((int(a),int(b),th if k==0 else 2**64-1-th))
  stats['frames']+=1;stats['pixels']+=w*h;stats['valid_vectors']+=sum(o[2] for o in out)
  if label in ('flat','aperture','threshold'):assert not any(z for _,_,z in out)
  if label=='static':assert all(u==0 and v==0 for u,v,_ in out)
  if label.startswith('translation') and w>=16 and h>=16 and outbits>=16:
   dx,dy=map(int,label[len('translation'):].split(','))
   vals=np.array([(u/2**frac,v/2**frac) for u,v,ok in out if ok])
   med=np.median(vals,axis=0)
   assert abs(med[0]-dx)<.25 and abs(med[1]-dy)<.25,(label,med)
   quality.append({'geometry':[w,h],'window':win,'shift':[dx,dy],'median':med.tolist(),'valid':len(vals)})
 with tempfile.TemporaryDirectory(prefix='lk_') as td:
  td=Path(td)
  (td/'input.hex').write_text('\n'.join(f'{th:016x}{b:03x}{a:03x}' for a,b,th in stim)+'\n')
  mask=(1<<outbits)-1
  (td/'expect.hex').write_text('\n'.join(f'{((ok<<(2*outbits))|((v&mask)<<outbits)|(u&mask)):x}' for u,v,ok in expected)+'\n')
  tb=f'''module tb;
 localparam W={w},H={h},B={bits},F={frac},O={outbits},COUNT={len(stim)},N=W*H;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,s_valid=0,s_sof=0,s_eol=0,m_ready=0;
 reg [B-1:0] s_prev=0,s_curr=0;reg [63:0] texture_threshold=0;
 wire s_ready,busy,done,m_valid,m_sof,m_eol,m_flow_valid;wire [3:0] error_code;
 wire signed [O-1:0]m_u,m_v;
 dense_lucas_kanade #(.WIDTH(W),.HEIGHT(H),.BITS(B),.WINDOW({win}),.FRAC(F),.OUT_BITS(O)) dut(.*);
 reg [87:0] ins[0:COUNT-1];reg [2*O:0] expect_data[0:COUNT-1];
 integer f,i,tx,rx,t,cycles,phase,target;reg [2*O+2:0] held;reg stalled;
 initial begin
 $readmemh("input.hex",ins);$readmemh("expect.hex",expect_data);
 repeat(2)@(negedge clk);rst_n=1;
 for(f=0;f<COUNT/N;f=f+1)begin
  tx=0;rx=0;cycles=0;stalled=0;
  while(rx<N)begin
   @(negedge clk);ce=(cycles%7!=2);m_ready=(cycles%5!=1);
   s_valid=(tx<N && cycles%4!=1);s_sof=(tx==0);s_eol=(tx%W==W-1);
   if(tx<N)begin s_prev=ins[f*N+tx][11:0];s_curr=ins[f*N+tx][23:12];texture_threshold=ins[f*N+tx][87:24];end
   @(posedge clk);
   if(stalled && (!m_valid || held!=={{m_sof,m_eol,m_flow_valid,m_v,m_u}}))$fatal(1,"output unstable");
   stalled=m_valid && !(ce && m_ready);held={{m_sof,m_eol,m_flow_valid,m_v,m_u}};
   if(ce && s_valid && s_ready)tx=tx+1;
   if(ce && m_valid && m_ready)begin
    if({{m_flow_valid,m_v,m_u}}!==expect_data[f*N+rx])$fatal(1,"numeric f=%0d px=%0d got %0d,%0d,%0d expected %h",f,rx,m_u,m_v,m_flow_valid,expect_data[f*N+rx]);
    if(m_sof!=(rx==0) || m_eol!=(rx%W==W-1))$fatal(1,"output marker");rx=rx+1;
   end
   #1;if(error_code)$fatal(1,"unexpected error");
   cycles=cycles+1;if(cycles>2000000)$fatal(1,"timeout");
  end
  if(!done || busy)$fatal(1,"done/busy");
 end
 // Abort malformed SOF. Reset overrides CE during partial capture.
 @(negedge clk);ce=1;s_valid=1;s_sof=0;s_eol=0;@(posedge clk);#1;
 if(!done || error_code!=1 || busy)$fatal(1,"marker abort");
 @(negedge clk);s_sof=1;s_eol=(W!=1);@(posedge clk);#1;
 if(!done || error_code!=1 || busy)$fatal(1,"EOL abort");
 @(negedge clk);s_sof=1;s_eol=(W==1);@(posedge clk);#1;
 @(negedge clk);rst_n=0;ce=0;@(posedge clk);#1;
 if(busy || m_valid || done || error_code)$fatal(1,"capture reset");
 // Explicitly reach interior ADDR, MUL, DIVU and DIVV before each reset.
 @(negedge clk);rst_n=1;ce=1;texture_threshold=0;
 for(phase=0;phase<4;phase=phase+1)begin
  case(phase)0:target=2;1:target=5;2:target=14;3:target=16;endcase
  for(i=0;i<N;i=i+1)begin s_valid=1;s_sof=(i==0);s_eol=(i%W==W-1);s_prev=i*i+(i/W)*13;s_curr=s_prev;@(negedge clk);end
  s_valid=0;m_ready=1;t=0;
  if(W>2*({win//2}+1) && H>2*({win//2}+1))begin
   while(dut.state!=target)begin @(negedge clk);t=t+1;if(t>10000)$fatal(1,"compute reset target %d unreachable",target);end
  end else repeat(7)@(negedge clk);
  rst_n=0;ce=0;@(negedge clk);if(m_valid || busy || done)$fatal(1,"compute reset target %d leak",target);rst_n=1;ce=1;
 end
 for(i=0;i<N;i=i+1)begin s_valid=1;s_sof=(i==0);s_eol=(i%W==W-1);s_prev=i;s_curr=i;@(negedge clk);end
 s_valid=0;m_ready=0;while(!m_valid)@(negedge clk);
 rst_n=0;ce=0;@(negedge clk);if(m_valid || busy)$fatal(1,"held reset");
 $display("OPTICAL FLOW PASS");$finish;
 end
 initial begin #100000000;$fatal(1,"watchdog");end
 endmodule'''
  (td/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'dense_lucas_kanade.sv',td/'tb.sv'],td,td/'compile.log')
  out=execute(['vvp',td/'sim'],td,td/'sim.log',timeout=180)
  assert 'OPTICAL FLOW PASS' in out
 print((w,h,bits,win,frac,outbits),'PASS')
def guards():
 with tempfile.TemporaryDirectory(prefix='lk_guards_') as td:
  td=Path(td)
  cases=('.WIDTH(0)','.HEIGHT(4097)','.WIDTH(4096),.HEIGHT(17)','.BITS(7)','.BITS(13)','.WINDOW(4)','.FRAC(17)','.OUT_BITS(9)','.OUT_BITS(33)')
  for cfg in cases:
   (td/'tb.sv').write_text(f'module bad;dense_lucas_kanade #({cfg}) dut();initial begin #10;$fatal(1,"missing guard");end endmodule')
   execute(['iverilog','-g2012','-s','bad','-o',td/'sim',HERE/'dense_lucas_kanade.sv',td/'tb.sv'],td,td/'compile.log')
   try:execute(['vvp',td/'sim'],td,td/'sim.log')
   except RuntimeError:assert 'invalid optical flow parameters' in (td/'sim.log').read_text()
   else:raise AssertionError('invalid accepted')
 stats['invalid_parameter_cases']=len(cases)
if __name__=='__main__':
 for cfg in [(9,8,8,3),(11,9,12,5),(16,16,8,3),(16,16,8,5),(7,7,8,3,4,6),(1,9,10,3),(9,1,8,5),(1,1,8,3)]:run(*cfg)
 guards()
 assert stats['overflow_invalid']>0
 evidence={'result':'PASS',**stats,'translation_quality':quality,'oracle':'independent Python arbitrary precision normal equations and signed division','board':False,'rtl_sha256':hashlib.sha256((HERE/'dense_lucas_kanade.sv').read_bytes()).hexdigest()}
 (HERE/'evidence.json').write_text(json.dumps(evidence,indent=2)+'\n');print(evidence)
