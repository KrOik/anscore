"""Exact integer map/weight oracle plus actual OpenCV remap, source-bound simulations."""
from pathlib import Path
import sys,tempfile,json,hashlib,re
import numpy as np,cv2
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'stereo_rectify.sv'
def hashes():return {RTL.name:hashlib.sha256(RTL.read_bytes()).hexdigest()}
def oracle(src,mx,my,fill,compat):
 h,w=src.shape;oh,ow=mx.shape;out=np.empty((oh,ow),dtype=np.int64);valid=np.ones((oh,ow),dtype=bool);F=5 if compat else 8;scale=1<<F
 for y in range(oh):
  for x in range(ow):
   X=int(round(int(mx[y,x])/8)) if compat else int(mx[y,x]);Y=int(round(int(my[y,x])/8)) if compat else int(my[y,x]);ix,fx=divmod(X,scale);iy,fy=divmod(Y,scale);total=0
   for j in [0,1]:
    for i in [0,1]:
     weight=(fx if i else scale-fx)*(fy if j else scale-fy);inside=0<=ix+i<w and 0<=iy+j<h
     if weight and not inside:valid[y,x]=False
     total+=weight*(int(src[iy+j,ix+i]) if inside else fill)
   out[y,x]=(total+scale*scale//2)//(scale*scale)
 return out,valid
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,map_begin_valid=0,map_valid=0,map_last=0,map_commit_valid=0,map_abort=0,map_done_ready=0;
reg start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
reg signed[23:0]map_x=0,map_y=0;reg[B-1:0]cfg_fill=FILL,s_data=0;
wire map_begin_ready,map_ready,map_commit_ready,map_done_valid,map_done_error,map_active_valid,start_ready,s_ready,m_valid,m_sof,m_eol,m_last,m_in_bounds,done_valid,done_error,busy;
wire[7:0]map_error_code,error_code;wire[B-1:0]m_data;
stereo_rectify #(.BITS(B),.SRC_WIDTH(SW),.SRC_HEIGHT(SH),.DST_WIDTH(DW),.DST_HEIGHT(DH),.CV_COMPAT(CV)) dut(.*);
reg[47:0]mapmem[0:DN-1];reg[B-1:0]pixels[0:SN-1];reg[B:0]expected[0:DN-1];
reg[B+3:0]held;reg stalled=0;integer cyc=0,i,got=0,rep;
wire[B+3:0]token={m_last,m_eol,m_sof,m_in_bounds,m_data};
always @(negedge clk)begin cyc=cyc+1;ce=cyc%13>1;m_ready=cyc%7<4;if(cyc>200000)$fatal(1,"timeout state %d map %d",dut.state,dut.map_state);end
always @(posedge clk)if(rst_n)begin
 if(stalled&&(!m_valid||token!==held))$fatal(1,"output hold");stalled=m_valid&&!(ce&&m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin
 if(got>=2*DN||{m_in_bounds,m_data}!==expected[got%DN])$fatal(1,"pixel %d got %h expect %h",got,{m_in_bounds,m_data},expected[got%DN]);
 if(m_sof!==(got%DN==0)||m_eol!==((got%DW)==DW-1)||m_last!==(got%DN==DN-1))$fatal(1,"output markers");got=got+1;end
end
 task tick;begin @(negedge clk);#1;end endtask
 task ackmap;begin repeat(3)tick;map_done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;map_done_ready=0;end endtask
 initial begin
 $readmemh("MAPFILE",mapmem);$readmemh("PIXFILE",pixels);$readmemh("EXPFILE",expected);
 repeat(3)tick;rst_n=1;tick;
 map_begin_valid=1;while(!map_begin_ready)tick;@(posedge clk);#1;tick;map_begin_valid=0;
 for(i=0;i<DN;i=i+1)begin map_x=mapmem[i][47:24];map_y=mapmem[i][23:0];map_valid=1;map_last=i==DN-1;while(!map_ready)tick;@(posedge clk);#1;tick;end
 map_valid=0;map_last=0;map_commit_valid=1;while(!map_commit_ready)tick;@(posedge clk);#1;tick;map_commit_valid=0;
 if(!map_done_valid||map_done_error||!map_active_valid)$fatal(1,"map commit");ackmap;
 for(rep=0;rep<2;rep=rep+1)begin
 start_valid=1;while(!start_ready)tick;@(posedge clk);#1;tick;start_valid=0;
 for(i=0;i<SN;i=i+1)begin s_data=pixels[i];s_sof=i==0;s_eol=i%SW==SW-1;s_last=i==SN-1;s_valid=1;while(!s_ready)tick;@(posedge clk);#1;tick;end
 s_valid=0;while(!done_valid)tick;if(done_error||got!=(rep+1)*DN)$fatal(1,"frame error %h got%d",error_code,got);
 repeat(7)tick;if(!done_valid||done_error)$fatal(1,"done hold");done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;done_ready=0;
 end
 $display("PASS stereo_rectify");$finish;end
endmodule
'''
def run_case(name,src,mx,my,bits=8,fill=0,compat=1):
 expect,valid=oracle(src,mx,my,fill,compat);h,w=src.shape;dh,dw=mx.shape;N=dw*dh
 cvsrc=src.astype(np.uint8 if bits==8 else np.uint16);cvx=mx.astype(np.float32)/256;cvy=my.astype(np.float32)/256
 cvfloat=cv2.remap(cvsrc,cvx,cvy,cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT,borderValue=fill).astype(np.int64)
 fixed=cv2.convertMaps(cvx,cvy,cv2.CV_16SC2)
 cvfixed=cv2.remap(cvsrc,*fixed,cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT,borderValue=fill).astype(np.int64)
 cv=cvfixed if compat else cvfloat
 delta=np.abs(cv-expect);bound=1
 float_delta=np.abs(cvfloat-expect);fixed_delta=np.abs(cvfixed-expect)
 phase_bound=((1<<bits)-1)//32+2
 assert max(float_delta.max(),fixed_delta.max())<=phase_bound
 assert delta.max()<=bound,(name,int(delta.max()),bound)
 with tempfile.TemporaryDirectory(prefix='stereo_rectify_') as tmp:
  d=Path(tmp);(d/'map.hex').write_text('\n'.join(f'{((int(x)&0xffffff)<<24)|(int(y)&0xffffff):012x}' for x,y in zip(mx.ravel(),my.ravel()))+'\n');(d/'src.hex').write_text('\n'.join(f'{int(v):x}' for v in src.ravel())+'\n');(d/'expected.hex').write_text('\n'.join(f'{(int(ok)<<bits)|int(v):x}' for ok,v in zip(valid.ravel(),expect.ravel()))+'\n')
  tb=TB
  # Longer identifiers before single-letter placeholders.
  for a,b in [('MAPFILE',(d/'map.hex').as_posix()),('PIXFILE',(d/'src.hex').as_posix()),('EXPFILE',(d/'expected.hex').as_posix()),('FILL',str(fill)),('SN',str(w*h)),('DN',str(N)),('SW',str(w)),('SH',str(h)),('DW',str(dw)),('DH',str(dh)),('CV',str(compat))]:tb=re.sub(r"\b"+a+r"\b",lambda m:b,tb)

  tb=re.sub(r'\bB\b',str(bits),tb);(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE.parents[3],d/'compile.log');text=execute(['vvp',d/'a.vvp'],HERE.parents[3],d/'sim.log');assert 'PASS stereo_rectify' in text
 return dict(name=name,bits=bits,source=[w,h],destination=[dw,dh],compat=compat,pixels=2*N,invalid_outputs=2*int((~valid).sum()),opencv_max_error=int(delta.max()),opencv_mae=float(delta.mean()),opencv_bound=bound,opencv_float_map_error=int(float_delta.max()),opencv_fixed_map_error=int(fixed_delta.max()),phase_variant_bound=phase_bound)
def main():
 rng=np.random.default_rng(729);rows=[]
 for bits in [8,10,12]:
  for compat in [0,1]:
   for mode in ['identity','nonlinear','signed_edges']:
    h,w=7,9;src=rng.integers(0,1<<bits,(h,w));y,x=np.indices((5,11));mx=x*256;my=y*256
    if mode=='nonlinear':mx=np.rint((x+.02*(x-5)**2+.35*np.sin(y))*256).astype(int);my=np.rint((y+.015*(y-2)**2+.4*np.cos(x))*256).astype(int)
    elif mode=='signed_edges':mx=rng.integers(-800,(w+2)*256,mx.shape);my=rng.integers(-800,(h+2)*256,my.shape);mx.ravel()[:6]=[-8388608,8388607,-4,4,12,20];my.ravel()[:6]=[0,0,0,0,0,0]
    row=run_case(f'{mode}_b{bits}_cv{compat}',src,mx,my,bits,(1<<bits)//3,compat);rows.append(row);print(row,flush=True)
 for w,h in [(1,1),(1,5),(6,1),(16,12)]:
  src=rng.integers(0,256,(h,w));y,x=np.indices((h,w));row=run_case(f'geometry_{w}x{h}',src,x*256,y*256,8,29,1);rows.append(row);print(row,flush=True)
 K=np.array([[11.,0.,7.5],[0.,12.,5.5],[0.,0.,1.]])
 R,_=cv2.Rodrigues(np.array([.005,.03,-.01]));dist=np.array([-.23,.08,.002,-.001,0.])
 calibrated_x,calibrated_y=cv2.initUndistortRectifyMap(K,dist,R,K,(16,12),cv2.CV_32FC1)
 mx=np.rint(calibrated_x*256).astype(int);my=np.rint(calibrated_y*256).astype(int)
 for bits in [8,10,12]:
  row=run_case(f'opencv_calibration_map_b{bits}',rng.integers(0,1<<bits,(12,16)),mx,my,bits,17,0);row['map_source']='cv2.initUndistortRectifyMap supplied synthetic K/dist/R (not measured calibration)';rows.append(row);print(row,flush=True)
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),opencv_version=cv2.__version__,cases=rows),indent=2)+'\n')
if __name__=='__main__':main()

