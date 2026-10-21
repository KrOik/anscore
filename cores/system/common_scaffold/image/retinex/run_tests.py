"""Exact integer and independent floating SSR references; all ROM entries audited."""
from pathlib import Path
import sys,tempfile,json,random,math,hashlib,decimal
sys.dont_write_bytecode=True
import numpy as np
import cv2
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute,ROOT
ROM_SHA='960228a10efd419990bf291d5b2c537e286de15dd175241616bce955394db683'

def reflect(i,n):
 if n==1:return 0
 while i<0 or i>=n:i=-i if i<0 else 2*n-2-i
 return i

def oracle(frame,w,h,b,gain,offset,logs):
 k=(1,4,6,4,1);results=[];raw_errors=[];log_errors=[];mapped_errors=[]
 surround_cv=cv2.sepFilter2D(np.array(frame,dtype=np.float64).reshape(h,w),cv2.CV_64F,np.array(k,dtype=np.float64)/16,np.array(k,dtype=np.float64)/16,borderType=cv2.BORDER_REFLECT_101)
 for y in range(h):
  for x in range(w):
   total=sum(k[j]*k[i]*frame[reflect(y+j-2,h)*w+reflect(x+i-2,w)] for j in range(5) for i in range(5))
   assert surround_cv[y,x]==total/256
   surround=(total+128)//256;pixel=frame[y*w+x]
   raw=logs[pixel]-logs[surround]
   product=raw*gain
   mapped=offset+((-1 if product<0 else 1)*((abs(product)+32768)//65536))
   mapped=max(0,min((1<<b)-1,mapped));results.append((mapped,raw,surround))
   ideal_raw=math.log2(pixel+1)-math.log2(total/256+1)
   ideal_rounded_raw=math.log2(pixel+1)-math.log2(surround+1)
   raw_errors.append(raw/256-ideal_raw);log_errors.append(raw/256-ideal_rounded_raw)
   ideal_mapped=max(0,min((1<<b)-1,offset+ideal_raw*gain/256))
   mapped_errors.append(mapped-ideal_mapped)
 return results,raw_errors,log_errors,mapped_errors

HEADER=r'''
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cv=0,sv=0,sof=0,eol=0,mr=0,dr=0;
reg [15:0] gain=256;reg signed [15:0] offset=0;reg [B-1:0] pixel=0;
wire cr,cd,sr,mv,ms,me,ml,dv,de;wire [B-1:0] mp,surround;wire signed [15:0] raw;wire [15:0] x,y;
retinex_ssr #(.WIDTH(W),.HEIGHT(H),.BITS(B)) dut(.clk(clk),.rst_n(rst_n),.ce(ce),
.cfg_valid(cv),.cfg_ready(cr),.cfg_gain(gain),.cfg_offset(offset),.cfg_done(cd),
.s_pixel(pixel),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
.m_pixel(mp),.m_raw(raw),.m_surround(surround),.m_valid(mv),.m_ready(mr),.m_x(x),.m_y(y),.m_sof(ms),.m_eol(me),.m_last(ml),
.done_valid(dv),.done_ready(dr),.done_error(de));
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task configure(input [15:0] g,input signed [15:0] o);begin
 if(!cr)$fatal(1,"config not ready");gain=g;offset=o;cv=1;tick;cv=0;if(!cd)$fatal(1,"config ack");
end endtask
task send(input [B-1:0] p,input fs,le);begin
 while(!sr)tick;pixel=p;sof=fs;eol=le;sv=1;tick;sv=0;
end endtask
task check(input [B-1:0] ep,es,input signed [15:0] er,input [15:0] ex,ey);reg [2*B+51:0] held;integer t;begin
 t=0;sv=1;sof=0;eol=0;
 while(!mv)begin ce=t%7!=3;tick;t=t+1;if(sr||cr)$fatal(1,"busy ready");end
 sv=0;ce=1;
 if({mp,surround,raw,x,y,ms,me,ml}!=={ep,es,er,ex,ey,(ex==0&&ey==0),(ex==W-1),(ex==W-1&&ey==H-1)})begin
 $display("actual p=%d surround=%d raw=%d x=%d y=%d expected p=%d surround=%d raw=%d x=%d y=%d",mp,surround,raw,x,y,ep,es,er,ex,ey);$fatal(1,"oracle mismatch");end
 held={mp,surround,raw,x,y,ms,me,ml};repeat(2)begin tick;if(!mv||{mp,surround,raw,x,y,ms,me,ml}!==held)$fatal(1,"backpressure");end
 ce=0;mr=1;repeat(2)begin tick;if(!mv||{mp,surround,raw,x,y,ms,me,ml}!==held||sr||cr)$fatal(1,"CE");end
 ce=1;tick;mr=0;
end endtask
task finish_frame(input expected_error);begin
 if(!dv||de!==expected_error)$fatal(1,"done");repeat(3)begin tick;if(!dv||de!==expected_error||sr||cr)$fatal(1,"done hold");end
 dr=1;tick;dr=0;if(!sr||!cr||mv||dv)$fatal(1,"release");
end endtask
task reset_dut;begin ce=0;rst_n=0;tick;if(sr||cr||mv||dv||de||cd)$fatal(1,"reset");rst_n=1;ce=1;tick;end endtask
initial begin #30000000;$fatal(1,"timeout");end
integer t;reg [11:0] expected_log[0:4095];
initial begin
 $readmemh("@EXPECTED_ROM@",expected_log);
 @(negedge clk);tick;rst_n=1;tick;
 for(t=0;t<4096;t=t+1)if(dut.logs[t]!==expected_log[t])$fatal(1,"RTL ROM mismatch index%0d",t);
 // Marker failure is fail-stop, requiring acknowledgement.
 send(0,0,W==1);finish_frame(1);send(0,1,W!=1);finish_frame(1);
'''

def stats(values):
 return {'maximum_absolute':max(map(abs,values)),'mean_absolute':sum(map(abs,values))/len(values),'rmse':math.sqrt(sum(v*v for v in values)/len(values))}

def main():
 decimal.getcontext().prec=70
 D=decimal.Decimal;den=D(2).ln()
 logs=[int((D(i+1).ln()/den*256).to_integral_value(rounding=decimal.ROUND_HALF_UP)) for i in range(4096)]
 rom=(HERE/'log2_q8.hex').read_bytes();assert hashlib.sha256(rom).hexdigest()==ROM_SHA
 assert [int(v,16) for v in rom.decode().split()]==logs
 rng=random.Random(42025);results=[];raw_errors=[];log_errors=[];mapped_errors=[]
 for w,h,b in ((9,7,8),(11,9,10),(7,5,12),(1,9,8),(9,1,12),(1,1,10),(2,2,12)):
  mask=(1<<b)-1;n=w*h
  fs=[[0]*n,[mask]*n,[mask//3]*n,
      [int(mask*(.15+.85*x/max(1,w-1))*(.3+.7*y/max(1,h-1))) for y in range(h) for x in range(w)],
      [mask if x>=w//2 else 0 for y in range(h) for x in range(w)],
      [mask if (x==w//2 and y==h//2) else 0 for y in range(h) for x in range(w)],
      [int((x+y)%2)*mask for y in range(h) for x in range(w)]]
  fs += [[rng.randrange(mask+1) for _ in range(n)] for _ in range(13)]
  fs += [[(x+y)%2 for y in range(h) for x in range(w)],
         [(x+2*y)%4 for y in range(h) for x in range(w)]]
  cfgs=[(256,0),(8192,128),(65535,-32768),(65535,32767),(0,mask//2),(8192,0),(8192,mask)]
  tb=HEADER.replace('module tb;',f'module tb;localparam W={w},H={h},B={b};')
  for fi,f in enumerate(fs):
   gain,offset=cfgs[fi%len(cfgs)]
   if fi>=20:gain,offset=8192,mask//2
   expected,re,le,me=oracle(f,w,h,b,gain,offset,logs);raw_errors+=re;log_errors+=le;mapped_errors+=me
   tb+=f"configure(16'd{gain},16'h{offset&65535:x});\n"
   for i,p in enumerate(f):
    tb+=f"send({b}'d{p},1'b{int(i==0)},1'b{int(i%w==w-1)});\n"
    if i==0:
     # Hold a pending update across partial capture, compute, output, DONE.
     tb+="gain=16'd0;offset=16'h8000;cv=1;\n"
   for i,(p,raw,surround) in enumerate(expected):tb+=f"check({b}'d{p},{b}'d{surround},16'h{raw&65535:x},16'd{i%w},16'd{i//w});\n"
   # Finish routine expects input ready high; deassert pending config only after
   # proving it wasn't accepted before the frame has completed.
   tb+='if(cr)$fatal(1,"early config ready");cv=0;finish_frame(0);\n'
  tb+='''
 // Configuration priority at frame boundary: pixel stays pending, not dropped.
 gain=8192;offset=128;cv=1;sv=1;sof=1;eol=W==1;pixel=0;tick;
 if(dut.capture_address!=0||!cd)$fatal(1,"config arbitration");sv=0;cv=0;
 send(0,1,W==1);reset_dut;
 for(t=0;t<W*H;t=t+1)send(t,t==0,t%W==W-1);
 repeat(4)tick;reset_dut;
 for(t=0;t<W*H;t=t+1)send(t,t==0,t%W==W-1);
 while(dut.state!=8)tick;reset_dut;
 for(t=0;t<W*H;t=t+1)send(t,t==0,t%W==W-1);
 while(!mv)tick;reset_dut;
 $display("PASS quantized SSR Retinex");$finish;end endmodule
'''
  tag=f'{w}x{h}_{b}'
  with tempfile.TemporaryDirectory(prefix='retinex_test_') as td:
   p=Path(td);(p/'expected.hex').write_text(''.join(f'{v:03x}\n' for v in logs))
   (p/'tb.sv').write_text(tb.replace('@EXPECTED_ROM@',(p/'expected.hex').as_posix()))
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim.vvp',HERE/'retinex_ssr.sv',p/'tb.sv'],ROOT,HERE/f'compile_{tag}.log')
   out=execute(['vvp',p/'sim.vvp'],ROOT,HERE/f'test_{tag}.log',timeout=120);assert 'PASS quantized SSR Retinex' in out
  results.append({'configuration':tag,'frames':len(fs),'pixels':len(fs)*n,'status':'PASS'})
 evidence={'status':'PASS','tests':results,'rom_entries_high_precision_audited':4096,'rom_sha256':ROM_SHA,'rom_log_units_max_error':max(abs(logs[i]/256-math.log2(i+1)) for i in range(4096)),
 'raw_vs_float_unrounded_surround_log_units':stats(raw_errors),'raw_vs_float_rounded_surround_log_units':stats(log_errors),'mapped_vs_float_unrounded_surround_intensity':stats(mapped_errors),
 'opencv_version':cv2.__version__,'opencv_surround_numeric_comparisons':len(raw_errors),'rtl_sha256':hashlib.sha256((HERE/'retinex_ssr.sv').read_bytes()).hexdigest(),'board':False}
 (HERE/'evidence.json').write_text(json.dumps(evidence,indent=2)+'\n');print(evidence)
if __name__=='__main__':main()
