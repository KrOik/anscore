"""Actual exhaustive SAD RTL vectors drive compensation RTL without host replacement."""
from pathlib import Path
import sys,random,tempfile,json,hashlib,importlib.util
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
spec=importlib.util.spec_from_file_location('motion_compensation_test_helpers',HERE/'run_tests.py')
helpers=importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
HEADER=helpers.HEADER

def main():
 w,h,b,bw,bh,r=7,5,8,3,2,1
 rng=random.Random(7101)
 blocks=[(x,y,min(bw,w-x),min(bh,h-y)) for y in range(0,h,bh) for x in range(0,w,bw)]
 frames=[]
 for mode in range(3):
  ref=[rng.randrange(256) for _ in range(w*h)];cur=[0]*(w*h)
  for bx,by,ww,hh in blocks:
   candidates=[(dx,dy) for dy in range(-r,r+1) for dx in range(-r,r+1) if 0<=bx+dx and bx+dx+ww<=w and 0<=by+dy and by+dy+hh<=h]
   dx,dy=(0,0) if mode==0 else rng.choice(candidates)
   for j in range(hh):
    for i in range(ww):cur[(by+j)*w+bx+i]=ref[(by+j+dy)*w+bx+i+dx] if mode<2 else rng.randrange(256)
  expected=[]
  for bx,by,ww,hh in blocks:
   scores=[]
   for dy in range(-r,r+1):
    for dx in range(-r,r+1):
     if bx+dx<0 or by+dy<0 or bx+dx+ww>w or by+dy+hh>h:continue
     sad=sum(abs(cur[(by+j)*w+bx+i]-ref[(by+j+dy)*w+bx+i+dx]) for j in range(hh) for i in range(ww))
     scores.append((sad,abs(dx)+abs(dy),dy,dx))
   best=min(scores);expected.append((best[3],best[2],best[0]>0))
  frames.append((ref,cur,expected))
 tb=HEADER.replace('module tb;',f'module tb;localparam W={w},H={h},B={b},BW={bw},BH={bh};')
 tb=tb[:tb.index('initial begin @(negedge clk);')]
 for port,normal,est in (('vector_valid','vv','ev'),('vector_x','vx','ex'),('vector_y','vy','ey'),('vector_width','vw','ew'),('vector_height','vh','eh'),('vector_dx','dx','edx'),('vector_dy','dy','edy'),('vector_invalid','vi','einv')):
  tb=tb.replace(f'.{port}({normal})',f'.{port}(chain?{est}:{normal})')
 declarations=r'''
reg chain=0,esv=0,esof=0,eeol=0,ecv=0,edr=0;
reg [B-1:0] curp=0,refp=0;
wire esr,ecr,ecd,ev,einv,es,el,edone,ederr;wire [1:0] ereason,eec;
wire signed [15:0] edx,edy;wire [15:0] ex,ey,ew,eh;wire [31:0] sad,second_sad,gap;
'''
 tb=tb.replace('reg clk=0;',declarations+'reg clk=0;')
 tb+=r'''
img_block_motion #(.WIDTH(W),.HEIGHT(H),.BITS(B),.BLOCK_W(BW),.BLOCK_H(BH),.SEARCH_RANGE(1)) estimator(
.clk(clk),.rst_n(rst_n),.clk_en(ce),.cfg_valid(ecv),.cfg_ready(ecr),.cfg_max_sad(32'd0),.cfg_min_gap(32'd0),.cfg_done(ecd),
.s_current(curp),.s_reference(refp),.s_valid(esv),.s_ready(esr),.s_sof(esof),.s_eol(eeol),
.m_valid(ev),.m_ready(chain&&vr),.m_dx(edx),.m_dy(edy),.m_sad(sad),.m_second_sad(second_sad),.m_gap(gap),
.m_x(ex),.m_y(ey),.m_width(ew),.m_height(eh),.m_invalid(einv),.m_reason(ereason),.m_sof(es),.m_last(el),
.done_valid(edone),.done_ready(edr),.done_error(ederr),.error_code(eec));
task pair_pixel(input [B-1:0] cp,rp,input fs,le);begin
 while(!esr)tick;curp=cp;refp=rp;esof=fs;eeol=le;esv=1;tick;esv=0;
end endtask
initial begin @(negedge clk);tick;rst_n=1;tick;ecv=1;tick;ecv=0;chain=1;
'''
 for ref,cur,vectors in frames:
  for i,p in enumerate(ref):tb+=f"pixel({p},1'b{int(i==0)},1'b{int(i%w==w-1)});\n"
  for i,(cp,rp) in enumerate(zip(cur,ref)):tb+=f"pair_pixel({cp},{rp},1'b{int(i==0)},1'b{int(i%w==w-1)});\n"
  tb+=f"while(!edone)tick;if(ederr||vc!={len(blocks)})$fatal(1,\"estimator completion\");chain=0;\nlaunch(77);\n"
  for y in range(h):
   for x in range(w):
    dx,dy,invalid=vectors[(y//bh)*((w+bw-1)//bw)+x//bw]
    p=77 if invalid else ref[(y+dy)*w+x+dx]
    tb+=f"expect_pixel({p},{x},{y},2'd{int(invalid)});\n"
  tb+='release_frame;edr=1;tick;edr=0;chain=1;\n'
 tb+='$display("PASS block motion compensation chain");$finish;end endmodule\n'
 with tempfile.TemporaryDirectory(prefix='motion_comp_chain_') as td:
  t=Path(td);(t/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',t/'sim.vvp',HERE/'motion_compensation.sv',HERE.parent/'block_motion/img_block_motion.v',t/'tb.sv'],t,HERE/'chain_compile.log')
  output=execute(['vvp',t/'sim.vvp'],t,HERE/'chain.log');assert 'PASS block motion compensation chain' in output
 result={'status':'PASS','configuration':'7x5 B8 blocks3x2 searchR1','frames':3,'pixels':105,'vectors':27,'block_motion_sha256':hashlib.sha256((HERE.parent/'block_motion/img_block_motion.v').read_bytes()).hexdigest()}
 (HERE/'chain_evidence.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
if __name__=='__main__':main()
