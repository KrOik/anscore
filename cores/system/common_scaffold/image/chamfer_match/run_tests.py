import sys,json,hashlib,tempfile,re
from pathlib import Path
import numpy as np
import scipy
from scipy.ndimage import distance_transform_edt
HERE=Path(__file__).resolve().parent;DEP=HERE.parent/'euclidean_distance'/'euclidean_distance.sv'
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
SOURCES=[HERE/'chamfer_match.sv',DEP]
def hashes():return {str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
def oracle(image,template):
 h,w=image.shape;th,tw=template.shape;features=list(zip(*np.where(image)));points=list(zip(*np.where(template)))
 distance=np.zeros((h,w),np.int64)
 if features:
  for y in range(h):
   for x in range(w):distance[y,x]=min((x-int(fx))**2+(y-int(fy))**2 for fy,fx in features)
  scipy_squared=np.rint(distance_transform_edt(~image)**2).astype(np.int64)
  assert np.array_equal(distance,scipy_squared)
 else:distance[:]=-1
 invalid=not points or not features;out=[]
 for y in range(h-th+1):
  for x in range(w-tw+1):
   total=0xffffffff if invalid else sum(int(distance[y+int(ty),x+int(tx)]) for ty,tx in points)
   score=0xffffffff if invalid else (total*256+len(points)//2)//len(points)
   out.append((x,y,score,total,int(invalid)))
 best=None if invalid else min(out,key=lambda p:(p[2],p[1],p[0]))
 return distance,out,best,len(points)
TB=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,t_valid=0,t_edge=0,t_sof=0,t_eol=0,t_last=0,s_valid=0,s_edge=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[3:0]cfg_template_width=TW,cfg_template_height=TH;
 wire start_ready,t_ready,s_ready,m_valid,m_invalid,m_sof,m_eol,m_last,done_valid,done_error,busy,best_valid;
 wire[31:0]m_score,m_sum_squared,best_score,best_sum_squared;wire[5:0]m_x,m_y,best_x,best_y;wire[6:0]template_edges;wire[3:0]error_code;
 chamfer_match #(.WIDTH(W),.HEIGHT(H))dut(.*);
 reg p[0:W*H-1],t[0:TW*TH-1];integer d[0:W*H-1];integer i,n=0,cy=0;reg checked=0,holding=0;reg[83:0]held;reg[31:0]rng=32'h1529abcd;
 wire[83:0]token={m_last,m_eol,m_sof,m_invalid,m_x,m_y,m_score,m_sum_squared};
 always @(posedge clk)begin
 cy=cy+1;if(cy>1200000)$fatal(1,"timeout %d EDT=%d",dut.state,dut.edt.state);
 if(rst_n)begin if(holding&&(!m_valid||token!==held))$fatal(1,"hold");holding=m_valid&&!(ce&&m_ready);held=token;end else holding=0;
 if(rst_n&&ce&&dut.state==4&&!checked)begin
 for(integer j=0;j<W*H;j=j+1)if(d[j]>=0&&dut.distances[j]!==d[j])$fatal(1,"EDT distance bin %d got%0d exp%0d",j,dut.distances[j],d[j]);checked=1;end
 if(rst_n&&ce&&m_valid&&m_ready)begin
 case(n) CHECKS default:$fatal(1,"extra output");endcase
 if(m_sof!=(n==0)||m_eol!=(m_x==W-TW)||m_last!=(n==COUNT-1))$fatal(1,"map markers");n=n+1;
 end end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin INIT
 tick;rst_n=1;tick;start_valid=1;tick;start_valid=0;cfg_template_width=0;cfg_template_height=15;
 for(i=0;i<TW*TH;i=i+1)begin t_edge=t[i];t_sof=i==0;t_eol=i%TW==TW-1;t_last=i==TW*TH-1;t_valid=1;
 if(i%3==0)begin ce=0;repeat(2)tick;if(t_ready)$fatal(1,"template CE");ce=1;#1;end
 while(!t_ready)tick;tick;t_valid=0;end
 for(i=0;i<W*H;i=i+1)begin s_edge=p[i];s_sof=i==0;s_eol=i%W==W-1;s_last=i==W*H-1;s_valid=1;
 if(i%7==0)begin ce=0;repeat(2)tick;if(s_ready)$fatal(1,"source CE");ce=1;#1;end
 while(!s_ready)tick;tick;s_valid=0;end
 while(!done_valid)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[0]||rng[2];m_ready=rng[3];tick;end
 ce=1;m_ready=0;if(done_error||error_code||n!=COUNT||template_edges!=EDGES||!checked)$fatal(1,"completion %d",n);
 BEST
 repeat(4)begin tick;if(!done_valid||done_error)$fatal(1,"held DONE");end
 ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"CE ACK");ce=1;tick;done_ready=0;
 $display("PASS scores=%d edges=%d cycles=%d",n,template_edges,cy);$finish;end endmodule'''
def run_case(image,template,label):
 distance,expected,best,count=oracle(image,template);h,w=image.shape;th,tw=template.shape
 checks='\n'.join(f'{i}:if(m_x!={x}||m_y!={y}||m_score!==32\'d{score}||m_sum_squared!==32\'d{total}||m_invalid!={invalid})$fatal(1,"score {i}: %0d %0d invalid%0d",m_score,m_sum_squared,m_invalid);' for i,(x,y,score,total,invalid) in enumerate(expected))
 best_check='if(best_valid||best_score||best_sum_squared||best_x||best_y)$fatal(1,"invalid best");' if best is None else f'if(!best_valid||best_x!={best[0]}||best_y!={best[1]}||best_score!={best[2]}||best_sum_squared!={best[3]})$fatal(1,"best");'
 init='\n'.join(f'p[{i}]=1\'b{int(v)};d[{i}]={int(distance.flat[i])};' for i,v in enumerate(image.flat))+'\n'+'\n'.join(f't[{i}]=1\'b{int(v)};' for i,v in enumerate(template.flat))
 tb=TB
 for k,v in [('CHECKS',checks),('INIT',init),('BEST',best_check),('W',w),('H',h),('TW',tw),('TH',th),('COUNT',len(expected)),('EDGES',count)]:tb=re.sub(r'\b'+k+r'\b',lambda _:str(v),tb)
 with tempfile.TemporaryDirectory(prefix='chamfer_match_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',*SOURCES,d/'tb.sv'],d,d/'compile.log')
  text=execute(['vvp',d/'sim'],d,d/'run.log',timeout=180);assert 'PASS' in text,text;print(label,text.strip(),flush=True)
 return dict(label=label,width=w,height=h,template_width=tw,template_height=th,template_edges=count,scores=len(expected),best=best,scipy_exact=bool(image.any()),invalid=best is None,simulation=text.strip())
def main():
 frozen=hashes();rng=np.random.default_rng(178)
 template=np.array([[1,0,0],[1,1,1]],bool);image=np.zeros((9,11),bool);image[4:6,5:8]=template
 cases=[(image,template,'inserted_exact'),(np.ones((7,7),bool),np.eye(3,dtype=bool),'zero_score_ties'),(np.zeros((7,9),bool),template,'no_image_edges'),(image,np.zeros((2,3),bool),'empty_template')]
 for shape,ts in [((1,1),(1,1)),((1,17),(1,4)),((17,1),(4,1)),((7,9),(3,2)),((8,8),(8,8)),((32,32),(8,8))]:
  cases.append((rng.random(shape)<.13,rng.random(ts)<.55,f'random_{shape}_{ts}'))
 edge=np.zeros((32,32),bool);edge[0,0]=1
 cases.extend([(edge,np.ones((1,1),bool),'maximum_distance'),(edge,np.ones((8,8),bool),'all64_edges'),(np.zeros((1,1),bool),np.zeros((1,1),bool),'both_empty')])
 rows=[run_case(*args) for args in cases];assert frozen==hashes()
 (HERE/'test_result.json').write_text(json.dumps(dict(status='PASS',cases=rows,sources=frozen,scipy_version=scipy.__version__,board=False),indent=2)+'\n')
if __name__=='__main__':main()
