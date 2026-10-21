"""Independent integer pyramids plus actual OpenCV double pyramid comparison."""
from pathlib import Path
import hashlib,json,random,sys,tempfile
import cv2
import numpy as np
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
K=[1,4,6,4,1]

def border(i,n,down):
 if n==1:return 0
 if down:
  while i<0 or i>=n:i=-i if i<0 else 2*n-2-i
 else:i=min(abs(i),n-1)
 return i

def filt(a,shape,down):
 h,w=shape;sh,sw=a.shape;out=np.zeros(shape,np.int64)
 for y in range(h):
  for x in range(w):
   total=0
   for j,wy in enumerate(K):
    yy=(2*y if down else y)+j-2
    if not down and yy%2:continue
    sy=border(yy if down else yy//2,sh,down)
    for i,wx in enumerate(K):
     xx=(2*x if down else x)+i-2
     if not down and xx%2:continue
     sx=border(xx if down else xx//2,sw,down);total+=int(a[sy,sx])*wx*wy
   out[y,x]=(total+(128 if down else 32))//(256 if down else 64)
 return out

def mix(a,b,m):
 d=(a-b)*m
 q=np.sign(d)*((np.abs(d)+32640)//65280)
 return b+q

def model(a,b,m,levels):
 aa=[a.astype(np.int64)*256];bb=[b.astype(np.int64)*256];mm=[m.astype(np.int64)*256]
 for i in range(1,levels):
  shape=((aa[-1].shape[0]+1)//2,(aa[-1].shape[1]+1)//2)
  for p in (aa,bb,mm):p.append(filt(p[-1],shape,True))
 result=mix(aa[-1],bb[-1],mm[-1])
 for i in reversed(range(levels-1)):
  shape=aa[i].shape
  result=mix(aa[i]-filt(aa[i+1],shape,False),bb[i]-filt(bb[i+1],shape,False),mm[i])+filt(result,shape,False)
 return np.clip((result+128)//256,0,255).astype(np.uint8)

def cvmodel(a,b,m,levels):
 aa=[a.astype(np.float64)];bb=[b.astype(np.float64)];mm=[m.astype(np.float64)/255]
 for i in range(1,levels):
  for p in (aa,bb,mm):p.append(cv2.pyrDown(p[-1],borderType=cv2.BORDER_REFLECT_101))
 r=aa[-1]*mm[-1]+bb[-1]*(1-mm[-1])
 for i in reversed(range(levels-1)):
  h,w=aa[i].shape
  up=lambda z:cv2.pyrUp(z,dstsize=(w,h))
  r=(aa[i]-up(aa[i+1]))*mm[i]+(bb[i]-up(bb[i+1]))*(1-mm[i])+up(r)
 return np.clip(np.floor(r+.5),0,255).astype(np.uint8)

def run(label,a,b,m,levels,replays=1):
 h,w=a.shape;expected=model(a,b,m,levels);cv=cvmodel(a,b,m,levels)
 cvdiff=int(np.max(np.abs(expected.astype(int)-cv.astype(int))));assert cvdiff<=1,(label,cvdiff,expected,cv)
 pixels='\n'.join(f"p[{i}]=24'h{x:02x}{y:02x}{z:02x};e[{i}]=8'd{v};" for i,(x,y,z,v) in enumerate(zip(a.flat,b.flat,m.flat,expected.flat)))
 tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,cfg_valid=0,start_valid=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[7:0]s_a,s_b,s_mask;wire cfg_ready,cfg_done,cfg_error,start_ready,s_ready;
 wire[7:0]m_data;wire m_valid,m_sof,m_eol,m_last,done_valid,busy;wire[3:0]error_code;
 localparam[5:0]W=WW,H=HH;localparam[1:0]L=LL;
 multiband_blend dut(.clk(clk),.rst_n(rst_n),.ce(ce),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),
 .cfg_width(W),.cfg_height(H),.cfg_levels(L),.cfg_done(cfg_done),.cfg_error(cfg_error),
 .start_valid(start_valid),.start_ready(start_ready),.s_a(s_a),.s_b(s_b),.s_mask(s_mask),.s_valid(s_valid),
 .s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),.s_ready(s_ready),.m_data(m_data),.m_valid(m_valid),.m_ready(m_ready),
 .m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.done_valid(done_valid),.done_ready(done_ready),.busy(busy),.error_code(error_code));
 reg[23:0]p[0:NN-1];reg[7:0]e[0:NN-1];integer i,r,got=0,cycles=0;reg accepted,held=0;reg[10:0]saved;
 always @(negedge clk)begin cycles=cycles+1;ce=cycles%13!=0&&cycles%13!=1;m_ready=cycles%7<4;if(cycles>3000000)$fatal(1,"timeout state=%d",dut.state);end
 always @(posedge clk)if(rst_n)begin
  if(held&&{m_data,m_sof,m_eol,m_last}!==saved)$fatal(1,"output instability");
  held=m_valid&&!(ce&&m_ready);saved={m_data,m_sof,m_eol,m_last};
  if(ce&&m_valid&&m_ready)begin
   if(m_data!==e[got]||m_sof!==(got==0)||m_eol!==(got%WW==WW-1)||m_last!==(got==NN-1))$fatal(1,"pixel %d got %d expected %d",got,m_data,e[got]);
   got=got+1;
  end
 end
 initial begin
 INIT
 repeat(3)@(negedge clk);rst_n=1;
 cfg_valid=1;accepted=0;while(!accepted)begin @(posedge clk);accepted=ce&&cfg_ready;@(negedge clk);end cfg_valid=0;
 if(!cfg_done||cfg_error)$fatal(1,"configuration");
 for(r=0;r<RR;r=r+1)begin
 got=0;start_valid=1;accepted=0;while(!accepted)begin @(posedge clk);accepted=ce&&start_ready;@(negedge clk);end start_valid=0;
 for(i=0;i<NN;i=i+1)begin
 @(negedge clk);{s_a,s_b,s_mask}=p[i];s_sof=i==0;s_eol=i%WW==WW-1;s_last=i==NN-1;s_valid=1;accepted=0;
 while(!accepted)begin @(posedge clk);accepted=ce&&s_ready;@(negedge clk);end s_valid=0;
 end
 wait(done_valid);@(negedge clk);if(error_code||got!=NN)$fatal(1,"completion");
 repeat(11)begin @(negedge clk);if(!done_valid||error_code)$fatal(1,"held DONE");end
 done_ready=1;accepted=0;while(!accepted)begin @(posedge clk);accepted=ce;@(negedge clk);end done_ready=0;
 end
 $display("MULTIBAND PASS");$finish;end endmodule'''
 for k,v in [('WW',w),('HH',h),('LL',levels),('NN',w*h),('RR',replays),('INIT',pixels)]:tb=tb.replace(k,str(v))
 with tempfile.TemporaryDirectory(prefix='multiband_') as td:
  td=Path(td);(td/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'multiband_blend.sv',td/'tb.sv'],td,td/'compile.log')
  assert 'MULTIBAND PASS' in execute(['vvp',td/'sim'],td,td/'run.log',timeout=300)
 single=np.floor((a.astype(float)*m+b.astype(float)*(255-m))/255+.5).astype(np.uint8)
 diff=int(np.max(np.abs(expected.astype(int)-single.astype(int))))
 report=dict(label=label,width=w,height=h,levels=levels,replays=replays,pixels=w*h,
             opencv_max_byte_difference=cvdiff,single_layer_max_difference=diff,status='PASS')
 print(report,flush=True);return report,expected

def main():
 rng=np.random.default_rng(611);cases=[]
 for w,h,l in [(1,1,2),(1,7,3),(7,1,3),(3,5,3),(16,16,2),(31,17,3),(32,32,3)]:
  a=rng.integers(0,256,(h,w),dtype=np.uint8);b=rng.integers(0,256,(h,w),dtype=np.uint8);m=rng.integers(0,256,(h,w),dtype=np.uint8)
  report,_=run('random',a,b,m,l,replays=2 if(w,h)==(3,5)else 1);cases.append(report)
 for kind in ('constant','identical','mask0','mask255','multifrequency_seam'):
  h,w=9,17;y,x=np.indices((h,w));a=((x*37+y*17)%256).astype(np.uint8);b=((x%2)*180+y*7).astype(np.uint8);m=np.where(x<w//2,255,0).astype(np.uint8)
  if kind=='multifrequency_seam':a=(20+x*3+(y%2)*12).astype(np.uint8);b=(160+(x%2)*70-y*2).astype(np.uint8)
  if kind=='constant':a[:]=41;b[:]=199;m[:]=123
  if kind=='identical':b=a.copy()
  if kind=='mask0':m[:]=0
  if kind=='mask255':m[:]=255
  report,out=run(kind,a,b,m,3);cases.append(report)
  if kind in ('identical','mask255'):assert np.array_equal(out,a)
  if kind=='mask0':assert np.array_equal(out,b)
  if kind=='multifrequency_seam':assert report['single_layer_max_difference']>=10
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',cases=cases,board=False,rtl_sha256=hashlib.sha256((HERE/'multiband_blend.sv').read_bytes()).hexdigest()),indent=2)+'\n')

if __name__=='__main__':main()
