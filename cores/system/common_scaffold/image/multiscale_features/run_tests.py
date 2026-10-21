from pathlib import Path
import sys,tempfile,math,json,random,hashlib
import numpy as np
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
PAT=H.parent/'oriented_brief'
CIRCLE=[(0,-3),(1,-3),(2,-2),(3,-1),(3,0),(3,1),(2,2),(1,3),(0,3),(-1,3),(-2,2),(-3,1),(-3,0),(-3,-1),(-2,-2),(-1,-3)]
def pyramid(a,levels):
 result=[a.astype(np.int64)];weights=(1,4,6,4,1)
 def refl(x,n):
  if n==1:return 0
  while x<0 or x>=n:x=-x if x<0 else 2*n-2-x
  return x
 for _ in range(1,levels):
  src=result[-1];hh,ww=src.shape
  dst=np.array([[(sum(weights[dy]*weights[dx]*int(src[refl(2*y+dy-2,hh),refl(2*x+dx-2,ww)]) for dy in range(5) for dx in range(5))+128)//256 for x in range((ww+1)//2)] for y in range((hh+1)//2)])
  result.append(dst)
 return result

def oracle(a,levels,r,t):
 raw=[int(v,16) for v in (PAT/f'base_r{r}.hex').read_text().splitlines()]
 def signed(v):v&=63;return v-64 if v>=32 else v
 pattern=[tuple(signed(v>>s) for s in (18,12,6,0)) for v in raw]
 trig=[round(127*math.cos(k*math.pi/8)) for k in range(16)];outputs=[];layer_counts=[]
 def nearest(v):return int(math.copysign(math.floor(abs(v)+.5),v))
 pyr=pyramid(a,levels)
 for lev,im in enumerate(pyr):
  h,w=im.shape;score=np.zeros_like(im)
  for y in range(3,h-3):
   for x in range(3,w-3):
    delta=[int(im[y+dy,x+dx]-im[y,x]) for dx,dy in CIRCLE]
    strength=max(max(min(delta[(start+k)%16] for k in range(9)),min(-delta[(start+k)%16] for k in range(9))) for start in range(16))
    score[y,x]=strength-1 if strength>t else 0
  count=0
  for y in range(r+1,h-r-1):
   for x in range(r+1,w-r-1):
    s=int(score[y,x])
    if s<=0:continue
    if any(score[y+dy,x+dx]>s or (score[y+dy,x+dx]==s and (dy<0 or dy==0 and dx<0)) for dy in (-1,0,1) for dx in (-1,0,1) if dx or dy):continue
    mx=sum(dx*int(im[y+dy,x+dx]) for dy in range(-r,r+1) for dx in range(-r,r+1) if dx*dx+dy*dy<=r*r)
    my=sum(dy*int(im[y+dy,x+dx]) for dy in range(-r,r+1) for dx in range(-r,r+1) if dx*dx+dy*dy<=r*r)
    angle=max(range(16),key=lambda k:mx*trig[k]+my*trig[(k+12)%16]);c=math.cos(angle*math.pi/8);sn=math.sin(angle*math.pi/8);desc=0
    for bit,(ax,ay,bx,by) in enumerate(pattern):
     xa,ya,xb,yb=map(nearest,(ax*c-ay*sn,ax*sn+ay*c,bx*c-by*sn,bx*sn+by*c))
     desc|=int(im[y+ya,x+xa]<im[y+yb,x+xb])<<bit
    outputs.append((desc,angle,int(bool(mx or my)),x,y,x<<lev,y<<lev,lev,s));count+=1
  layer_counts.append(count)
 return outputs,pyr,layer_counts

def run(w,h,bits,levels,r):
 rng=np.random.default_rng(w*17+h);maximum=(1<<bits)-1
 yy,xx=np.indices((h,w));coarse=rng.integers(0,maximum+1,((h+3)//4,(w+3)//4))
 texture=coarse[yy//4,xx//4]
 # Explicit scale mixture, a quarter-turn centered crop, a no-corner frame, then independent repeat.
 frames=[rng.integers(0,maximum+1,(h,w)),texture,np.roll(texture,3,axis=0),np.full((h,w),maximum//2),rng.integers(0,maximum+1,(h,w))]
 if w==h:frames[2]=np.rot90(texture,3)
 threshold=max(1,maximum//16);expect=[];pyramids=[];counts=[];ends=[]
 for im in frames:
  out,pyr,c=oracle(im,levels,r,threshold);expect+=out;pyramids.append(pyr);counts.append(c);ends.append(len(expect))
 if levels>1 and w>2*r+3 and h>2*r+3:assert all(sum(c[l] for c in counts)>0 for l in range(levels)),counts
 with tempfile.TemporaryDirectory(prefix='multiscale_features_') as td:
  p=Path(td);(p/'pixels.mem').write_text('\n'.join(f'{int(v):x}' for im in frames for v in im.ravel()))
  fields=[256,4,1,16,16,16,16,2,bits]
  def pack(row):
   v=0
   for value,sz in zip(row,fields):v=(v<<sz)|value
   return v
  ow=sum(fields);n=w*h
  (p/'expected.mem').write_text('\n'.join(f'{pack(row):x}' for row in expect) or '0')
  pyrflat=[int(v) for pyr in pyramids for layer in pyr for v in layer.ravel()]
  (p/'pyramid.mem').write_text('\n'.join(f'{v:x}' for v in pyrflat));total=sum(layer.size for layer in pyramids[0])
  (p/'ends.mem').write_text('\n'.join(f'{v:x}' for v in ends))
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,cfg_valid=0,s_valid=0,s_sof=0,s_eol=0,m_ready=0,done_ready=0;reg [{bits-1}:0] cfg_threshold={threshold},s_pixel;
 wire cfg_ready,s_ready,m_orientation_valid,m_valid,done_valid,frame_error;wire[255:0]m_descriptor;wire[3:0]m_angle,error_code;wire[15:0]m_x,m_y,m_original_x,m_original_y;wire[1:0]m_level;wire[{bits-1}:0]m_score;
 multiscale_features_frame #(.WIDTH({w}),.HEIGHT({h}),.BITS({bits}),.LEVELS({levels}),.RADIUS({r}),.PATTERN_FILE("{(PAT/f'pattern_r{r}.mem').as_posix()}")) dut(.*);
 reg [{bits-1}:0] pixels[0:{len(frames)*n-1}],pyr[0:{len(pyrflat)-1}];reg [{ow-1}:0] expected[0:{max(1,len(expect))-1}];reg[31:0]ends[0:{len(frames)-1}];
 integer i,f,got=0,cycles=0;reg[31:0]rng=35;reg take,stalled=0,pyrchecked=0;reg[{ow-1}:0] held;
 wire[{ow-1}:0]token={{m_descriptor,m_angle,m_orientation_valid,m_x,m_y,m_original_x,m_original_y,m_level,m_score}};
 always @(posedge clk)begin cycles=cycles+1;if(cycles>20000000)$fatal(1,"timeout state=%d",dut.state);
 if(rst_n)begin
 if(stalled&&(!m_valid||token!==held))$fatal(1,"output unstable");stalled=m_valid&&(!ce||!m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin if(got>={len(expect)}||token!==expected[got])$fatal(1,"descriptor %d got %h expected %h",got,token,expected[got]);got=got+1;end
 end else stalled=0;
 end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];m_ready=rng[2]|rng[3];end endtask
 task capture;input integer ff;begin i=0;while(i<{n})begin s_valid=1;s_pixel=pixels[ff*{n}+i];s_sof=i==0;s_eol=i%{w}=={w-1};@(posedge clk);take=ce&&s_ready;if(take)i=i+1;tick;end s_valid=0;end endtask
 initial begin $readmemh("pixels.mem",pixels);$readmemh("pyramid.mem",pyr);$readmemh("expected.mem",expected);$readmemh("ends.mem",ends);
 repeat(3)@(negedge clk);rst_n=1;cfg_valid=1;@(negedge clk);cfg_valid=0;
 // Malformed first beat terminates explicitly, without accepting a partial result.
 s_valid=1;s_sof=0;s_eol=0;@(negedge clk);s_valid=0;if(!done_valid||!frame_error||error_code!=1)$fatal(1,"marker fault");done_ready=1;@(negedge clk);done_ready=0;
 for(f=0;f<{len(frames)};f=f+1)begin capture(f);pyrchecked=0;
 while(!done_valid)begin
 if(!pyrchecked&&dut.state==4&&dut.level==0&&dut.x==0&&dut.y==0)begin for(i=0;i<{total};i=i+1)if(dut.image[i]!==pyr[f*{total}+i])$fatal(1,"pyramid f=%d i=%d got=%d exp=%d",f,i,dut.image[i],pyr[f*{total}+i]);pyrchecked=1;end
 tick;end
 if(frame_error||error_code||got!=ends[f]||!pyrchecked)$fatal(1,"completion f=%d got=%d expected=%d checked=%d err=%d",f,got,ends[f],pyrchecked,error_code);
 ce=0;repeat(3)@(negedge clk);if(!done_valid)$fatal(1,"done hold");ce=1;done_ready=1;@(negedge clk);done_ready=0;
 end
 // CE-disabled reset during a partial capture and work, followed by a full healthy frame.
 ce=1;s_valid=1;s_sof=1;s_eol={int(w==1)};s_pixel=7;@(negedge clk);s_valid=0;rst_n=0;ce=0;@(negedge clk);if(done_valid||m_valid||s_ready)$fatal(1,"reset");rst_n=1;ce=1;
 capture(0);repeat(10)tick;rst_n=0;ce=0;@(negedge clk);if(done_valid||m_valid)$fatal(1,"reset work");
 rst_n=1;ce=1;capture(3);while(!done_valid)tick;if(frame_error||got!={len(expect)})$fatal(1,"post-reset recovery");
 $display("PASS multiscale {w}x{h} BITS{bits} L{levels} R{r}: {len(frames)} frames {len(expect)} descriptors pyramid/FAST/NMS/orientation/rotation CE/error/reset");$finish;end endmodule'''
  (p/'tb.sv').write_text(tb)
  log=f'b{bits}_{w}x{h}_l{levels}_r{r}'
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'multiscale_features_frame.sv',p/'tb.sv'],ROOT,H/f'{log}_compile.log')
  print(execute(['vvp',p/'sim'],p,H/f'{log}_simulation.log',timeout=300).strip(),flush=True)
 return {'result':'PASS','width':w,'height':h,'bits':bits,'levels':levels,'radius':r,'frames':len(frames),'descriptors':len(expect),'counts_by_layer':counts,'pyramid_values':len(pyrflat)}
if __name__=='__main__':
 rows=[run(3,1,8,3,1),run(19,17,8,1,3),run(65,65,8,3,3),run(71,69,10,2,15)]
 (H/'test_evidence.json').write_text(json.dumps({'result':'PASS','cases':rows,'board':False},indent=2)+'\n')
