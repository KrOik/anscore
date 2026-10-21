import sys,json,hashlib,tempfile,random,re
from fractions import Fraction
from pathlib import Path
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
SOURCES=[HERE/'lens_shading.sv']
def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in SOURCES}
def channel(pattern,x,y):return ((0,1,2,3),(1,0,3,2),(2,3,0,1),(3,2,1,0))[pattern][2*(y%2)+x%2]
def oracle(pixels,w,h,gw,gh,gains,pattern,gf,bits):
 out=[];nums=[]
 for i,raw in enumerate(pixels):
  x,y=i%w,i//w;u=Fraction(x*(gw-1),w-1)if w>1 else Fraction(0);v=Fraction(y*(gh-1),h-1)if h>1 else Fraction(0)
  ix=min(gw-2,int(u));iy=min(gh-2,int(v));fx=u-ix;fy=v-iy;ch=channel(pattern,x,y)
  def g(dx,dy):return gains[ch*gw*gh+(iy+dy)*gw+ix+dx]
  gain=g(0,0)*(1-fx)*(1-fy)+g(1,0)*fx*(1-fy)+g(0,1)*(1-fx)*fy+g(1,1)*fx*fy
  exact=raw*gain/(1<<gf);q,r=divmod(exact.numerator,exact.denominator);q+=r*2>=exact.denominator
  out.append((min((1<<bits)-1,q),int(q>((1<<bits)-1))))
  n=gain*(w-1 if w>1 else 1)*(h-1 if h>1 else 1);assert n.denominator==1;nums.append(int(n))
 return out,nums
TB=r'''module tb;
localparam W=WW,H=HH,B=BB,GW=GWW,GH=GHH,GB=GBB,GF=GFF,E=4*GW*GH;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cfg_valid=0,cfg_commit_valid=0,start_valid=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
reg[15:0]cfg_index;reg[GB-1:0]cfg_gain;reg[1:0]cfg_pattern=PATTERN;reg[B-1:0]s_data;
wire cfg_ready,cfg_commit_ready,cfg_error,cfg_pending,start_ready,s_ready,m_valid,m_sof,m_eol,m_last,m_saturated,done_valid,done_error;wire[B-1:0]m_data;wire[2:0]error_code;
lens_shading #(.WIDTH(W),.HEIGHT(H),.BITS(B),.GRID_WIDTH(GW),.GRID_HEIGHT(GH),.GAIN_BITS(GB),.GAIN_FRAC(GF))dut(.*);
reg[GB-1:0]gains[0:E-1];reg[B-1:0]pixels[0:W*H-1];reg[63:0]weight[0:W*H-1];integer i,n=0,cy=0,computed=0;reg held=0;reg[B+3:0]token;reg[31:0]rng=32'h7231a98b;
always @(posedge clk)begin cy=cy+1;if(cy>2000000)$fatal(1,"timeout%d",dut.state);
if(rst_n)begin
if(held&&(!m_valid||{m_data,m_saturated,m_sof,m_eol,m_last}!==token))$fatal(1,"hold");
held=m_valid&&!(ce&&m_ready);token={m_data,m_saturated,m_sof,m_eol,m_last};
if(ce&&dut.state==7)begin if(dut.weighted_gain!==weight[computed])$fatal(1,"bilinear numerator %d got%0d expected%0d",computed,dut.weighted_gain,weight[computed]);computed=computed+1;end
if(ce&&m_valid&&m_ready)begin case(n) CHECKS default:$fatal(1,"extra");endcase
if(m_sof!=(n==0)||m_eol!=(n%W==W-1)||m_last!=(n==W*H-1))$fatal(1,"markers");n=n+1;end end else held=0;end
 task tick;begin @(negedge clk);#1;end endtask
initial begin INIT
repeat(2)tick;rst_n=1;tick;
for(i=0;i<E;i=i+1)begin cfg_index=i;cfg_gain=gains[i];cfg_valid=1;tick;if(!cfg_ready)$fatal(1,"cfg ready");end
cfg_valid=0;cfg_commit_valid=1;tick;cfg_commit_valid=0;#1;if(cfg_error||cfg_pending||!start_ready)$fatal(1,"commit");
start_valid=1;tick;start_valid=0;cfg_pattern=3-PATTERN;
// Busy writes go exclusively to the inactive bank and must not change this frame.
cfg_valid=1;cfg_index=0;cfg_gain=0;
for(i=0;i<W*H;i=i+1)begin
s_data=pixels[i];s_sof=i==0;s_eol=i%W==W-1;s_last=i==W*H-1;s_valid=1;
#1;while(!s_ready)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[0]||rng[2];m_ready=rng[3];tick;end
tick;s_valid=0;
end
while(!done_valid)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[0]||rng[2];m_ready=rng[3];tick;end
ce=1;m_ready=0;cfg_valid=0;if(done_error||error_code||cfg_error||n!=W*H||computed!=W*H)$fatal(1,"completion %d %d",n,computed);
repeat(3)begin tick;if(!done_valid)$fatal(1,"done hold");end
ce=0;done_ready=1;repeat(2)tick;if(!done_valid)$fatal(1,"CE done");ce=1;tick;done_ready=0;#1;if(!start_ready)$fatal(1,"recovery idle");
$display("PASS pixels=%0d cycles=%0d",n,cy);$finish;end endmodule'''
def run_case(label,w,h,bits,gw,gh,gb,gf,pattern,gains,pixels):
 out,nums=oracle(pixels,w,h,gw,gh,gains,pattern,gf,bits)
 checks='\n'.join(f'{i}:if(m_data!={v}||m_saturated!={sat})$fatal(1,"pixel {i} rawout%0d sat%0d",m_data,m_saturated);'for i,(v,sat)in enumerate(out))
 init='\n'.join(f'gains[{i}]={v};'for i,v in enumerate(gains))+'\n'+'\n'.join(f'pixels[{i}]={v};weight[{i}]=64\'d{nums[i]};'for i,v in enumerate(pixels))
 tb=TB
 for key,value in [('WW',w),('HH',h),('BB',bits),('GWW',gw),('GHH',gh),('GBB',gb),('GFF',gf),('PATTERN',pattern),('CHECKS',checks),('INIT',init)]:tb=re.sub(r'\b'+key+r'\b',lambda _:str(value),tb)
 with tempfile.TemporaryDirectory(prefix='lens_shading_')as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');text=execute(['vvp',p/'sim'],p,p/'sim.log',timeout=180);assert 'PASS' in text
 print(label,text.strip(),flush=True)
 return dict(label=label,width=w,height=h,bits=bits,grid_width=gw,grid_height=gh,gain_bits=gb,gain_frac=gf,pattern=pattern,pixels=w*h,saturations=sum(v[1]for v in out),simulation=text.strip())
def main():
 frozen=hashes();rng=random.Random(1237);cases=[]
 for pattern in range(4):
  gains=[2048+ch*1024+gx*301+gy*157 for ch in range(4)for gy in range(3)for gx in range(3)]
  cases.append(('four_plane_nonlinear',33,25,12,3,3,16,12,pattern,gains,[rng.randrange(4096)for _ in range(825)]))
 for bits in (8,10,12):cases.append(('unity',11,7,bits,3,3,16,12,2,[4096]*36,[rng.randrange(1<<bits)for _ in range(77)]))
 for w,h,gw,gh in [(1,1,5,5),(1,13,3,4),(13,1,4,3),(14,10,5,4),(3,2,9,9)]:
  gains=[rng.randrange(32768)for _ in range(4*gw*gh)];cases.append(('thin_nondivisible',w,h,10,gw,gh,16,12,1,gains,[rng.randrange(1024)for _ in range(w*h)]))
 cases.append(('gain_max_saturation',5,3,12,3,3,24,0,3,[(1<<24)-1]*36,[0,1,4095]*5))
 cases.append(('gain_zero',5,3,8,2,2,2,0,0,[0]*16,[255]*15))
 cases.append(('half_up_round',2,1,8,2,2,8,1,0,[1]*16,[1,3]))
 cases.append(('max_gain_fraction',7,5,12,3,3,24,20,2,[rng.randrange(1<<24)for _ in range(36)],[rng.randrange(4096)for _ in range(35)]))
 rows=[run_case(*c)for c in cases];assert hashes()==frozen
 (HERE/'test_result.json').write_text(json.dumps(dict(status='PASS',sources=frozen,oracle='independent Fraction bilinear coordinates and single RAW half-up rounding',cases=rows,board=False),indent=2)+'\n')
if __name__=='__main__':main()
