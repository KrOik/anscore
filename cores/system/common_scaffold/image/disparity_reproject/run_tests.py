import sys,json,hashlib,tempfile,random,math
from decimal import Decimal,localcontext
from pathlib import Path
import numpy as np
import cv2
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
SOURCES=[HERE/'disparity_reproject.sv']
def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in SOURCES}
def reference(q,disp,invalid,w,h,df,of,ob):
 out=[];hom=[]
 for i,d in enumerate(disp):
  v=[(i%w)<<df,(i//w)<<df,d,1<<df];a=[sum(q[row*4+k]*v[k]for k in range(4))for row in range(4)];hom.append(a)
  xyz=[0,0,0];sat=0;bad=int(invalid[i]);wz=0;wn=0
  if not bad:
   wn=int(a[3]<0)
   if a[3]==0:bad=wz=1
   else:
    for axis in range(3):
     n=abs(a[axis])<<of;den=abs(a[3]);mag,rem=divmod(n,den);mag+=2*rem>=den
     value=-mag if (a[axis]<0) != (a[3]<0) else mag
     clipped=max(-(1<<(ob-1)),min((1<<(ob-1))-1,value));xyz[axis]=clipped
     if clipped!=value:sat|=1<<axis;bad=1
  out.append((*xyz,bad,wz,wn,sat))
 return out,hom
TB=r'''module tb;
localparam W=WW,H=HH,DB=DBB,DF=DFF,QB=QBB,QF=QFF,OB=OBB,OF=OFF;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cfg_valid=0,cfg_commit_valid=0,start_valid=0,s_valid=0,s_invalid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
reg[3:0]cfg_index;reg signed[QB-1:0]cfg_value;reg signed[DB-1:0]s_disparity;
wire cfg_ready,cfg_commit_ready,cfg_error,start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,m_invalid,m_wzero,m_wnegative;wire[2:0]error_code,m_saturated;wire signed[OB-1:0]m_x,m_y,m_z;
disparity_reproject #(.WIDTH(W),.HEIGHT(H),.DISP_BITS(DB),.DISP_FRAC(DF),.Q_BITS(QB),.Q_FRAC(QF),.OUT_BITS(OB),.OUT_FRAC(OF))dut(.*);
reg signed[QB-1:0]q[0:15];reg signed[DB-1:0]d[0:W*H-1];reg inv[0:W*H-1];integer i,n=0,cy=0,processed=0;reg held=0;reg[3*OB+8:0]token;reg[31:0]rng=32'h752389af;
always @(posedge clk)begin cy=cy+1;if(cy>2000000)$fatal(1,"timeout state%d",dut.state);
if(rst_n)begin
if(held&&(!m_valid||{m_x,m_y,m_z,m_invalid,m_wzero,m_wnegative,m_saturated,m_sof,m_eol,m_last}!==token))$fatal(1,"hold");
held=m_valid&&!(ce&&m_ready);token={m_x,m_y,m_z,m_invalid,m_wzero,m_wnegative,m_saturated,m_sof,m_eol,m_last};
if(ce&&dut.state==5)begin case(dut.pixel) HOMCHECKS default:begin end endcase processed=processed+1;end
if(ce&&m_valid&&m_ready)begin case(n) CHECKS default:$fatal(1,"extra");endcase
if(m_sof!=(n==0)||m_eol!=(n%W==W-1)||m_last!=(n==W*H-1))$fatal(1,"markers");n=n+1;end end else held=0;end
 task tick;begin @(negedge clk);#1;end endtask
initial begin INIT
repeat(2)tick;rst_n=1;tick;
for(i=0;i<16;i=i+1)begin cfg_valid=1;cfg_index=i;cfg_value=q[i];tick;if(!cfg_ready)$fatal(1,"cfg ready");end
cfg_valid=0;cfg_commit_valid=1;tick;cfg_commit_valid=0;#1;if(cfg_error||!start_ready)$fatal(1,"commit");
start_valid=1;tick;start_valid=0;
// Configuration changes and commit requests during busy must not alter latched Q.
cfg_valid=1;cfg_commit_valid=1;cfg_index=0;cfg_value=0;
for(i=0;i<W*H;i=i+1)begin
s_disparity=d[i];s_invalid=inv[i];s_sof=i==0;s_eol=i%W==W-1;s_last=i==W*H-1;s_valid=1;
#1;while(!s_ready)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[0]||rng[2];m_ready=rng[3];tick;end
tick;s_valid=0;
end
while(!done_valid)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[0]||rng[2];m_ready=rng[3];tick;end
ce=1;m_ready=0;cfg_valid=0;cfg_commit_valid=0;if(done_error||error_code||n!=W*H||processed!=PROCESSED)$fatal(1,"completion %d processed %d",n,processed);
repeat(3)begin tick;if(!done_valid)$fatal(1,"done hold");end
ce=0;done_ready=1;repeat(2)tick;if(!done_valid)$fatal(1,"CE done");ce=1;tick;done_ready=0;if(!start_ready)$fatal(1,"recovery idle");
$display("PASS pixels=%0d cycles=%0d",n,cy);$finish;end endmodule'''
def cv_compare(q,d,invalid,out,hom,w,h,df,qf,of,ob):
 disparity=np.array(d,dtype=np.float32).reshape(h,w)/(2**df)
 mat=np.array(q,dtype=np.float64).reshape(4,4)/(2**qf)
 cv=cv2.reprojectImageTo3D(disparity,mat,handleMissingValues=False)
 max_delta=0.;max_bound=0.;count=0
 for i,row in enumerate(out):
  if row[3]:continue
  a=hom[i];v=[(i%w)<<df,(i//w)<<df,d[i],1<<df]
  errors=[sum(abs(q[r*4+k]*v[k])for k in range(4))*2.0**-49 for r in range(4)]
  assert abs(a[3])>errors[3]
  for axis in range(3):
   with localcontext()as ctx:
    ctx.prec=90;exact=Decimal(a[axis])/Decimal(a[3]);fixed=Decimal(row[axis])/(2**of)
    assert abs(exact-fixed)<=Decimal(1)/(2**(of+1))
   ratio=float(exact);cvvalue=float(cv.reshape(-1,3)[i,axis]);spacing=abs(float(np.spacing(np.float32(cvvalue))))
   arithmetic=(errors[axis]+abs(ratio)*errors[3])/(abs(a[3])-errors[3])
   # OpenCV stores homogeneous XYZ into Vec3f before division: allow its float32 rounding too.
   intermediate=abs(ratio)*2.0**-23
   bound=.5/(2**of)+spacing+arithmetic+intermediate;delta=abs(cvvalue-row[axis]/(2**of))
   assert math.isfinite(cvvalue)and delta<=bound+1e-14,(i,axis,delta,bound)
   max_delta=max(max_delta,delta);max_bound=max(max_bound,bound);count+=1
 return dict(components=count,max_delta=max_delta,max_bound=max_bound)
def run_case(label,w,h,db,df,qb,qf,ob,of,q,d,invalid=None):
 invalid=invalid or [0]*len(d);out,hom=reference(q,d,invalid,w,h,df,of,ob)
 checks='\n'.join(f'{i}:if($signed(m_x)!={x}||$signed(m_y)!={y}||$signed(m_z)!={z}||m_invalid!={bad}||m_wzero!={wz}||m_wnegative!={wn}||m_saturated!={sat})$fatal(1,"pixel {i}: %0d %0d %0d bad%0d sat%0d",$signed(m_x),$signed(m_y),$signed(m_z),m_invalid,m_saturated);'for i,(x,y,z,bad,wz,wn,sat)in enumerate(out))
 hc='\n'.join(f'{i}:begin '+''.join(f'if($signed(dut.homogeneous[{axis}])!==64\'sd{v})$fatal(1,"homogeneous {i} {axis}");'if v>=0 else f'if($signed(dut.homogeneous[{axis}])!==-64\'sd{-v})$fatal(1,"homogeneous {i} {axis}");'for axis,v in enumerate(a))+'end'for i,a in enumerate(hom)if not invalid[i])
 init='\n'.join(f'q[{i}]={v};'for i,v in enumerate(q))+'\n'+'\n'.join(f'd[{i}]={v};inv[{i}]={invalid[i]};'for i,v in enumerate(d))
 tb=TB
 import re
 for key,value in [('WW',w),('HH',h),('DBB',db),('DFF',df),('QBB',qb),('QFF',qf),('OBB',ob),('OFF',of),('CHECKS',checks),('HOMCHECKS',hc),('INIT',init),('PROCESSED',sum(not i for i in invalid))]:tb=re.sub(r'\b'+key+r'\b',lambda _:str(value),tb)
 with tempfile.TemporaryDirectory(prefix='reproject_')as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log')
  text=execute(['vvp',p/'sim'],p,p/'sim.log',timeout=180);assert 'PASS' in text
 metrics=cv_compare(q,d,invalid,out,hom,w,h,df,qf,of,ob)
 print(label,text.strip(),metrics,flush=True)
 return dict(label=label,width=w,height=h,disp_bits=db,disp_frac=df,q_bits=qb,q_frac=qf,out_bits=ob,out_frac=of,pixels=w*h,cv2=metrics,saturated=sum(bool(r[6])for r in out),zero_w=sum(r[4]for r in out),negative_w=sum(r[5]for r in out),simulation=text.strip())
def main():
 frozen=hashes();rng=random.Random(73192);cases=[]
 identity=[65536 if i%5==0 else 0 for i in range(16)]
 cases.append(('identity',7,5,24,4,32,16,32,12,identity,[rng.randrange(-4096,4096)for _ in range(35)]))
 canonical=[65536,0,0,-3*65536,0,65536,0,-2*65536,0,0,0,9*65536,0,0,2*65536,0]
 cases.append(('canonical_subpixel',7,5,24,4,32,16,32,12,canonical,[rng.randrange(-128,128)for _ in range(35)]))
 for j in range(4):
  q=[rng.randrange(-90000,90001)for _ in range(16)];q[15]+=500000
  cases.append((f'dense_general{j}',7,5,24,4,32,16,32,12,q,[rng.randrange(-2048,2048)for _ in range(35)]))
 q=identity.copy();q[15]=-65536;cases.append(('negative_w',4,3,24,4,32,16,32,12,q,[i-6 for i in range(12)]))
 q=identity.copy();q[15]=0;cases.append(('zero_w',4,3,24,4,32,16,32,12,q,list(range(12))))
 q=[2147483647,-2147483648,2147483647,-2147483648]*3+[0,0,0,1]
 cases.append(('extreme_sat',3,2,24,12,32,28,32,16,q,[-8388608,8388607,0,-1,1,4096]))
 q=[32767,-32768,32767,-32768]*3+[0,0,0,32767]
 cases.append(('small_width_q',5,3,12,3,16,8,16,6,q,[rng.randrange(-2048,2048)for _ in range(15)]))
 cases.append(('mixed_invalid',7,5,24,4,32,16,32,12,canonical,[i-16 for i in range(35)],[int(i%3==0)for i in range(35)]))
 cases.append(('all_invalid',7,5,24,4,32,16,32,12,identity,[0]*35,[1]*35))
 cases.append(('one_pixel_tie_round',1,1,8,0,8,0,8,0,[0,0,0,-1,0,0,0,1,0,0,0,3,0,0,0,2],[0]))
 q=[31,-17,7,29,-3,11,5,-9,4,2,-1,13,1,0,0,-3]
 cases.append(('general_w_crosses_zero',7,3,12,4,16,8,24,8,q,[rng.randrange(-128,128)for _ in range(21)]))
 cases.append(('exact_negative_limit',1,1,8,0,8,0,8,0,[0,0,0,-128,0,0,0,127,0,0,0,0,0,0,0,1],[0]))
 rows=[run_case(*c)for c in cases];assert hashes()==frozen
 (HERE/'test_result.json').write_text(json.dumps(dict(status='PASS',sources=frozen,opencv=cv2.__version__,cases=rows,board=False),indent=2)+'\n')
if __name__=='__main__':main()
