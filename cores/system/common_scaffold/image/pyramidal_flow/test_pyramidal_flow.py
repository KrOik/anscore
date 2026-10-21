"""Independent array-level fixed-point oracle plus real OpenCV LK comparison."""
import os,json,random,tempfile,subprocess,hashlib,time
from pathlib import Path
import numpy as np
import cv2
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])
def pyramid(a,levels):
 result=[a.astype(np.int64)]
 kernel=np.outer([1,4,6,4,1],[1,4,6,4,1])
 for _ in range(levels-1):
  src=result[-1];h,w=src.shape;pad=np.pad(src,2,mode='edge');out=np.empty(((h+1)//2,(w+1)//2),dtype=np.int64)
  for y in range(out.shape[0]):
   for x in range(out.shape[1]):out[y,x]=(int(np.sum(pad[2*y:2*y+5,2*x:2*x+5]*kernel))+128)//256
  result.append(out)
 return result
def trunc_div(a,b):return (-1 if a<0 else 1)*(abs(a)//b)
def oracle(ref,cur,levels=3,window=5,iterations=3,threshold=10000,max_step=32,max_flow=32767):
 refs=pyramid(ref,levels);curs=pyramid(cur,levels);coarse=None
 for level in reversed(range(levels)):
  a=refs[level];b=curs[level];h,w=a.shape;flow=np.zeros((h,w,2),dtype=np.int64);flags=np.zeros((h,w,3),dtype=np.int64)
  for y in range(h):
   for x in range(w):
    if coarse is None:v=np.array([0,0],dtype=np.int64)
    else:
     ch,cw,_=coarse.shape;xx=x//2;yy=y//2;u=x%2;t=y%2
     v=(coarse[min(yy,ch-1),min(xx,cw-1)]*(2-u)*(2-t)+coarse[min(yy,ch-1),min(xx+1,cw-1)]*u*(2-t)+coarse[min(yy+1,ch-1),min(xx,cw-1)]*(2-u)*t+coarse[min(yy+1,ch-1),min(xx+1,cw-1)]*u*t)//2
    flags[y,x,2]=np.any(abs(v)>max_flow);v=np.clip(v,-max_flow,max_flow)
    for _ in range(iterations):
     gxx=gxy=gyy=bx=by=0
     for j in range(-window//2+1,window//2+1):
      for i in range(-window//2+1,window//2+1):
       xx=min(max(x+i,0),w-1);yy=min(max(y+j,0),h-1)
       gx=int(a[yy,min(xx+1,w-1)]-a[yy,max(xx-1,0)]);gy=int(a[min(yy+1,h-1),xx]-a[max(yy-1,0),xx])
       qx=xx*16+int(v[0]);qy=yy*16+int(v[1]);flags[y,x,1]|=qx<0 or qy<0 or qx>(w-1)*16 or qy>(h-1)*16
       qx=min(max(qx,0),(w-1)*16);qy=min(max(qy,0),(h-1)*16);ix,fx=divmod(qx,16);iy,fy=divmod(qy,16)
       p00=int(b[iy,ix]);p10=int(b[iy,min(ix+1,w-1)]);p01=int(b[min(iy+1,h-1),ix]);p11=int(b[min(iy+1,h-1),min(ix+1,w-1)])
       warped=(p00*(16-fx)*(16-fy)+p10*fx*(16-fy)+p01*(16-fx)*fy+p11*fx*fy)//256
       residual=warped-int(a[yy,xx]);gxx+=gx*gx;gxy+=gx*gy;gyy+=gy*gy;bx+=gx*residual;by+=gy*residual
     det=gxx*gyy-gxy*gxy
     if det<=threshold:flags[y,x,0]=1;delta=np.array([0,0],dtype=np.int64)
     else:delta=np.array([trunc_div(32*(gxy*by-gyy*bx),det),trunc_div(32*(gxy*bx-gxx*by),det)],dtype=np.int64)
     total=v+np.clip(delta,-max_step,max_step);flags[y,x,2]|=np.any(abs(total)>max_flow);v=np.clip(total,-max_flow,max_flow)
    flow[y,x]=v
  coarse=flow
 return flow,flags
def numerical_audit():
 rng=np.random.default_rng(672)
 ref=cv2.GaussianBlur(rng.integers(0,256,(32,32),dtype=np.uint8),(5,5),.8)
 dx,dy=4,2;cur=cv2.warpAffine(ref,np.float32([[1,0,dx],[0,1,dy]]),(32,32),flags=cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)
 flow,flags=oracle(ref,cur,3,5,4);single,_=oracle(ref,cur,1,5,4)
 yy,xx=np.mgrid[8:24,8:24];target=np.array([dx,dy]);err=np.linalg.norm(flow[yy,xx]/16-target,axis=-1);single_err=np.linalg.norm(single[yy,xx]/16-target,axis=-1)
 pts=np.column_stack((xx.ravel(),yy.ravel())).astype(np.float32).reshape(-1,1,2)
 nxt,status,_=cv2.calcOpticalFlowPyrLK(ref,cur,pts,None,winSize=(5,5),maxLevel=2,criteria=(cv2.TERM_CRITERIA_COUNT,20,.01),minEigThreshold=1e-5)
 cvflow=(nxt-pts).reshape(16,16,2);cvvalid=status.reshape(16,16)>0
 result=dict(opencv_version=cv2.__version__,translation=[dx,dy],interior_points=256,pyramid_median_error=float(np.median(err)),single_scale_median_error=float(np.median(single_err)),opencv_median_error=float(np.median(np.linalg.norm(cvflow[cvvalid]-target,axis=-1))),pyramid_opencv_median_difference=float(np.median(np.linalg.norm(flow[yy,xx][cvvalid]/16-cvflow[cvvalid],axis=-1))),valid_interior=int(np.sum(~np.any(flags[yy,xx],axis=-1))))
 valid=~np.any(flags[yy,xx],axis=-1)
 result['valid_interior_median_error']=float(np.median(err[valid]))
 result['valid_interior_p95_error']=float(np.percentile(err[valid],95))
 assert np.sum(valid)>128,result
 assert result['pyramid_median_error']<result['single_scale_median_error']*.7,result
 assert result['pyramid_median_error']<1.5,result
 return ref,cur,result
TB='''module tb;
localparam W=@W@,H=@H@,L=@L@,WIN=@WIN@,IT=@IT@,MF=@MF@,F=@F@,N=W*H,T=@T@;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,s_valid=0,s_sof=0,s_eol=0,m_ready=0,done_ready=0;
reg[7:0]s_ref=0,s_cur=0;wire s_ready,m_valid,m_texture_invalid,m_oob,m_overflow,m_invalid,m_sof,m_eol,m_last,done_valid,busy;
wire signed[15:0]m_flow_x,m_flow_y;wire[$clog2(W)-1:0]m_x;wire[$clog2(H)-1:0]m_y;wire[1:0]error_code;
pyramidal_lk_flow #(.WIDTH(W),.HEIGHT(H),.LEVELS(L),.WINDOW(WIN),.ITERATIONS(IT),.MAX_FLOW_Q(MF))dut(.*);
reg[15:0]inputs[0:F*N-1];reg[127:0]expected[0:T-1];reg[127:0]payload,previous;reg[1:0]old_error;
integer cycle=0,index=0,f,i,frame_out=0;reg held=0,dh=0;reg errors[0:F-1];
always @(negedge clk)begin cycle=cycle+1;ce=cycle%13!=0;m_ready=cycle%7!=0;end
always @(posedge clk)if(rst)begin held=0;dh=0;end else begin
 payload={m_flow_x,m_flow_y,8'(m_texture_invalid),8'(m_oob),8'(m_overflow),8'(m_x),8'(m_y),8'(m_sof),8'(m_eol),8'(m_last)};
 if(held&&(!m_valid||payload!==previous))$fatal(1,"OUT unstable");
 if(dh&&(!done_valid||error_code!==old_error))$fatal(1,"DONE unstable");
 held=m_valid&&(!ce||!m_ready);dh=done_valid&&(!ce||!done_ready);previous=payload;old_error=error_code;
 if(ce&&m_valid&&m_ready)begin
 if(index>=T||payload!==expected[index])$fatal(1,"pixel %d got %h expected %h",index,payload,expected[index]);
 if(m_invalid!==(m_texture_invalid|m_oob|m_overflow))$fatal(1,"invalid OR");index=index+1;frame_out=frame_out+1;end
end
task send(input[15:0]v,input a,b);begin @(negedge clk);s_ref=v[15:8];s_cur=v[7:0];s_sof=a;s_eol=b;s_valid=1;@(posedge clk);while(!s_ready)@(posedge clk);@(negedge clk);s_valid=0;end endtask
initial begin $readmemh("input.hex",inputs);$readmemh("expected.hex",expected);$readmemh("errors.hex",errors);repeat(3)@(negedge clk);rst=0;
 for(f=0;f<F;f=f+1)begin frame_out=0;
 for(i=0;i<N;i=i+1)send(inputs[f*N+i],i==0&&!errors[f],i%W==W-1);
 wait(done_valid);#1;if(error_code!=errors[f]||frame_out!=(errors[f]?0:N))$fatal(1,"frame result %d",f);
 repeat(4)@(negedge clk);done_ready=1;@(posedge clk);while(!ce)@(posedge clk);@(negedge clk);done_ready=0;
 end
 if(index!=T)$fatal;$display("PASS");$finish;end
initial begin #2000000000;$fatal(1,"timeout");end
endmodule'''
def run_profile(td,w,h,levels,window,iterations,maxflow,pairs):
 started=time.perf_counter()
 expected=[];inputs=[];errors=[];texture=oob=overflow=0
 for ref,cur,error in pairs:
  inputs.extend((int(a)<<8)|int(b) for a,b in zip(ref.ravel(),cur.ravel()));errors.append(error)
  if error:continue
  flow,flags=oracle(ref,cur,levels,window,iterations,max_flow=maxflow)
  texture+=int(flags[:,:,0].sum());oob+=int(flags[:,:,1].sum());overflow+=int(flags[:,:,2].sum())
  for y in range(h):
   for x in range(w):
    fields=[(int(flow[y,x,0])&65535,4),(int(flow[y,x,1])&65535,4)]+[(int(v),2) for v in flags[y,x]]+[(x,2),(y,2),(int(x==0 and y==0),2),(int(x==w-1),2),(int(x==w-1 and y==h-1),2)]
    expected.append(''.join(f'{v:0{digits}x}' for v,digits in fields).zfill(32))
 (td/'input.hex').write_text('\n'.join(f'{v:04x}' for v in inputs));(td/'expected.hex').write_text('\n'.join(expected));(td/'errors.hex').write_text('\n'.join(map(str,errors)))
 tb=TB
 for key,value in dict(W=w,H=h,L=levels,WIN=window,IT=iterations,MF=maxflow,F=len(pairs),T=len(expected)).items():tb=tb.replace('@'+key+'@',str(value))
 (td/'tb.sv').write_text(tb)
 p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'pyramidal_lk_flow.v'),str(td/'tb.sv')],cwd=td,capture_output=True,text=True)
 if p.returncode:raise RuntimeError(p.stderr)
 p=subprocess.run(['vvp',str(td/'sim')],cwd=td,capture_output=True,text=True,timeout=360)
 if p.returncode:raise RuntimeError(p.stdout+p.stderr)
 result=dict(width=w,height=h,levels=levels,window=window,iterations=iterations,max_flow_q=maxflow,frames=len(pairs),output_pixels=len(expected),texture_invalid=texture,oob=oob,overflow=overflow,elapsed_seconds=round(time.perf_counter()-started,3),status='PASS');print(result,flush=True);return result
def main():
 started=time.perf_counter()
 ref32,cur32,numerical=numerical_audit();rng=np.random.default_rng(781);results=[]
 with tempfile.TemporaryDirectory(prefix='pyramidal_flow_') as temporary:
  td=Path(temporary)
  for w,h,l,win,it,mf in [(8,8,2,3,2,32767),(9,11,3,5,2,32767),(8,8,2,3,2,8),(32,32,3,5,4,32767)]:
   if w==32:pairs=[(ref32,cur32,0)]
   else:
    a=rng.integers(0,256,(h,w),dtype=np.uint8);b=cv2.warpAffine(a,np.float32([[1,0,2],[0,1,1]]),(w,h),borderMode=cv2.BORDER_REPLICATE)
    pairs=[(a,a,0),(a,b,0),(np.full((h,w),67,np.uint8),np.full((h,w),71,np.uint8),0),(a,a,1),(a,a,0)]
   results.append(run_profile(td,w,h,l,win,it,mf,pairs))
 from test_pyramidal_protocol import main as protocol_main
 protocol_main()
 result=dict(status='PASS',elapsed_seconds=round(time.perf_counter()-started,3),protocol='PASS test_pyramidal_protocol.py',profiles=results,numerical_audit=numerical,source_sha256=hashlib.sha256((ROOT/'pyramidal_lk_flow.v').read_bytes()).hexdigest(),test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),board_verified=False)
 (ROOT/'test_result.json').write_text(json.dumps(result,indent=2)+'\n');print(result,flush=True)
if __name__=='__main__':main()
