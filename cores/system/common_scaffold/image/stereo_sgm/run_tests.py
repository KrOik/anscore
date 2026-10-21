import sys,json,hashlib,tempfile,random
from pathlib import Path
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
SOURCES=[HERE/'stereo_sgm.sv']
def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
def oracle(left,right,lb,rb,w,h,D,p1,p2):
 n=w*h;cost=[[(1024 if lb[i] or d>i%w or rb[i-d] else (left[i]^right[i-d]).bit_count()) for d in range(D)]for i in range(n)]
 total=[[0]*D for _ in range(n)];allpaths=[]
 for dx,dy in [(-1,0),(1,0),(0,-1),(0,1)]:
  path=[[0]*D for _ in range(n)]
  order=range(n) if dx<0 or dy<0 else reversed(range(n))
  for i in order:
   x,y=i%w,i//w;px,py=x+dx,y+dy
   for d in range(D):
    if 0<=px<w and 0<=py<h:
     prev=path[py*w+px];mn=min(prev)
     path[i][d]=cost[i][d]+min(prev[d],prev[d-1]+p1 if d else 10**9,prev[d+1]+p1 if d+1<D else 10**9,mn+p2)-mn
    else:path[i][d]=cost[i][d]
    total[i][d]+=path[i][d]
  allpaths.append(path)
 out=[]
 for i in range(n):
  candidates=[d for d in range(D)if d<=i%w and not lb[i] and not rb[i-d]]
  if candidates:
   d=min(candidates,key=lambda d:total[i][d]);out.append((d,total[i][d],0))
  else:out.append((0,16383,1))
 return out,total,allpaths
TB=r'''module tb;
localparam W=WW,H=HH,D=DD,B=BB;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,s_left_border=0,s_right_border=0,m_ready=0,done_ready=0;
reg[7:0]cfg_p1=PONE,cfg_p2=PTWO;reg[B-1:0]s_left,s_right;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,m_invalid;wire[2:0]error_code;wire[(D<=1?1:$clog2(D))-1:0]m_disparity;wire[13:0]m_score;
stereo_sgm #(.WIDTH(W),.HEIGHT(H),.DESC_BITS(B),.DISPARITIES(D))dut(.*);
integer i,n=0,cy=0;reg[B-1:0]left[0:W*H-1],right[0:W*H-1];reg lb[0:W*H-1],rb[0:W*H-1];
reg[31:0]rng=32'h12348765;reg held=0,agg_checked=0;reg[31:0]token;
always @(posedge clk)begin
cy=cy+1;if(cy>4000000)$fatal(1,"timeout state %d",dut.state);
if(rst_n)begin
if(ce&&dut.state==10&&!agg_checked)begin AGGCHECKS agg_checked=1;end
if(held&&(!m_valid||{m_disparity,m_score,m_invalid,m_sof,m_eol,m_last}!==token))$fatal(1,"unstable output");
held=m_valid&&!(ce&&m_ready);token={m_disparity,m_score,m_invalid,m_sof,m_eol,m_last};
if(ce&&m_valid&&m_ready)begin case(n) CHECKS default:$fatal(1,"extra");endcase
if(m_sof!=(n==0)||m_eol!=(n%W==W-1)||m_last!=(n==W*H-1))$fatal(1,"markers");n=n+1;end end else held=0;
end
 task tick;begin @(negedge clk);#1;end endtask
initial begin INIT
repeat(2)tick;rst_n=1;tick;start_valid=1;tick;start_valid=0;cfg_p1=255;cfg_p2=0;
for(i=0;i<W*H;i=i+1)begin
s_left=left[i];s_right=right[i];s_left_border=lb[i];s_right_border=rb[i];s_sof=i==0;s_eol=i%W==W-1;s_last=i==W*H-1;s_valid=1;
if(i%3==0)begin ce=0;repeat(2)tick;if(s_ready)$fatal(1,"CE ready");ce=1;#1;end
while(!s_ready)tick;tick;s_valid=0;
end
while(!done_valid)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[0]||rng[2];m_ready=rng[3];tick;end
ce=1;m_ready=0;if(done_error||error_code||n!=W*H)$fatal(1,"done %d err%d",n,error_code);
repeat(3)begin tick;if(!done_valid)$fatal(1,"done hold");end
ce=0;done_ready=1;repeat(2)tick;if(!done_valid)$fatal(1,"CE done");ce=1;tick;done_ready=0;
if(!start_ready)$fatal(1,"recovery ready");$display("PASS pixels=%0d cycles=%0d",n,cy);$finish;end endmodule'''
def run_case(label,w,h,D,B,p1,p2,left,right,lb=None,rb=None):
 lb=lb or [0]*(w*h);rb=rb or [0]*(w*h)
 out,total,paths=oracle(left,right,lb,rb,w,h,D,p1,p2)
 checks='\n'.join(f'{i}:if(m_disparity!={d}||m_score!={s}||m_invalid!={inv})$fatal(1,"pixel {i}: disparity %d score %d invalid %d",m_disparity,m_score,m_invalid);' for i,(d,s,inv)in enumerate(out))
 init='\n'.join(f'left[{i}]={B}\'d{l};right[{i}]={B}\'d{r};lb[{i}]={a};rb[{i}]={b};' for i,(l,r,a,b)in enumerate(zip(left,right,lb,rb)))
 tb=TB
 for key,value in [('WW',w),('HH',h),('DD',D),('BB',B),('PONE',p1),('PTWO',p2),('CHECKS',checks),('INIT',init),('AGGCHECKS','\n'.join(f'if(dut.aggregate[{i*D+d}]!={v})$fatal(1,"aggregate {i} {d}");'for i,row in enumerate(total)for d,v in enumerate(row)))]:tb=__import__('re').sub(r'\b'+key+r'\b',lambda _:str(value),tb)
 with tempfile.TemporaryDirectory(prefix='sgm_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',*SOURCES,d/'tb.sv'],d,d/'compile.log')
  text=execute(['vvp',d/'sim'],d,d/'sim.log',timeout=180);assert 'PASS' in text
 print(label,text.strip(),flush=True)
 return dict(label=label,width=w,height=h,disparities=D,descriptor_bits=B,p1=p1,p2=p2,pixels=w*h,simulation=text.strip(),directions=4)
def main():
 frozen=hashes();rng=random.Random(342);rows=[]
 for w,h,D,B,p1,p2 in [(1,1,1,1,0,0),(9,1,4,8,2,8),(1,9,1,24,3,12),(7,5,4,24,3,15),(8,6,8,64,255,255),(16,8,8,24,2,20),(5,4,3,8,0,0)]:
  left=[rng.getrandbits(B)for _ in range(w*h)];right=[rng.getrandbits(B)for _ in left]
  rows.append(run_case('random',w,h,D,B,p1,p2,left,right))
 rows.append(run_case('all_ties',8,4,5,8,2,9,[0]*32,[0]*32))
 rows.append(run_case('all_invalid',8,4,5,8,2,9,[0]*32,[0]*32,[1]*32,[1]*32))
 left=[rng.getrandbits(24)for _ in range(96)];right=[left[y*12+min(11,x+2)]for y in range(8)for x in range(12)]
 rows.append(run_case('shift2_occlusion_borders',12,8,6,24,3,17,left,right,[int(i%12 in (0,11))for i in range(96)],[int(i//12 in(0,7))for i in range(96)]))
 assert hashes()==frozen
 (HERE/'test_result.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows,board=False),indent=2)+'\n')
if __name__=='__main__':main()

