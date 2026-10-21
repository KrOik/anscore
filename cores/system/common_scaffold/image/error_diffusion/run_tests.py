"""Independent sequential 2-D fixed-point FS oracle; no ordered-dither substitution."""
from pathlib import Path
import sys,tempfile,random,json,hashlib
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute,ROOT

def oracle(frame,w,h,b,ob,serpentine):
 maximum=(1<<b)-1;levels=(1<<ob)-1
 errors=[0]*(w*h);pixels=[0]*(w*h);codes=[0]*(w*h)
 for y in range(h):
  direction=-1 if serpentine and y%2 else 1
  for x in (range(w) if direction==1 else range(w-1,-1,-1)):
   corrected=min(maximum*16,max(0,frame[y*w+x]*16+errors[y*w+x]))
   code=(corrected*levels+maximum*8)//(maximum*16)
   pixel=(code*maximum+levels//2)//levels
   codes[y*w+x]=code;pixels[y*w+x]=pixel
   error=corrected-pixel*16
   for nx,ny,weight in ((x+direction,y,7),(x-direction,y+1,3),(x,y+1,5),(x+direction,y+1,1)):
    if 0<=nx<w and 0<=ny<h:
     errors[ny*w+nx]+=(-1 if error<0 else 1)*((abs(error)*weight+8)//16)
 return pixels,codes

HEADER=r'''
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,mode=0,sv=0,sof=0,eol=0,mr=0,dr=0;reg [B-1:0] sp=0;
wire sr,mv,ms,me,ml,dv,de;wire [B-1:0] mp;wire [O-1:0] code;wire [15:0] x,y;
floyd_steinberg #(.WIDTH(W),.HEIGHT(H),.BITS(B),.OUTPUT_BITS(O)) dut(
.clk(clk),.rst_n(rst_n),.ce(ce),.cfg_serpentine(mode),.s_pixel(sp),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
.m_pixel(mp),.m_code(code),.m_valid(mv),.m_ready(mr),.m_x(x),.m_y(y),.m_sof(ms),.m_eol(me),.m_last(ml),.done_valid(dv),.done_ready(dr),.done_error(de));
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task send(input [B-1:0] p,input fs,le);begin while(!sr)tick;sp=p;sof=fs;eol=le;sv=1;tick;sv=0;end endtask
task check(input [B-1:0] p,input [O-1:0] c,input [15:0] ex,ey);reg [B+O+34:0] held;integer t;begin
 t=0;sv=1;sof=0;eol=0;
 while(!mv)begin ce=t%9!=4;tick;t=t+1;if(sr)$fatal(1,"busy ready");end
 sv=0;ce=1;
 if({mp,code,x,y,ms,me,ml}!=={p,c,ex,ey,(ex==0&&ey==0),(ex==W-1),(ex==W-1&&ey==H-1)})begin
 $display("actual p=%d code=%d x=%d y=%d expected p=%d code=%d x=%d y=%d",mp,code,x,y,p,c,ex,ey);$fatal(1,"oracle");end
 held={mp,code,x,y,ms,me,ml};repeat(2)begin tick;if(!mv||{mp,code,x,y,ms,me,ml}!==held)$fatal(1,"output hold");end
 ce=0;mr=1;repeat(2)begin tick;if(!mv||{mp,code,x,y,ms,me,ml}!==held||sr)$fatal(1,"CE");end
 ce=1;tick;mr=0;
end endtask
task finish_frame(input expected_error);begin
 if(!dv||de!==expected_error)$fatal(1,"done");repeat(3)begin tick;if(!dv||de!==expected_error||sr)$fatal(1,"done hold");end
 dr=1;tick;dr=0;if(!sr||mv||dv)$fatal(1,"done release");
end endtask
task reset_dut;begin ce=0;rst_n=0;tick;if(sr||mv||dv||de)$fatal(1,"reset CE0");rst_n=1;ce=1;tick;end endtask
initial begin #100000000;$fatal(1,"timeout");end
integer t;
initial begin @(negedge clk);tick;rst_n=1;tick;
send(0,0,W==1);finish_frame(1);send(0,1,W!=1);finish_frame(1);
'''

def main():
 rng=random.Random(71016);results=[];measurements=[]
 profiles=((9,7,8,1),(17,13,8,2),(7,5,10,4),(5,7,12,3),(1,11,12,1),(11,1,8,1),(1,1,10,2),(8,5,8,8),(4,3,12,12))
 for w,h,b,ob in profiles:
  n=w*h;maximum=(1<<b)-1
  fs=[[0]*n,[maximum]*n,[maximum//4]*n,[maximum//2]*n,[maximum//2+1]*n,
      [int(32*x/max(1,w-1)) for y in range(h) for x in range(w)],
      [int(maximum*x/max(1,w-1)) for y in range(h) for x in range(w)],
      [int(maximum*(x+y)/max(1,w+h-2)) for y in range(h) for x in range(w)],
      [maximum*((x+y)%2) for y in range(h) for x in range(w)]]
  fs += [[rng.randrange(maximum+1) for _ in range(n)] for _ in range(9)]
  # Identical repeated frames with both modes prove row errors never leak.
  fs += [fs[3],fs[3],fs[3],fs[3]]
  tb=HEADER.replace('module tb;',f'module tb;localparam W={w},H={h},B={b},O={ob};')
  for fi,frame in enumerate(fs):
   mode=bool(fi%2);pixels,codes=oracle(frame,w,h,b,ob,mode)
   tb+=f"mode=1'b{int(mode)};\n"
   for i,p in enumerate(frame):
    tb+=f"send({b}'d{p},1'b{int(i==0)},1'b{int(i%w==w-1)});\n"
    if i==0:tb+=f"mode=1'b{int(not mode)};\n"
   for i,(p,c) in enumerate(zip(pixels,codes)):tb+=f"check({b}'d{p},{ob}'d{c},16'd{i%w},16'd{i//w});\n"
   tb+='finish_frame(0);\n'
   if ob==b:assert pixels==frame and codes==frame
   measurements.append({'geometry':f'{w}x{h}','bits':b,'output_bits':ob,'frame':fi,'serpentine':mode,'input_mean':sum(frame)/n,'output_mean':sum(pixels)/n,'mean_intensity_error':(sum(pixels)-sum(frame))/n,'mean_error_fullscale':(sum(pixels)-sum(frame))/(n*maximum)})
  tb+='''
 // Abort load, row clear, division, diffusion RMW and held output; every reset ignores CE.
 send(7,1,W==1);reset_dut;
 for(t=0;t<W*H;t=t+1)send(t,t==0,t%W==W-1);
 tick;reset_dut;
 for(t=0;t<W*H;t=t+1)send(t,t==0,t%W==W-1);
 while(dut.state!=5)tick;reset_dut;
 for(t=0;t<W*H;t=t+1)send(t,t==0,t%W==W-1);
 while(dut.state!=8)tick;reset_dut;
 for(t=0;t<W*H;t=t+1)send(t,t==0,t%W==W-1);
 while(!mv)tick;reset_dut;
 $display("PASS Floyd-Steinberg diffusion");$finish;end endmodule
'''
  tag=f'{w}x{h}_B{b}_O{ob}'
  with tempfile.TemporaryDirectory(prefix='floyd_steinberg_') as td:
   p=Path(td);(p/'tb.sv').write_text(tb)
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim.vvp',HERE/'floyd_steinberg.sv',p/'tb.sv'],ROOT,HERE/f'compile_{tag}.log')
   out=execute(['vvp',p/'sim.vvp'],ROOT,HERE/f'test_{tag}.log',timeout=120);assert 'PASS Floyd-Steinberg diffusion' in out
  results.append({'configuration':tag,'frames':len(fs),'pixels':len(fs)*n,'status':'PASS'})
 for w,h,b,ob in ((0,1,8,1),(257,256,8,1),(1,1,7,1),(1,1,8,0),(1,1,8,9)):
  tag=f'{w}x{h}_B{b}_O{ob}'
  with tempfile.TemporaryDirectory(prefix='floyd_guard_') as td:
   p=Path(td);(p/'tb.sv').write_text(f'module tb;floyd_steinberg #(.WIDTH({w}),.HEIGHT({h}),.BITS({b}),.OUTPUT_BITS({ob})) dut();endmodule')
   try:
    execute(['iverilog','-g2012','-s','tb','-o',p/'sim.vvp',HERE/'floyd_steinberg.sv',p/'tb.sv'],ROOT,HERE/f'guard_compile_{tag}.log')
    execute(['vvp',p/'sim.vvp'],ROOT,HERE/f'guard_{tag}.log')
   except RuntimeError:pass
   else:raise AssertionError('invalid parameter accepted')
 (HERE/'brightness_measurements.json').write_text(json.dumps(measurements,indent=2)+'\n')
 evidence={'status':'PASS','tests':results,'invalid_parameter_cases':5,'maximum_absolute_mean_intensity_error':max(abs(m['mean_intensity_error']) for m in measurements),'maximum_absolute_mean_error_fullscale':max(abs(m['mean_error_fullscale']) for m in measurements),'mean_absolute_normalized_frame_brightness_error':sum(abs(m['mean_error_fullscale']) for m in measurements)/len(measurements),'visual_quality_signoff':False,'pillow_bitexact_claim':False,'rtl_sha256':hashlib.sha256((HERE/'floyd_steinberg.sv').read_bytes()).hexdigest(),'board':False}
 (HERE/'evidence.json').write_text(json.dumps(evidence,indent=2)+'\n');print(evidence)
if __name__=='__main__':main()
